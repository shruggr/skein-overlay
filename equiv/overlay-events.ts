// skein-overlay 0.26.0 + skein-chain 0.10.0 on a real kernel (David 2026-11-09): every status of
// a transaction is the chain app's fact `chain/tx/<txid>`; the submission's thread rests on it for
// the transaction's life (skein 0.5.4) and the overlay's verdicts are facts too; 0.26.0: the overlay
// hands each transaction to the chain app by an in-VM call of its `ingest` (status words pending,
// seen, mined, rejected; `seen` with reason "reorged" after a reorg)
// (`overlay/topic/tx/<txid>` {verdict}, `overlay/topic/output/<txid>.<vout>` {state}). One router
// with an Arcade, one stock-system instance, the chain app and the overlay installed by the
// owner's messages, the topic tm_ev registered:
//
//   (a) t1 posted unmined (POST /submit, BRC-22): the request waits on the subject (no launch),
//       answered the STEAK once the chain app's `seen` admits it; the facts chain/tx pending, seen,
//       topic/tx admitted, topic/output admitted;
//   (b) mined at 2 (Arcade's MINED): chain/tx mined {height: 2}; the topic's anchors tip 2;
//   (c) reorged (a heavier branch without it): chain/tx seen (reason reorged); the topic's tip gone (back in its
//       tail); mined again at 5 in the new branch: chain/tx mined {height: 5}, the tip 5;
//   (d) a message submission (box overlay/submit) of t1 under a second topic tm_ev2 re-ingests it
//       (the chain app restates `mined`): the first submission's thread hears it again and
//       answers nothing again; the message submission is answered admitted once, its proof once;
//   (e) t2 posted while Arcade rejects: 400 to the client; chain/tx rejected; topic/tx rejected;
//   (f) a parent in flight (Arcade busy: no status), its child posted with it in the BEEF: the
//       child undecided (paused, resting on the parent's verdict); Arcade back: the parent
//       admitted, the child woken, routed again, admitted — its outputs admitted, the parent's spent;
//       0.25.0 (case c): a second copy of the paused child is a duplicate — one submission thread;
//   (g) 0.25.0 (case a): t2, rejected in (e), mined later: chain/tx mined (the latest fact, over the
//       rejection) and the overlay admits it on the same thread;
//   (h) 0.25.0 (case e): a topic registered with a seed — the deploy's BEEF — submitted as an
//       ordinary submission: admitted via its submission thread; mined later, placed.
//
// The store then replays to itself exactly (SKEIN_EQUIV_STORE: sqlite, rocksdb, wasm).
//
// It runs from a skein checkout: copy it into <skein>/kernel-zig/equiv/ and
//   SKEIN_OVERLAY_DIR=<this repo> SKEIN_CHAIN_DIR=<skein-chain> node --experimental-strip-types --no-warnings kernel-zig/equiv/overlay-events.ts

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Beef, MerklePath, P2PKH, PrivateKey, Script, Transaction, UnlockingScript } from "@bsv/sdk";
import { CID } from "multiformats/cid";
import { ownerCli } from "../../src/testapps.ts";
import { RawBox } from "../../src/client/raw.ts";
import { storeSpec } from "../../src/runtime/index-store.ts";
import { openStoreFile } from "../../src/host/stores.ts";
import { BACKEND, routerStore, storeFor } from "./backend.ts";
import { FakeArcade } from "../../src/host/fake-arcade.ts";
import { HostDb } from "../../src/host/instances.ts";
import { Router } from "../../src/host/router.ts";
import { txCid } from "../../src/host/feeds.ts";
import { ephemeralWallet } from "../../src/wallet.ts";

const here = dirname(fileURLToPath(import.meta.url));
const kernel = process.env.SKEIN_KERNEL_BIN ?? join(here, "../zig-out/bin/skein-kernel");
const home = mkdtempSync(join(tmpdir(), "skein-kz-ovev-"));
let failures = 0;
const check = (ok: boolean, what: string) => { process.stdout.write(`${ok ? "ok  " : "FAIL"} ${what}\n`); if (!ok) failures++; };
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function until<T>(what: string, f: () => Promise<T | undefined> | T | undefined, ms = 30_000): Promise<T> {
  for (const end = Date.now() + ms; ;) {
    const v = await f();
    if (v) return v;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(150);
  }
}
const dirOf = (env: string) => {
  const d = process.env[env];
  if (!d) throw new Error(`${env}: the checkout to test`);
  return d;
};
const copyOf = (src: string, dst: string) => { cpSync(src, dst, { recursive: true, filter: (p) => !/\/(\.git|zig-out|\.zig-cache|zig-pkg|equiv)$/.test(p) }); return dst; };

// ---------------------------------------------------------------- regtest

const sha256d = (b: Uint8Array) => createHash("sha256").update(createHash("sha256").update(b).digest()).digest();
const internal = (displayHex: string) => Buffer.from(displayHex, "hex").reverse();
const display = (b: Uint8Array) => Buffer.from(b).reverse().toString("hex");
const REGTEST_GENESIS = Buffer.from("0100000000000000000000000000000000000000000000000000000000000000000000003ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4adae5494dffff7f2002000000", "hex");
const TARGET = 0x7fffffn << BigInt(8 * (0x20 - 3));
function mine(prev: Uint8Array, merkleRoot: Uint8Array, time: number): Uint8Array {
  const h = Buffer.alloc(80);
  h.writeInt32LE(1, 0);
  Buffer.from(prev).copy(h, 4);
  Buffer.from(merkleRoot).copy(h, 36);
  h.writeUInt32LE(time, 68);
  h.writeUInt32LE(0x207fffff, 72);
  for (let nonce = 0; ; nonce++) {
    h.writeUInt32LE(nonce, 76);
    if (BigInt("0x" + Buffer.from(sha256d(h)).reverse().toString("hex")) <= TARGET) return new Uint8Array(h);
  }
}

/** Every overlay step's result record in a store, each once. */
async function overlayResults(file: string): Promise<Array<Record<string, unknown>>> {
  const v = openStoreFile(file, { readOnly: true });
  const out: Array<{ at: number; r: Record<string, unknown> }> = [];
  const seen = new Set<string>();
  try {
    for await (const th of v.edges.query({ kind: "thread" })) {
      for await (const u of v.chains.history(th)) {
        if (u.equals(th)) continue;
        const up = await v.get(u) as unknown as { at?: number; result?: { stdout?: Uint8Array } };
        const text = up.result?.stdout ? Buffer.from(up.result.stdout).toString("utf8").trim().split("\n").at(-1) ?? "" : "";
        let c: CID;
        try { c = /^[0-9a-f]+$/.test(text) ? CID.decode(Buffer.from(text, "hex")) : CID.parse(text); } catch { continue; }
        const r = await v.get(c).catch(() => undefined) as unknown as Record<string, unknown> | undefined;
        if (r?.kind === "overlay-result" && !seen.has(String(c))) { seen.add(String(c)); out.push({ at: up.at ?? 0, r }); }
      }
    }
  } finally { await v.close(); }
  return out.sort((x, y) => x.at - y.at).map((x) => x.r);
}

// ---------------------------------------------------------------- one router, one instance

const key = (h: string) => new PrivateKey(h, 16);
const ownerKey = key("2222");
const owner = ownerKey.toPublicKey().toString();
const ownerWallet = ephemeralWallet(ownerKey);
const arcade = await FakeArcade.start();
const H = "ev";
const hostHome = join(home, H);
mkdirSync(hostHome, { recursive: true });
const db = new HostDb(join(hostHome, "host.db"));
db.add(H, { store: storeFor(hostHome, H) });
const r = new Router({
  db, walletFor: () => ephemeralWallet(key("1111")), home: hostHome, owner, idleMs: 0, answerWaitMs: 4000,
  kernel: { command: kernel, env: { SKEIN_HOME: hostHome } }, ...routerStore(hostHome),
  genesis: { defaults: { walletNetwork: "regtest" } },
  arc: { url: arcade.url, token: "the-ev-arcade-token", events: arcade.eventsUrl }, arcRetry: { min: 300, max: 800 },
  log: (s: string, l: string) => { if (process.env.VERBOSE) process.stdout.write(`  | [${s}] ${l}\n`); },
});
const store = () => storeSpec(db.get(H)!);
const origin = () => r.originOf(H);

// The chain: the funding transaction mined at 1.
const alice = key("3333");
const fund = new Transaction();
fund.addInput({ sourceTXID: "72".repeat(32), sourceOutputIndex: 0, unlockingScript: UnlockingScript.fromHex("51"), sequence: 0xffffffff });
for (let i = 0; i < 8; i++) fund.addOutput({ lockingScript: new P2PKH().lock(alice.toPublicKey().toHash()), satoshis: 10_000 });
const fundTxid = fund.id("hex");
fund.merklePath = new MerklePath(1, [[{ offset: 0, hash: "cb".repeat(32) }, { offset: 1, hash: fundTxid, txid: true }]]);
const h1 = mine(sha256d(REGTEST_GENESIS), sha256d(Buffer.concat([internal("cb".repeat(32)), internal(fundTxid)])), 1_790_200_000);
const tokenScript = () => Script.fromBinary([0x07, ...Buffer.from("tm_demo"), 0x75, ...new P2PKH().lock(alice.toPublicKey().toHash()).toBinary()]);
async function token(source: Transaction, vout: number, sats = 9_000): Promise<Transaction> {
  const t = new Transaction();
  t.addInput({ sourceTransaction: source, sourceOutputIndex: vout, unlockingScriptTemplate: new P2PKH().unlock(alice), sequence: 0xffffffff });
  t.addOutput({ lockingScript: tokenScript(), satoshis: 1 });
  t.addOutput({ lockingScript: new P2PKH().lock(alice.toPublicKey().toHash()), satoshis: sats });
  await t.sign();
  return t;
}
/** A token transfer: `source`'s token output `vout` (1 sat) to a new token output, no change. */
async function transfer(source: Transaction, vout: number): Promise<Transaction> {
  const t = new Transaction();
  t.addInput({ sourceTransaction: source, sourceOutputIndex: vout, unlockingScriptTemplate: new P2PKH().unlock(alice), sequence: 0xffffffff });
  t.addOutput({ lockingScript: tokenScript(), satoshis: 1 });
  await t.sign();
  return t;
}
const headers = async (hs: Uint8Array[]) => { await r.chainHeaders(H, "chain", hs); await r.settled(); };
const post = (beef: number[] | Uint8Array, topics = "tm_ev") => fetch(`${origin()}/overlay/submit`, { method: "POST", headers: { "x-topics": topics }, body: Uint8Array.from(beef) });
type Row = { id: string; event: string; record: Record<string, unknown> };
const events = async (name: string): Promise<Row[]> => {
  const res = await fetch(`${origin()}/events/${name}`);
  if (res.status !== 200) throw new Error(`GET /events/${name}: ${res.status} ${await res.text()}`);
  return await res.json() as Row[];
};
const field = async (name: string, f: string) => (await events(name)).map((x) => String(x.record[f]));
const tipOf = async (topic: string) => (await (await fetch(`${origin()}/overlay/anchors?topic=${topic}`)).json() as { tipHeight?: number }).tipHeight;
const proofAt = (t: Transaction, height: number, block: Uint8Array) => ({ txStatus: "MINED", blockHash: display(sha256d(block)), blockHeight: height, merklePath: new MerklePath(height, [[{ offset: 0, hash: t.id("hex"), txid: true }]]).toHex() });

try {
  const overlayDir = copyOf(dirOf("SKEIN_OVERLAY_DIR"), join(home, "overlay"));
  const chainDir = copyOf(dirOf("SKEIN_CHAIN_DIR"), join(home, "chain"));
  const mf = JSON.parse(readFileSync(join(overlayDir, "etc/app.json"), "utf8")) as { version: string; config: { overlay: Record<string, unknown> } };
  const cmf = JSON.parse(readFileSync(join(chainDir, "etc/app.json"), "utf8")) as { version: string };
  check(mf.version === "0.25.1" && cmf.version === "0.9.0", `skein-overlay ${mf.version}, skein-chain ${cmf.version}`);
  mf.config.overlay.gossip = { tm_demo: false };
  writeFileSync(join(overlayDir, "etc/app.json"), JSON.stringify(mf, null, 2));

  await r.listen(0);
  await r.hydrate(H);
  const hostOf = { home: hostHome, port: r.port!, owner: ownerWallet, settled: () => r.settled() };
  for (const dir of [chainDir, overlayDir]) {
    const o = await ownerCli(hostOf, ["install", dir, "--instance", H]);
    if (o.code !== 0) throw new Error(`install ${dir}: ${o.err.join(" ")}`);
    await r.settled();
  }
  const identity = (await r.hydrate(H)).identity;
  const box = new RawBox(ownerWallet, `http://127.0.0.1:${r.port}/@${H}`);
  for (const t of ["tm_ev", "tm_ev2"]) await box.send(identity, "overlay/register", { fn: "register", args: { topic: t, program: "topic-demo" } });
  await r.settled();
  await headers([h1]);

  // ------------------------------------------------ (a) unmined, posted: admitted on `seen`, the STEAK
  const t1 = await token(fund, 0);
  const id1 = t1.id("hex");
  const s1 = await post(t1.toBEEF());
  const s1t = await s1.text();
  check(s1.status === 200 && /"tm_ev":\{"outputsToAdmit":\[0\]/.test(s1t), `(a) t1 posted unmined: the request waited on the subject and was answered the STEAK (${s1.status} ${s1t})`);
  check((await field(`chain/tx/${id1}`, "status")).join() === "pending,seen", `(a) the chain app's facts chain/tx/${id1.slice(0, 8)}…: pending, seen (${await field(`chain/tx/${id1}`, "status")})`);
  check((await overlayResults(store())).every((x) => x.ingest === undefined && x.ingests === undefined && x.awaiting === undefined), "(a) 0.26.0: no ingest message, nothing awaited (the chain app called)");
  check((await field(`overlay/topic/tx/${id1}`, "verdict")).join() === "admitted", `(a) overlay/topic/tx: admitted (${await field(`overlay/topic/tx/${id1}`, "verdict")})`);
  check((await field(`overlay/topic/output/${id1}.0`, "state")).join() === "admitted", "(a) overlay/topic/output/<t1>.0: admitted");
  check((await overlayResults(store())).every((x) => x.op !== "watch" && x.op !== "watched" && x.op !== "resume"), "(a) no watch, no resume step (0.24.0)");

  // ------------------------------------------------ (b) mined at 2
  const h2 = mine(sha256d(h1), internal(id1), 1_790_200_600);
  await headers([h2]);
  arcade.emit(id1, proofAt(t1, 2, h2));
  await until("chain/tx mined", async () => (await field(`chain/tx/${id1}`, "status")).includes("mined") || undefined);
  await r.settled();
  const mined = (await events(`chain/tx/${id1}`)).at(-1)!.record;
  check(mined.status === "mined" && mined.height === 2, `(b) chain/tx: mined {height: ${mined.height}}`);
  check(await until("the topic's tip 2", async () => (await tipOf("tm_ev")) === 2 || undefined).catch(() => false) === true, `(b) the topic's anchors: tip 2 (${await tipOf("tm_ev")})`);

  // ------------------------------------------------ (c) reorged, then mined again at 5
  const fork: Uint8Array[] = [];
  for (let i = 0; i < 3; i++) fork.push(mine(sha256d(fork.at(-1) ?? h1), Buffer.alloc(32, 0x61 + i), 1_790_300_000 + i * 600));
  await headers(fork);
  await until("chain/tx reorged", async () => (await field(`chain/tx/${id1}`, "reason")).includes("reorged") || undefined).catch(() => undefined);
  await r.settled();
  check((await field(`chain/tx/${id1}`, "status")).join() === "pending,seen,mined,seen" && (await field(`chain/tx/${id1}`, "reason")).at(-1) === "reorged", `(c) a heavier branch without it: chain/tx seen, reason reorged (${await field(`chain/tx/${id1}`, "status")} / ${await field(`chain/tx/${id1}`, "reason")})`);
  check((await tipOf("tm_ev")) === undefined, `(c) back in the topic's tail: no tip (${await tipOf("tm_ev")})`);
  const h5 = mine(sha256d(fork.at(-1)!), internal(id1), 1_790_302_000);
  await headers([h5]);
  arcade.emit(id1, proofAt(t1, 5, h5));
  await until("mined again", async () => (await field(`chain/tx/${id1}`, "status")).filter((s) => s === "mined").length === 2 || undefined);
  await r.settled();
  const again = (await events(`chain/tx/${id1}`)).at(-1)!.record;
  check(again.status === "mined" && again.height === 5, `(c) mined again in the new branch: chain/tx mined {height: ${again.height}}`);
  check(await until("the topic's tip 5", async () => (await tipOf("tm_ev")) === 5 || undefined).catch(() => false) === true, `(c) the topic's tip 5 (${await tipOf("tm_ev")})`);
  check((await field(`overlay/topic/tx/${id1}`, "verdict")).join() === "admitted", "(c) its verdict never changed: one fact, admitted");
  const proofsBefore = (await overlayResults(store())).filter((x) => x.op === "heard" && x.heard === "mined").length;

  // ------------------------------------------------ (d) a message submission under tm_ev2 re-ingests it: answered once
  const m1 = (await box.send(identity, "overlay/submit", { fn: "submit", args: { beef: Uint8Array.from(t1.toBEEF()), topics: ["tm_ev2"] } })).id;
  await r.settled();
  await until("admitted under tm_ev2", async () => (await overlayResults(store())).some((x) => x.admitted === true && JSON.stringify(x.steak ?? {}).includes("tm_ev2")) || undefined);
  await r.settled();
  check((await field(`chain/tx/${id1}`, "status")).filter((s) => s === "mined").length === 3, `(d) the ingest restated it: chain/tx mined a third time (${await field(`chain/tx/${id1}`, "status")})`);
  const results = await overlayResults(store());
  const answers = results.flatMap((x) => ((x.answers ?? []) as Array<{ body?: { replyTo?: CID; result?: { state?: string } } }>));
  const mine1 = answers.filter((x) => x.body?.replyTo && String(x.body.replyTo) === String(m1));
  check(mine1.filter((x) => x.body?.result?.state === "admitted").length === 1 && mine1.filter((x) => x.body?.result?.state === "proven").length === 1, `(d) the message submission answered admitted once, its proof once (${mine1.map((x) => x.body?.result?.state).join(", ")})`);
  // The first submission's thread (POST /submit, no submitter to answer) heard `mined` again: nothing moved, nothing published.
  const heardAgain = results.filter((x) => x.op === "heard" && x.heard === "mined").slice(proofsBefore);
  const others = heardAgain.filter((x) => x.admitted !== true);
  check(heardAgain.filter((x) => x.admitted === true).length === 1 && others.length >= 1 && others.every((x) => !x.published && !x.unapplied), `(d) the restated mined woke the resting threads: tm_ev2's admitted it, the first one's moved nothing (${others.length} other wake(s))`);

  // ------------------------------------------------ (e) rejected by Arcade: 400, the facts rejected
  const t2 = await token(fund, 1);
  const id2 = t2.id("hex");
  arcade.mode = "reject";
  const s2 = await post(t2.toBEEF());
  arcade.mode = "ok";
  const s2t = await s2.text();
  check(s2.status === 400 && /rejected/i.test(s2t), `(e) t2 rejected by Arcade: 400 (${s2.status} ${s2t.slice(0, 120)})`);
  check((await field(`chain/tx/${id2}`, "status")).join() === "pending,rejected", `(e) chain/tx pending, rejected (${await field(`chain/tx/${id2}`, "status")})`);
  check((await field(`overlay/topic/tx/${id2}`, "verdict")).join() === "rejected", `(e) overlay/topic/tx rejected (${await field(`overlay/topic/tx/${id2}`, "verdict")})`);

  // ------------------------------------------------ (f) a parent in flight, its child paused on it, woken by its verdict
  const p = await token(fund, 2);
  const c = await transfer(p, 0);
  const idp = p.id("hex");
  const idc = c.id("hex");
  arcade.mode = "busy";
  const pp = post(p.toBEEF()); // waits: no status while Arcade is busy
  await sleep(500);
  await r.settled();
  const both = new Beef();
  both.mergeBeef(p.toBEEF());
  both.mergeRawTx(c.toBinary());
  const pc = post(both.toBinaryAtomic(idc));
  await until("c undecided", async () => (await field(`overlay/topic/tx/${idc}`, "verdict")).includes("undecided") || undefined);
  check((await field(`overlay/topic/tx/${idc}`, "verdict")).join() === "undecided", "(f) the child, its parent in flight: undecided (paused, resting on the parent's verdict)");
  // 0.25.0 (case c): a second copy of the paused child — in flight already: a duplicate, ignored.
  const pc2 = post(both.toBinaryAtomic(idc));
  await sleep(500);
  await r.settled();
  arcade.mode = "ok";
  const [rp, rc, rc2] = await Promise.all([pp, pc, pc2]);
  await until("c admitted", async () => (await field(`overlay/topic/tx/${idc}`, "verdict")).includes("admitted") || undefined, 30_000);
  await r.settled();
  check((await field(`overlay/topic/tx/${idp}`, "verdict")).join() === "admitted", `(f) the parent admitted once Arcade took it (its request ${rp.status})`);
  check((await field(`overlay/topic/tx/${idc}`, "verdict")).join() === "undecided,admitted", `(f) the child woken by it, routed again, admitted (its request ${rc.status})`);
  check((await field(`overlay/topic/output/${idp}.0`, "state")).join() === "admitted,spent", `(f) the parent's token admitted, then spent by the child (${await field(`overlay/topic/output/${idp}.0`, "state")})`);
  const sp = (await events(`overlay/topic/output/${idp}.0`)).at(-1)!.record;
  check(sp.spentBy === idc, "(f) spentBy the child");
  const childThreads = (await overlayResults(store())).filter((x) => x.op === "submit" && x.txid === idc);
  const begunHere = (await overlayResults(store())).filter((x) => x.op === "woke" && x.outcome === "begun" && x.txid === idc);
  check(childThreads.length === 1 && begunHere.length === 1 && rc2.status === 200, `(f) two copies of the paused child: one submission thread, begun once in it (${childThreads.length} first step(s), ${begunHere.length} begun; the copy's request ${rc2.status})`);
  check((await field(`overlay/topic/tx/${idc}`, "verdict")).join() === "undecided,admitted", "(f) one verdict history for the child");

  // ------------------------------------------------ (g) case a: t2 rejected in (e), mined later — admitted on the same thread
  const h6 = mine(sha256d(h5), internal(id2), 1_790_302_600);
  await headers([h6]);
  // Arcade never took it (rejected at its broadcast): its proof comes as the host's pull delivers one
  // (skein 0.6.0, D3) — the proof event in box chain.
  await r.admitEvent(H, "chain", { kind: "proof", subject: txCid(id2), txid: id2, path: Uint8Array.from(new MerklePath(6, [[{ offset: 0, hash: id2, txid: true }]]).toBinary()) });
  await until("t2 mined", async () => (await field(`chain/tx/${id2}`, "status")).includes("mined") || undefined);
  await until("t2 admitted", async () => (await field(`overlay/topic/tx/${id2}`, "verdict")).includes("admitted") || undefined);
  await r.settled();
  check((await field(`chain/tx/${id2}`, "status")).join() === "pending,rejected,mined", `(g) chain/tx: pending, rejected, then mined — the latest fact (${await field(`chain/tx/${id2}`, "status")})`);
  check((await field(`overlay/topic/tx/${id2}`, "verdict")).join() === "rejected,admitted", `(g) the overlay admitted it after its rejection (${await field(`overlay/topic/tx/${id2}`, "verdict")})`);
  const t2Threads = new Set((await overlayResults(store())).filter((x) => x.txid === id2).map((x) => String(x.submission ?? "")).filter((x) => x));
  check(t2Threads.size === 1, `(g) on the same thread: one submission event (${t2Threads.size})`);
  check(await until("the topic's tip 6", async () => (await tipOf("tm_ev")) === 6 || undefined).catch(() => false) === true, `(g) placed: the topic's tip 6 (${await tipOf("tm_ev")})`);

  // ------------------------------------------------ (h) case e: a topic registered with the deploy's BEEF as its seed
  const t3 = await token(fund, 3);
  const id3 = t3.id("hex");
  await box.send(identity, "overlay/register", { fn: "register", args: { topic: "tm_seed", program: "topic-demo", seed: Uint8Array.from(t3.toBEEF()) } });
  await r.settled();
  await until("the seed admitted", async () => (await field(`overlay/topic/tx/${id3}`, "verdict")).includes("admitted") || undefined);
  await r.settled();
  check((await field(`chain/tx/${id3}`, "status")).join() === "pending,seen", `(h) the seed ingested by the chain app: chain/tx pending, seen (${await field(`chain/tx/${id3}`, "status")})`);
  const seeded = (await overlayResults(store())).filter((x) => x.admitted === true && x.txid === id3);
  check(seeded.length === 1 && JSON.stringify(seeded[0]!.steak ?? {}).includes("tm_seed"), "(h) admitted under tm_seed by its submission thread");
  const regs = (await overlayResults(store())).filter((x) => x.op === "register" && x.topic === "tm_seed");
  check(regs.length === 1 && regs[0]!.seed !== undefined && regs[0]!.seeded === undefined, "(h) the register step judged nothing: it sent the seed as a submission (`seed`, no `seeded`)");
  const h7 = mine(sha256d(h6), internal(id3), 1_790_303_200);
  await headers([h7]);
  arcade.emit(id3, proofAt(t3, 7, h7));
  await until("t3 mined", async () => (await field(`chain/tx/${id3}`, "status")).includes("mined") || undefined);
  check(await until("tm_seed's tip 7", async () => (await tipOf("tm_seed")) === 7 || undefined).catch(() => false) === true, `(h) mined later: placed, tm_seed's tip 7 (${await tipOf("tm_seed")})`);
  await sleep(500);
  await r.settled();
} catch (e) {
  check(false, `threw: ${(e as Error).stack}`);
} finally {
  const spec = store();
  await r.stop();
  await arcade.close();
  db.close();
  const rp = spawnSync("node", ["--experimental-strip-types", "--no-warnings", join(here, "replays.ts"), spec], { encoding: "utf8" });
  process.stdout.write(rp.stdout);
  if (rp.status !== 0) process.stdout.write(rp.stderr);
  check(rp.status === 0 && /identical .*the source store reproduced exactly/.test(rp.stdout), "the store replays to itself exactly");
}
if (process.env.KEEP) process.stdout.write(`kept ${home}\n`); else rmSync(home, { recursive: true, force: true });
process.stdout.write(failures ? `overlay-events (${BACKEND}): ${failures} FAILED\n` : `overlay-events (${BACKEND}): all ok\n`);
process.exit(failures ? 1 : 0);
