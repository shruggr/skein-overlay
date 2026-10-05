# Overlay services in the VM (0.4.0)

An overlay is an app (skein docs/APPS.md §6). It judges transactions with
its topic managers and indexes them with its lookup services; it does not
keep the chain. The chain state — headers, transactions, proofs, spends,
settlement, broadcasts — is global to an instance and has one writer, the
chain app ([shruggr/skein-chain](https://github.com/shruggr/skein-chain),
its docs/CHAIN.md), under `chain/state`. The overlay reads it by CID and
asks the chain app to take a transaction; what the chain app answers
(accepted, proven, rejected) is the overlay's gate.

A submitted transaction is decoded once into records (by the kernel's door, skein #121), checked against the
chain app's headers, then judged by topic managers. Topic managers are
programs. Lookup services are programs too, and they are pluggable in the
submission flow as topic managers are: the engine calls their hooks when a
topic admits a transaction, when a previous coin is spent, and when a
judgement is removed by a rejection, and each keeps its own indexes under
its own head. A lookup answers from those indexes.

**Everything the overlay writes is under its app's name** (skein #77: an app
writes only heads under its own name): `<app>/state` (what its topics
admitted), `<app>/gossip` (its peers' admits), `<app>/ls_<service>` (each
lookup service's index); its app record is `<app>/app`. Two overlay apps on
one instance — `overlay` and `amm`, say — therefore keep two sets of heads
and share the one chain: they coexist by construction.

Only the wire contract is taken from the standard libraries. That contract is
BRC-22 submit, BRC-24 lookup, and overlay-express's listing and documentation
routes. The go-sdk `overlay/` engine and ts-stack `packages/overlays`
storage are not ported.

**Not built:**

- BRC-88 SHIP/SLAP advertisement. Clients reach an instance through the
  `hostOverrides` / `facilitator` options of the @bsv/sdk clients.
- Sync between overlay nodes (GASP); catch-up from a peer. The push half —
  submissions, admits and proofs as they happen — is the gossip (#74, below).
- The `historical-tx` modes.
- BRC-64 history queries beyond "spent too" (`includeSpent`).

## Pieces

| where | what |
|---|---|
| `src/engine.zig` → `overlay.wasm` | The engine: called, the front door's route handlers (`routes.zig`); stepped, the submission's thread, a watch, a peer's admit. |
| `src/submit.zig` | A submission from the wire to the state: the route's half (decode, verify, judge — in the front door's step on the request), the submission's thread (the BEEF to the chain app; admitted on its answer), the watch. |
| `src/state.zig` | The overlay's state (`<app>/state`) over the chain state (read only): the maps, the previous coins, recording a judgement (`apply`), removing one (`unapply`), `inTopic`, `spender`; the door's pointer record read (`decodeRecord`, #121) or the one BEEF parse of bytes (`decode`), SPV over the records (`verifyDecoded`; BUMPs only for bytes), BEEF out for a lookup (`beefFor`, `beefOfMany`). |
| `src/calls.zig` | The configuration as the engine reads it (`configObject`, `listeners`, the app's name) and its calls of topics and lookup services (`Caller`, `hookAdmitted`, `hookRejected`). |
| `src/routes.zig` | The route handlers (#40): the overlay-express wire contract, and the gossip's inbound routes (`peerAdmit`, `peerProof`, #74). |
| `src/gossip.zig` | The three gossip topics (#74): message shapes, what an admission and a proof publish, a peer's proof checked, the peer-admit records. |
| `src/config.zig` | Where the engine's configuration comes from: its app record (`<app>/app`), else the genesis. |
| `src/engine_vm.zig` | The engine's wiring over the `skein` imports. |
| `src/topic.zig` | The topic contract — the module `topic`. |
| `src/lookup.zig` | The lookup contract: hooks, own storage, answers — the module `lookup`. |
| `src/vm.zig` | The `skein` imports as an overlay program sees them — the module `sk`. |
| `src/topic_demo.zig` → `topic-demo.wasm` | `tm_demo`, an example topic. |
| `src/lookup_demo.zig` → `lookup-demo.wasm` | `ls_demo`, an example lookup service with its own index. |
| skein's `kernel-zig/equiv/overlay.ts`, `install-overlay.ts` | End to end, with the `@bsv/sdk` clients (against a system-tree instance served at its origin root), over this repo's `bin/` (cloned at a pinned commit, or `$SKEIN_OVERLAY_DIR`). Part of skein's `equiv/run.sh`. |

Build and test (Zig 0.16.0, `mise.toml`):

```
zig build        # zig-out/bin/{overlay,topic-demo,lookup-demo}.wasm
zig build bin    # the same, into bin/ (committed)
zig build test   # the submission flow and the contracts, natively
```

The SDK (shruggr/skein-sdk v0.5.0) is a URL+hash dependency in
`build.zig.zon`; the overlay uses its `chain` module only (BEEF, SPV,
merkle paths, the store and its maps, and `state`: the chain app's
records), and bsvz comes through it. No chain tracker and no wallet
library are linked.

**The contract as Zig modules.** This package exports `topic`, `lookup`
and `sk`. An overlay app of its own — its topic managers and lookup
services — depends on skein-overlay by URL+hash, as on the SDK:

```zig
// build.zig.zon: .skein_overlay = .{ .url = "https://github.com/shruggr/skein-overlay/archive/refs/tags/v0.4.0.tar.gz",
//                                    .hash = "skein_overlay-0.4.0-IMuNgRwfFADMLyxiAIDkDNkH4RwJT5SRmG5rqnV1RSXE" }
const ov = b.dependency("skein_overlay", .{ .target = wasi, .optimize = .ReleaseSafe });
exe.root_module.addImport("topic", ov.module("topic"));   // pub fn main() u8 { return topic.main(identify); }
exe.root_module.addImport("lookup", ov.module("lookup")); // pub fn main() u8 { return lookup.main(spec); }
```

and ships the engine's module (`bin/overlay.wasm`, or `bin/overlay.cid`
for a module the instance holds) beside its own programs.

Paths below that are not this repo's (`docs/*.md`, `programs/frontdoor`,
`src/host/*`, `wasm/`, `equiv/*.ts`) are shruggr/skein's.

## A submission, from the wire to the state (#50)

**Decoded at the door** (shruggr/skein#121). The submit rows (`/<app>/submit`
and the libp2p `<topic>`) name `filter: "beef"`. Before the request's
entry is written, the kernel's door decodes the BEEF in its body (V1, V2,
Atomic or Outpoint; the subject is the Atomic or Outpoint one's, or else
the last) — each transaction stored once as its `bitcoin-tx` block (its
CID is its txid), each BUMP as the raw block of its bytes and the merkle
nodes it reveals — checks every BUMP against the headers in `chain/state`,
and puts the BEEF's **pointer record** where the bytes were: the handler's
`body` is that record's CID (skein-sdk `chain.record`; a bad BUMP is a
refusal entry and the handler never runs). The submit reads the record
(`state.decodeRecord`) and does **not** prove the BUMPs again. A body the
door did not take as a BEEF — framed with off-chain values (`VarInt(len) ‖
BEEF ‖ values`: no BEEF pattern leads it) — is decoded here once, into
records in the step's write cache (`state.decode`), and its BUMPs checked
here as before.

SPV for the rest (`state.verifyDecoded`), the previous coins and the topic
managers read typed records through `get` (the store, and the step's
write cache), and the chain state, read only (`head("chain/state")`):

- (bytes only) every BUMP's root is the chain app's header's merkle root at
  its height (an unknown height is refused), and each transaction a BUMP
  proves is reached from that root through the merkle nodes;
- every other transaction's inputs come from a transaction decoded before it
  or held by the chain app, with their scripts verified;
- a subject the chain app has rejected is refused (`TransactionRejected`),
  and so is one spending an output a proven transaction spends
  (`DoubleSpend`).

In a test build the SDK's `chain/src/beef.zig` counts its parses
(`beef.parses`); this repo's test.zig asserts one parse per submit of bytes (a pointer record is read, not parsed).

**Judge in the step.** For each requested topic this overlay serves and has
not judged the transaction for, the handler calls the topic's program (fn
`identify`, below) with the transaction's CID and its previous coins. The
topic reads the transaction and its inputs' sources through the same cache.

**Nothing moves until admitted.** If no topic takes anything (no output
admitted and no previous coin consumed), or every such topic's program fails,
or the transaction is one the chain app rejected, the handler answers **200
with the empty STEAK** (BRC-22 and overlay-express's answer; the reasons are
kept for the log) and starts nothing: the request is recorded, and no head
moves. Only a BEEF that does not decode or verify answers 400 `{status:
"error", message}`. A resubmission of a transaction every served topic judged
before (a dupe) is answered from the state at once; one of a transaction
pending (below) waits on the first submission's thread.

**The submission's thread.** Otherwise the handler launches the submission's
thread — the engine on the submit event (args `{event, box: "submit"}`) —
and answers `{wait: true}`: the request's thread waits on it (#66). (A
gossiped submission admits the same event into the app's box `<app>`
instead, and the app's row from `event` starts the same engine; its verdict
goes back at once.)

```
{kind: "submit", txid (hex), beef: <the pointer record's CID> | bytes (the BEEF as received, off-chain framing taken off),
 topics: [{topic, previousCoins, outputsToAdmit, coinsToRetain}], offChainValues?: bytes,
 source?: {transport, topic?, request}}
```

1. **To the chain app.** Its first step sends the instance itself (skein
   #79: a message to the instance's own key is looped back, from the
   instance) the chain app's ingest, box `chain`:

   ```
   {fn: "ingest", args: {beef}}     beef: the pointer record's CID (#121), or the bytes
   ```

   notes the submission `pending` (`<app>/state` map `pending`: `{kind:
   "submission", txid, thread, ingest: <the message>}`) and rests awaiting
   that message's answers. The chain app records the BEEF (SPV against its
   headers), and — unproven — registers its broadcast and broadcasts it: the
   overlay never broadcasts.
2. **The gate is the chain app's answer** (#73). Each answer is `{fn,
   request, replyTo: <the ingest message>, result: {txid, tx, state, …}}`
   (or `{…, error}`), the input `reply`:
   - `accepted` (a status provider's first word that is not a rejection) or
     `proven` (its proof, validated by the chain app against its headers) —
     the first of them **admits**: each judgement recorded (`apply`: the
     admittances and the `applied` record; the previous coins are taken
     again and, if they moved since the call, the topic is asked again),
     then each listening lookup service's hooks (`admitted`, then `spent`
     for each previous coin consumed), then the gossip out;
   - `rejected` (a status provider's rejection, a competing proof,
     abandonment, a rejected input) — nothing admitted;
   - an error answer (the chain app refused the ingest) — nothing admitted;
   - anything else — the thread awaits on.

   With no status provider, no status ever accepts it: it is admitted at its
   proof. Admission on validation alone is not a mode.
3. **It finishes** (#66), admitted or not: the requests waiting on it
   answer. Admitted on `accepted` (not yet proven), its last step sends the
   app itself a **watch**, box `<app>`:

   ```
   {fn: "watch", args: {txid (hex), ingest: <the ingest message>}}
   ```

**The watch.** The app's row from `$self` steps the engine on it. It reads
the chain state first — what the chain app said in between: proven →
`<topic>-proof` published, done; rejected → unwound, done — and otherwise
awaits the same ingest message (any thread awaiting a message the instance
sent gets its answers): `proven` publishes `<topic>-proof` (unless the
proof came by gossip: `via`); `rejected` **unwinds** — each served topic's
judgement of the transaction removed (`State.unapply`: its `applied`
record and its admittances) and each listening lookup service told
(`rejected`); then it finishes. No deadline: abandonment is the chain app's,
and reaches the watch as a `rejected` answer.

**Next (not built).** skein-overlay#1: submit walks the whole BEEF
oldest-first and judges every transaction of the topic before the subject
(known ones skip, unknown valid ones are admitted on the way, each ingested
through the chain app); a submission whose parent is neither in the BEEF nor
held pauses until something changes, and fetching it is a separate monitor
tool's. With it comes the decided direction of shruggr/skein#31 ("Decided
2026-10-02 (night)"): the one-shot watch becomes a registration for the life
of the transaction, there is no unwind as an action (whether an admission
counts is a read of the chain state), and a judgement is re-run when the
chain state it depended on changes.

**The answer** (#66). When the submission's thread comes to rest, the
request waiting on it calls the handler again (`resolved`), which reads the
answer from the state:

| state of the transaction | answer |
|---|---|
| admitted (or judged before) | 200, the STEAK from each topic's `applied` record (empty for a topic that took nothing) |
| still pending, or the chain app does not hold it (an error answer) | **503** `{status: "error", message}` with `Retry-After: 30`: nothing admitted; resubmit |
| rejected by the chain app | **400** `{status: "error", message: "Transaction rejected: <reason>"}` (overlay-express's error form) |

While the thread waits on the chain app the client waits too, up to the
host's bound (`answerWaitMs`, the host's `SKEIN_ANSWER_WAIT_MS`, default
two minutes): then 503 + `Retry-After` from the host, and
the thread goes on. A resubmission while pending waits on the same thread
(the pending record names it) and gets the same answer; after admission it
gets the STEAK at once. A resubmission of a rejected transaction is refused
in its call (`TransactionRejected`: 200, the empty STEAK).

## The state: `<app>/state`

```
{kind: "overlay-state", maps: {admitted, applied, pending}}
```

`tp` is len ‖ topic. The outpoint is txid (internal order) ‖ vout (u32 BE).

| map | key → value | |
|---|---|---|
| `admitted` | tp ‖ outpoint → admittance record | an output a topic admitted |
| `applied` | tp ‖ txid → applied record | the topic's judgement of this transaction: a later submission is a dupe; which previous coins it retained |
| `pending` | txid → submission record | handed to the chain app, not yet admitted (or rejected) |

**Records.**

- **Admittance:** `{kind: "admitted", topic, txid, vout, script, satoshis,
  admittedAt, tx: <tx CID>, refs: [{to: <tx CID>, rel: "admits"}]}`.
- **Applied:** `{kind: "applied", topic, txid, outputsToAdmit,
  coinsToRetain, coinsRemoved, at, tx, refs}`.
- **Submission:** `{kind: "submission", txid, thread, ingest}`.

The step keeps the admittance and applied records; their `refs` give the
kernel `admits` edges (docs/VM.md, "Edges"). Indexes for answering queries
are not here: each lookup service keeps its own (below).

**Nothing is derived from the chain, and nothing of the chain is copied.**
Whether an admitted output is spent is the chain state's `spent[outpoint]`
— the first transaction the chain app holds that spends it and is not
rejected (the kernel's `spends` edges) — read when asked: `inTopic`
(unspent first, then spent with `includeSpent`), `previousCoins`,
`spender`. A rejected spend gives the coins it consumed back by itself: the
chain's `spent` no longer counts it. The one bit a consumed table would
carry — whether the topic kept the coin for history — is the topic's
judgement of the *spending* transaction, its `applied` record
(`coinsToRetain`). `spender(topic, txid, vout)` gives both.

**Previous coins** (BRC-22's `previousCoins`) are the inputs that spend an
output live in the topic: admitted, and not spent by another transaction
the chain holds that is not rejected (the one being judged does not count).

**Retained and removed coins.** Both are spent. `coinsToRetain` keeps the
old output queryable for history (`includeSpent`). overlay-express deletes
the removed ones; here nothing is deleted, so a rejected spend gives them
back.

**Rejections.** The chain app rejects (a status provider's `REJECTED`,
`DOUBLE_SPEND_ATTEMPTED`, …; a competing proof; abandonment; an input
rejected) and answers its watchers; the overlay's submission thread or watch
removes the judgements of that transaction and tells the lookup services.
A spender of a rejected transaction is rejected by the chain app in turn
(`input-rejected`) and answered to its own watchers — the overlay's watch of
that spender, if it admitted it.

**Sync note (GASP, later).** Other overlay engines answer history /
`consumedBy` from per-topic tables. Here the answer is the chain's spends
joined to `applied`; wire answers for sync are to be derived from those.

## The engine (`overlay`)

Called (#40), the engine is the front door's route handlers (below, "The
wire"). Stepped:

| launched by | input | does |
|---|---|---|
| POST /submit (a launch), or the submit event in box `<app>` (the `libp2p:<topic>` route's admit, row from `event`) | `{kind: "submit", …}` | the submission's thread: the ingest message, pending; on each answer (`reply`) admit, reject or await on |
| a message in box `<app>` from the instance itself (row from `$self`) | `{fn: "watch", args: {txid, ingest}}` | the watch: the later proof (`-proof`) or rejection (unwound) |
| the `peer-admit` event in box `<app>` (the `-admit` route's admit) | `{kind: "peer-admit", …}` | recorded under `<app>/gossip` ("Gossip", below); nothing admitted |

A message in box `<app>` from anyone else is refused. There is no `lookup`
box: a lookup is a read: its request is recorded, and it moves nothing.

**Config.** An installed engine reads its configuration from its app
record (skein #72, #77; `src/config.zig`), at every step and call: the root
of the head `<app>/app`, `{kind: "app", programs: {<role>: <program
record>}, config: {overlay: {topics, lookups, gossip?}}, …}`, that
`skein-host install` wrote. It finds it through its own program record,
which the install gives `app: <name>`: in a step, the thread's `program`;
in a route's call, the matched dispatch row's `program` (`match`). The same
name is where its heads are (`<name>/state`, …). A reinstall with a changed
`config.overlay` is read at the next step or call; nothing restarts.

- `config.overlay.topics = {"tm_demo": "topic-demo"}` maps each topic to a
  role in `programs`.
- `config.overlay.lookups = {"ls_demo": {"program": "lookup-demo",
  "topics": ["tm_demo"]}}` maps each lookup service to a role and the
  topics it listens to. The short form `{"ls_demo": "lookup-demo"}` listens
  to every topic the overlay serves.
- `config.overlay.gossip = {"tm_demo": false}` turns a topic's gossip
  publishing off (#74; default on).

There is no `status` (statuses are the chain app's) and no admission
setting (#73).

**The fallback: a genesis-wired engine.** An engine whose program record
names no app (a system tree's `bin/overlay.wasm`, booted with the
instance), or a host's call with no row, reads the genesis `defaults`
(`etc/config.json`) instead, the same mappings as JSON in strings, the
program names the genesis's: `overlayTopics = '{"tm_demo":"topic-demo"}'`,
`overlayLookups = '{"ls_demo":{"program":"lookup-demo","topics":["tm_demo"]}}'`,
`overlayGossip = '{"tm_demo": false}'`. Its heads are under its program's
name (`overlay/…`), which the tree's `scopes` must grant. `walletNetwork`
is the network of a chain state not written yet (the chain app's record
says its own).

**The wiring is derived from `config.overlay`** (skein docs/APPS.md §6):
`skein-host install` adds, for each topic, the libp2p rows `<topic>` →
`submit`, `<topic>-admit` → `peerAdmit`, `<topic>-proof` → `peerProof`
(sender `*`); the http rows `/submit` and `/lookup` (open, under
`/<app>/`); and the mailbox rows `<app>` from `event` (the routes'
admitted events) and from `$self` (its own watch) — all to the role
`overlay`. The manifest lists the listing and documentation routes and
`requires: ["chain/1"]`: the chain app must be installed.

**Result.** Each step keeps a result record and prints its CID:

- `{kind: "overlay-result", op: "submit" | "answer" | "watch" | "watched",
  txid, ingest, heard?, admitted?, steak?: {topic: {outputsToAdmit,
  coinsToRetain, coinsRemoved}}, unapplied?: [topic], watch?, published?,
  awaiting?, refs (mentions), state}`;
- `{kind: "overlay-result", op: "peer-admit", topic, txid, record, state}`;
- `{op, error}` when the step fails.

A topic whose instructions do not fit the transaction admits nothing.

## The topic contract

A topic manager is a program called, not launched: an in-VM call of fn
`identify`, in the `/submit` call (and, only if its previous coins moved, in
the admitting step), with the argument

```
{kind: "topic-call", topic, tx: <bitcoin-tx CID>, previousCoins: [input index], offChainValues?}
```

It answers (dag-cbor on stdout)

```
{kind: "admittance", topic, txid, outputsToAdmit: [output index], coinsToRetain: [input index]}
```

That is `identify(tx: cid, previousCoins, offChain?) → {outputsToAdmit,
coinsToRetain}`, BRC-22's `identifyAdmissibleOutputs` on a CID instead of a
BEEF. With the module `topic`, a topic is only its identify function:

```zig
const topic = @import("topic");
pub fn identify(a: std.mem.Allocator, call: topic.Call) anyerror!topic.Instructions { … }
pub fn main() u8 { return topic.main(identify); }
```

`Call` carries the transaction (decoded from its block, read through `get`),
its CID, the previous coins, the off-chain values, and `sourceOutput(i)` /
`transaction(txid)`, which read other transactions through `get` as well.

**Metadata and documentation** are the program's own (the TopicManager's
`getMetaData` and `getDocumentation`, as in the Go and TypeScript engines).
The listing and documentation routes call fn `metadata` or fn
`documentation` with `{kind: "topic-describe", topic}`; the answers are

```
{kind: "metadata", name, shortDescription, iconURL?, version?, informationURL?}
{kind: "documentation", documentation: <markdown>}
```

A program may define, beside `main`,

```zig
pub fn metadata(a: std.mem.Allocator, topic_name: []const u8) anyerror!topic.Metadata { … }
pub fn documentation(a: std.mem.Allocator, topic_name: []const u8) anyerror![]const u8 { … }
```

and `topic.main` finds them. One it does not define answers the default:
`name` the configured topic name, `shortDescription` and the documentation
empty. How a program answers is its own: a literal in the code, or a file
it reads from its tree. The engine reads no file.

**`tm_demo`.** An output whose script starts `<"tm_demo"> OP_DROP` and
carries at least 1 satoshi is a token, and every token is admitted. A
transaction that admits a token retains the tokens it spends. One that admits
none removes them. It answers its metadata and documentation with literals.

## The lookup contract (#50)

A lookup service is a program with its own storage and four functions, all
in-VM calls. The hooks are called by the engine in the step that admits a
submission or removes a judgement; they receive CIDs, never bytes, and read
the transactions through `get`. Every call names `app`, the app the engine
runs as:

| fn | argument | when |
|---|---|---|
| `admitted` | `{kind: "lookup-hook", app, service, topic, tx: <CID>, outputsToAdmit: [vout], coinsRetained: [input index]}` | a topic it listens to admitted a transaction (or consumed previous coins) |
| `spent` | `{kind: "lookup-hook", app, service, topic, outpoint: {tx: <CID>, vout}, spendingTx: <CID>}` | for each previous coin that transaction consumed (retained or removed) |
| `rejected` | `{kind: "lookup-hook", app, service, topic, tx: <CID>}` | a judgement of that topic was removed by a rejection |
| `lookup` | `{kind: "lookup-call", app, service, query}` | `POST /lookup`: a read |

A hook may be a no-op. **Own storage:** a service keeps named maps (the
SDK chain library's `store.zig`) under its own head `<app>/ls_<service>`
(`ls_demo` → `<app>/ls_demo`), a record `{kind: "lookup-state", service,
maps: {name: root | null}}`. A head under its app's name: the kernel lets
the service's program write it (its program record names the same app). The
maps are written only through the hooks: a hook that changes them puts the
new nodes and state record and advances the head. `lookup` reads them (and
the chain state, read only, for the BEEF), and writes nothing.

The `lookup` answer (dag-cbor on stdout) is one of:

```
{kind: "lookup-answer", type: "output-list", outputs: [{beef, outputIndex, context?}]}
{kind: "lookup-answer", type: "freeform", result}
```

Each `beef` is the Atomic BEEF of the output's transaction, built from the
chain app's records (`chain.state.State.beefOf`): the ancestry back to
proven transactions, with their BUMPs. The query is the client's JSON as
dag-cbor; integers only.

With the module `lookup`, a service is a `Spec`:

```zig
const lookup = @import("lookup");
pub const spec: lookup.Spec = .{
    .maps = &.{ "outputs", "byTopic", "byScript" },
    .answer = answer,       // (arena, *Service, *lookup.Chain, query) !Answer
    .admitted = admitted,   // (arena, *Service, topic, Tx, outputs_to_admit, coins_retained) !void
    .spent = spent,         // (arena, *Service, topic, Outpoint, spending: Tx) !void
    .rejected = rejected,   // (arena, *Service, topic, Tx) !void
};
pub fn main() u8 { return lookup.main(spec); }
```

`Service.map(name)` is one of its maps; `lookup.handle` runs one call over a
given store and heads (the tests call it directly).

**Metadata and documentation** are the service's own, as for a topic
manager (the LookupService's `getMetaData` and `getDocumentation`): fn
`metadata` or fn `documentation` with `{kind: "lookup-describe", app,
service}`, answered from `pub fn metadata(a, service) !lookup.Metadata` and
`pub fn documentation(a, service) ![]const u8` if the program defines them,
else the default (`name` the configured service name, the rest empty). The
same answers as a topic's; no state is loaded for them.

**`ls_demo`** keeps its own index through the hooks:

| map | key → value |
|---|---|
| `outputs` | tp ‖ outpoint → sha256(locking script) [‖ spending txid] |
| `byTopic` | tp ‖ 0 (unspent) \| 1 (spent) ‖ outpoint → null |
| `byScript` | sha256(locking script) ‖ tp ‖ 0 \| 1 ‖ outpoint → null |

`admitted` adds the admitted outputs (unspent); `spent` moves an output to
spent and names its spender; `rejected` drops the rejected transaction's
outputs and gives back the ones it had spent. It answers from these maps
alone: `{topic}`, `{scriptHash (hex sha256 of the locking script),
topic?}`, `{txid, outputIndex, topic}`, each with `includeSpent` for spent
outputs too. It answers its metadata and documentation with literals.

## The wire: the instance's own front door (#40)

The overlay is served by the instance itself: its front door
(`programs/frontdoor`) matches the request against the dispatch table's
http rows and calls the engine's handler with it. The rows are open (sender
`*`), as overlay-express is, and under the app's prefix: the app's BRC-23
base URL is `https://<handle>.<host>/<app>` (on a host without wildcard
DNS, `/@<handle>/<app>` on the host's origin), and a client calls
`${baseUrl}/submit` (`POST https://alice.skein.nexus/overlay/submit`). The
@bsv/sdk `TopicBroadcaster` and `LookupResolver` reject a base URL with a
path, so they work only against an overlay served
at an origin's root (a system tree, below); skein does not use them for
overlay apps.

| route | fn | | answer |
|---|---|---|---|
| `POST /submit` | `submit` | body BEEF (`application/octet-stream`); `X-Topics` a comma list (the SDK's form) or a JSON array; `x-includes-off-chain-values: true` → VarInt(len) ‖ BEEF ‖ values | the STEAK `{topic: {outputsToAdmit, coinsToRetain, coinsRemoved}}` over the requested topics this overlay serves; 400 `{status: "error", message}` if refused or rejected; 503 with `Retry-After` while it is undecided |
| `POST /lookup` | `lookup` | `{service, query}` JSON; `X-Aggregation: yes` | `{type: "output-list", outputs: [{beef: [bytes], outputIndex, context?}]}`, or the compact octet-stream (count, per output txid ‖ index ‖ context, then one BEEF of them all, `state.beefOfMany`); a freeform answer as `{type, result}` |
| `GET /listTopicManagers`, `/listLookupServiceProviders` | `listTopicManagers`, `listLookupServiceProviders` | | `{name: {name, shortDescription, iconURL?, version?, informationURL?}}`: each configured topic's or service's fn `metadata` |
| `GET /getDocumentationForTopicManager?manager=`, `/getDocumentationForLookupServiceProvider?lookupService=` | `topicDocumentation`, `lookupDocumentation` | | `text/markdown`: its fn `documentation`; 400 if not configured |

**A submit is the one write**, and only when a topic takes the transaction
(above).

**The same submit over GossipSub** (#57). The libp2p row `<topic>` names the
same fn. The front door verifies the message's signature (docs/MESSAGES.md,
"libp2p") and calls `submit` with it; the handler sees `transport:
"libp2p"` and takes the message's topic as the one requested, its body as
the BEEF (no off-chain values), and runs the same route half. Its answer is
the libp2p handler contract: **accept** admitting the submit event into box
`<app>` (after the message's own `p2p` entry), so the step persists exactly
what the HTTP path does, through the same gate; **ignore** (no forward, no
penalty) when the topic is not served, nothing is new (a dupe, no topic
takes it, or it is pending) or the BEEF is refused — a refusal may be this
instance's missing headers rather than the publisher's fault.

**A lookup writes nothing.** The handler calls the service's program and
shapes its answer for the wire. Listings and documentation call the
programs too (fn `metadata`, fn `documentation`) and read no file; a call
that fails answers 500.

**The STEAK.** It carries exactly the three fields the @bsv/sdk client accepts
(`validateSTEAK` refuses any other field).

## Gossip: the three topics (#74)

For each overlay topic `<topic>` it runs, an overlay speaks three GossipSub
topics, three meanings (`src/gossip.zig`). Bodies are dag-cbor unless said;
a txid and a block hash are hex in display order.

| topic | body | published | received (row → fn) |
|---|---|---|---|
| `<topic>` | the raw submission: the BEEF as received (bytes, not dag-cbor) | after this overlay **admits** a submission that did not arrive by gossip on `<topic>` | `<topic>` → `submit`: judged as any submission (#57) |
| `<topic>-admit` | `{txid, topics: {<topic>: {outputsToAdmit: [vout], coinsToRetain: [input index]}}}` — the STEAK and the txid, **no BEEF** | on admission, every time (also for a submission that arrived by gossip) | `<topic>-admit` → `peerAdmit`: recorded, never admits |
| `<topic>-proof` | `{txid, blockHash, blockHeight, bump: bytes}` — `bump` the BRC-74 path of this txid alone | when the chain app answers that a transaction a topic admitted is **proven**, unless that proof came by gossip (`via`) | `<topic>-proof` → `peerProof`: checked, then the proof-in path |

**Publishing.** A message to the libp2p provider, box `publish`, body
`{topic, body}` (docs/MESSAGES.md, "The providers"), emitted from the step
and not awaited. With no libp2p provider in the address book nothing is
published. The raw submission is the submit event's `beef` (the off-chain
values do not travel): from its pointer record, the exact bytes received,
re-encoded by skein-sdk's `chain.record.beefOf` (#121). A submission that arrived by gossip on `<topic>` is
not re-published there; a proof that arrived on `<topic>-proof` is not
re-published. The proof is the chain app's: the BUMP rebuilt from its
merkle nodes (`State.proofFor`), one txid's path, no compound BUMP. It is
published once per transaction, at the `proven` answer the overlay hears; a
reorg's re-proof is the chain app's business and is not re-published.
**Statuses never propagate.**

**Receiving `-admit`** (`peerAdmit`): the topic must be one this overlay
serves and the body that shape, else `ignore`. Accept admits a `peer-admit`
event into box `<app>`; the engine records it under the head `<app>/gossip`:

```
{kind: "overlay-gossip", maps: {peerAdmits: <MST root> | null}}
peerAdmits: tp ‖ txid (internal order) ‖ from → {kind: "peer-admit", topic, txid (hex), from: bytes(33) (the publisher's peer key),
                                                 outputsToAdmit, coinsToRetain}
```

A later admit from the same peer for the same transaction replaces the
record. It is a read and **never admits anything**.

**Receiving `-proof`** (`peerProof`): the proof-in wiring of #65 for the
topics this overlay runs. In the call (read only), against the chain state:
the topic is served; the transaction is admitted under it, or pending here;
the chain app holds it and has not proven it in that block; the BUMP parses,
is at `blockHeight` and flags the txid; the chain's header at `blockHeight`
has the hash `blockHash`, and its merkle root is the BUMP's root. Then
accept, admitting the proof event into box `chain` — the chain app's event
row, as the host's broadcaster admits one — plus `via`:

```
event (box "chain")  {kind: "proof", subject: <tx CID>, txid, path: <the bump>, blockHash, blockHeight, via: "libp2p:<topic>-proof"}
```

The chain app records it and answers the transaction's watchers `proven`
with `via`: a pending submission is admitted at it (#73), and nothing is
re-published. Anything else is **`ignore`, never `reject`**.

**Late duplicates.** A `<topic>` message GossipSub's seen-cache has
forgotten is the same record as before: the front door answers `ignore`
with nothing run. The same BEEF in a new message is decoded once, looked
up, and answered `ignore` "already judged" (or "already submitted: awaiting
the chain app" while pending): no topic manager runs.

**Config.** `config.overlay.gossip` (genesis-wired: `defaults.overlayGossip`):
`{"<topic>": false}` turns a topic's publishing off; the default is on.

**Not built:** catch-up (asking a peer for its admitted set, or proofs by
block — the pull half of #44–#48).

## Two overlays on one instance

Each overlay app is its own name: its heads (`<name>/state`,
`<name>/gossip`, `<name>/ls_<service>`, `<name>/app`), its box (`<name>`),
its http rows (`/<name>/submit`, …). They share the chain (both read
`chain/state`, both ingest through the chain app) and nothing else. A
transaction both judge is ingested twice — the chain app records it once and
answers both — and each admits it on its own answer. Two overlays that run
the same overlay topic on one instance would both claim its libp2p rows
(the same key): give them different topics, or different instances.

## A system tree for an overlay node

Installed as an app (`skein-host install https://github.com/shruggr/skein-overlay
--instance <h>`, beside the chain app), the overlay needs none of this. A
system tree wires the engine and the chain app into an instance's genesis
instead (the fallback above; skein docs/BOOTSTRAP.md has the file formats):

```
bin/frontdoor.wasm, bin/chain.wasm (shruggr/skein-chain), bin/overlay.wasm, bin/topic-demo.wasm, bin/lookup-demo.wasm
etc/config.json     {"defaults": {"walletNetwork": "regtest", "overlayTopics": "{\"tm_demo\":\"topic-demo\"}",
                                  "overlayLookups": "{\"ls_demo\":{\"program\":\"lookup-demo\",\"topics\":[\"tm_demo\"]}}"},
                     "scopes": {"overlay": ["overlay/"], "lookup-demo": ["overlay/"]}}
                     (+ "libp2p": {"topics": ["tm_demo", "tm_demo-proof"]} to take part in the gossip, #74)
etc/dispatch.json   the chain app's rows (box chain from event, from $self, from $owner; status from $status),
                    {"address": "overlay", "sender": "event", "program": "overlay"},
                    {"address": "overlay", "sender": "$self", "program": "overlay"},
                    http /submit, /lookup and the listing rows (sender "*") and the libp2p rows tm_demo,
                    tm_demo-admit, tm_demo-proof (sender "*") to the program overlay with their fn
```

The front door must be in `bin/` (a tree's programs are its own). The
lookup service's program writes `overlay/ls_demo`, so the tree grants it
the prefix too. The config names no broadcaster and no status provider: they
are the chain app's.
