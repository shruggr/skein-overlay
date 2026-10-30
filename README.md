# skein-overlay

The overlay services engine for a [skein](https://github.com/shruggr/skein),
as an app: BRC-22 submit and BRC-24 lookup, served by the instance's own
front door, with topic managers and lookup services as programs the engine
calls. It is also a Zig package: an overlay of your own depends on it for
the topic and lookup contracts. Version **0.19.0**.

## What it is

- **The engine** (`bin/overlay.wasm`): two ways to submit. `POST /submit`
  is BRC-22: the request waits on the submission's thread and answers the
  STEAK (0.9.1). A submission by message, `{fn: "submit", args: {beef,
  topics}}`, into the app's box `<app>/submit`, is answered by message. The engine decodes
  the BEEF once, asks the topic managers to judge it by CID, and hands it to
  the chain app ([shruggr/skein-chain](https://github.com/shruggr/skein-chain),
  required as `chain/1`) with `ingest`. It is admitted on the chain app's
  first `accepted` or `proven` answer. A message's submitter is answered by message,
  in its own box: **admitted** (status `pending`, the STEAK per topic), then
  **every proof**, or **rejected**. Nothing persists unless a topic takes
  it, apart from the request. `/lookup` is a read.
- **State under its own name.** The engine and its lookup services write
  only `<app>/state`, `<app>/gossip`, `<app>/topics`, `<app>/lookups`, `<app>/configured` and
  each lookup program's index `<app>/ls_<…>`; the app record is `<app>/app`. The chain state is the chain app's `chain/state`, read by
  CID. Two overlay apps on one instance share the chain and nothing else.
- **Gossip** over libp2p, per topic (0.12.0, David 2026-10-09): `<topic>`,
  one mesh for two kinds of dag-cbor message, `{kind: "submit", beef}` (the
  raw submission) and `{kind: "admit", txid, topics}` (the verdict);
  `<topic>-proof` (the proofs) on its own; `<topic>-live` the beats, the
  runtime's liveness tool (unlogged).
- **Beats** (0.12.0): every skein is a market and a validator, always. Each
  registered or (0.17.0) configured topic beats on `<topic>-live` with its view digest (and the
  app's terms: the head `<app>/terms` when it has written them, else
  `config.overlay.terms`), and each registered or configured lookup service on `<service>-live`
  with a body its program gives; the skein keeps liveness on both ("Beats"
  below).
- **The examples**: `tm_demo` (`bin/topic-demo.wasm`) and `ls_demo`
  (`bin/lookup-demo.wasm`).

Exported Zig modules:

| module | file | what |
|---|---|---|
| `topic` | `src/topic.zig` | the topic manager contract: `pub fn main() u8 { return topic.main(identify); }` |
| `lookup` | `src/lookup.zig` | the lookup service contract: `pub fn main() u8 { return lookup.main(spec); }` |
| `sk` | `src/vm.zig` | the `skein` imports as an overlay program sees them |

They pull in the SDK's `chain` module only.

**What is built and where it goes.** Submit walks the whole BEEF oldest
first and judges every transaction of the requested topics before the
subject; each one a topic takes is ingested through the chain app on its
own and admitted, in order, on its own answer (skein-overlay#1). A
submission whose parent is neither in the BEEF nor held pauses, however it
came: it is noted pending, waiting on those parents, and the engine records
a want per (parent, topic, peer?) — `{event: "want", txid, topic, peer?}`
(shruggr/skein#112). With a peer (a gossip pause: the publisher, and every
peer whose `admit` for it was seen, more as admits arrive) the host asks
that peer on a direct stream; without one (a submission by message or
HTTP) it asks peers from its mesh for the topic. Each want that ends is
cleared by `{event: "unwant", txid, topic, peer?}`. A peer answers a want
on the stream `/skein/overlay/beef/1.0.0` (one Atomic BEEF per frame, the
wanted txid its subject; no reply frame), routed to `submit` as a
submission from that peer; when the parent is in, the paused one is routed
again. A submission whose parent is held but not yet admitted (in flight:
its own submission handed to the chain app, the answer not in) pauses on
it the same way, with no want — nothing to ask anyone for — and is routed
again when the chain app answers for that parent: judged with the parent's
outputs admitted, refused on the merits if the parent was rejected, or
paused again for what it still lacks (skein-overlay#6). A transaction a
topic manager cannot decide — it fails `MissingParents`, naming the input
sources it cannot read — pauses the same way and wants those (0.19.0): no
verdict, nothing rejected, judged again as each arrives. The pause is
internal: the submitter hears nothing of it. A
transaction admitted on `accepted` sends the app itself a `watch`, which
waits for `proven` (publishes `-proof`) or `rejected` (unwinds); with a
submitter to answer, each proof is relayed and a new watch waits for the
next (a reorg's). Not built: the decided direction of shruggr/skein#31
("Decided 2026-10-02 (night)"): a reference to a transaction is a
registration for the life of the transaction, and a judgement is re-run
when the chain state it depended on changes.

## Use it

Install the chain app, then the overlay:

```
skein-host install https://github.com/shruggr/skein-chain --instance <handle>
skein-host install https://github.com/shruggr/skein-overlay --instance <handle>
```

The chain app proves nothing without the host's headers feed and broadcasts
nothing without its broadcaster; shruggr/skein-chain's README, "Use it",
has what the host must provide.

Its BRC-23 base URL is `https://<handle>.<host>/<app>`; on a host without
wildcard DNS (local dev) the router also serves it as `/@<handle>/<app>` on
the host's origin. Its endpoints are under it: `POST <base>/submit`
(`POST https://alice.skein.nexus/overlay/submit`, or
`POST http://127.0.0.1:8100/@alice/overlay/submit`), a route that takes a
signed request (BRC-104) from any key, or an unsigned one whose BEEF
validates (skein's front door, shruggr/skein#135); and the
reads, open to anyone, signed or not: `POST <base>/lookup` and the listing
and documentation paths (shruggr/skein#135). The @bsv/sdk
`TopicBroadcaster` and `LookupResolver` reject a base URL with a path, so
call the endpoints directly (`POST <base>/submit` with the BEEF and
`X-Topics`), or have root add the two root routes that answer them at
the origin's root ("Root routes", below). `/submit` answers BRC-22's STEAK once the submission is
decided (503 + `Retry-After` when nothing is decided within the host's
bound; resubmit to poll the same flow): docs/OVERLAY.md, "Submitting".

### Write an overlay of your own

An overlay app is a tree with the engine's module, your topic managers and
lookup services, and `etc/app.json` naming them in `config.overlay`.

`build.zig.zon`:

```zig
.dependencies = .{
    .skein_overlay = .{
        .url = "https://github.com/shruggr/skein-overlay/archive/refs/tags/v0.4.0.tar.gz",
        .hash = "skein_overlay-0.4.0-IMuNgRwfFADMLyxiAIDkDNkH4RwJT5SRmG5rqnV1RSXE",
    },
},
```

`build.zig`:

```zig
const wasi = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
const ov = b.dependency("skein_overlay", .{ .target = wasi, .optimize = .ReleaseSafe });
const exe = b.addExecutable(.{
    .name = "topic-mine",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/topic_mine.zig"),
        .target = wasi,
        .optimize = .ReleaseSafe,
        .strip = true,
        .imports = &.{.{ .name = "topic", .module = ov.module("topic") }},
    }),
});
b.installArtifact(exe);
```

A topic manager is its identify function. `tm_demo` in full
(`src/topic_demo.zig`):

```zig
const std = @import("std");
const topic = @import("topic");

pub const tag = "\x07tm_demo\x75"; // push "tm_demo", OP_DROP

pub fn isToken(script: []const u8, satoshis: i64) bool {
    return satoshis >= 1 and script.len > tag.len and std.mem.startsWith(u8, script, tag);
}

pub fn identify(a: std.mem.Allocator, call: topic.Call) anyerror!topic.Instructions {
    var admit: std.ArrayList(u32) = .empty;
    for (call.tx.outputs, 0..) |o, i| if (isToken(o.locking_script.bytes, o.satoshis)) try admit.append(a, @intCast(i));
    return .{ .outputs_to_admit = admit.items, .coins_to_retain = if (admit.items.len > 0) call.previous_coins else &.{} };
}

pub fn main() u8 {
    return topic.main(identify);
}
```

`topic.Instructions` also has `ancillary_txids` (skein-overlay#4, the
shape of go-overlay-services' `AdmittanceInstructions.AncillaryTxids`): the
transactions the topic read and relied on that it does not admit, such as
the funding parents that fix a 1Sat ordinal's satoshi offset on a transfer.
The answer carries them as `ancillaryTxids: [<txid hex>]` (omitted when
empty). Each must be in the submitted BEEF or held, or the engine refuses
the judgement (`UnknownAncillary`). The engine keeps them on the
admittance (`ancillary`, a `mentions` ref each), and the read
`GET /holds?txid=` answers `{txid, tx, via: "admitted" | "retained" |
"ancillary" | "judged", outpoint?: {txid, vout}, beef?}` (or `{}`) for a
peer's want: `judged` is a transaction the topic took that admitted no
output of it, and `beef` the chain state's Atomic BEEF of it, hex
(docs/OVERLAY.md "Holds").

A lookup service is a `lookup.Spec` (its map names, `answer`, and the
`admitted` / `spent` / `rejected` hooks); `src/lookup_demo.zig` is a complete
one with its own index.

Either may also define `pub fn metadata(a, name) !topic.Metadata` (or
`lookup.Metadata`: name, shortDescription, iconURL?, version?,
informationURL?) and `pub fn documentation(a, name) ![]const u8`
(markdown); the listing and documentation reads call them. Without them it
lists under its configured name with an empty description. Where the text
comes from (a literal, a file in the tree) is the program's own.

The manifest (`etc/app.json`, this repo's own, description left out):

```json
{
  "kind": "app",
  "name": "overlay",
  "version": "0.16.1",
  "programs": {
    "overlay": "bin/overlay.wasm",
    "topic-demo": "bin/topic-demo.wasm",
    "lookup-demo": "bin/lookup-demo.wasm"
  },
  "config": {
    "overlay": {
      "topics": { "tm_demo": "topic-demo" },
      "lookups": { "ls_demo": { "program": "lookup-demo", "topics": ["tm_demo"] } },
      "gossip": { "tm_demo": true }
    }
  },
  "requires": ["chain/1"],
  "filters": {
    "listTopicManagers": "overlay.listTopicManagers",
    "listLookupServiceProviders": "overlay.listLookupServiceProviders",
    "topicDocumentation": "overlay.topicDocumentation",
    "lookupDocumentation": "overlay.lookupDocumentation",
    "holds": "overlay.holds",
    "anchors": "overlay.anchors",
    "admitted": "overlay.admitted",
    "sync": "overlay.sync"
  },
  "roles": { "root": ["register", "registerLookup", "deregisterLookup"] },
  "routes": [
    {"address": "register", "handler": "overlay.register"},
    {"address": "submit", "filters": ["kernel.beef"], "handler": "overlay.submit"},
    {"transport": "libp2p", "address": "/skein/overlay/beef/1.0.0", "filters": ["kernel.beef"], "handler": "overlay.submit"},
    {"transport": "http", "address": "/listTopicManagers", "filters": ["listTopicManagers"]},
    {"transport": "http", "address": "/listLookupServiceProviders", "filters": ["listLookupServiceProviders"]},
    {"transport": "http", "address": "/getDocumentationForTopicManager", "filters": ["topicDocumentation"]},
    {"transport": "http", "address": "/getDocumentationForLookupServiceProvider", "filters": ["lookupDocumentation"]},
    {"transport": "http", "address": "/holds", "filters": ["holds"]},
    {"transport": "http", "address": "/anchors", "filters": ["anchors"]},
    {"transport": "http", "address": "/admitted", "filters": ["admitted"]},
    {"transport": "libp2p", "address": "/skein/overlay/sync/1.0.0", "filters": ["sync"]}
  ]
}
```

The format is skein's routes, filters and roles (shruggr/skein#143,
docs/APPS.md §2): a route names a transport, an address, its filters and a
handler, and no sender; who may run a function is `roles`.

- `programs.overlay` is the engine: copy `bin/overlay.wasm` from this repo
  into your tree (or `bin/overlay.cid` when the instance already holds it).
  The engine is the role `overlay`.
- The rest of the wiring is derived from `config.overlay` by the install:
  the http route `/submit` (`kernel.beef`, handler `overlay.submit`), the
  read route `/lookup` (its filter `lookup`, which the install adds to
  `filters` as `overlay.lookup` unless the manifest names its own), the
  libp2p routes `<topic>` (`kernel.beef`), `<topic>-admit`, `<topic>-proof`,
  and the app's box `<app>` twice, an `event` route and a `mailbox` route.
  (skein's install still derives `<topic>-admit` for a declared topic; since
  0.12.0 nothing publishes there — the verdicts are `admit` messages on
  `<topic>` — and a message that arrives there is read as one.)
  The install prompt reads them all aloud, marked derived.
- Read routes (shruggr/skein#143). An http route with no handler is a
  **read**: its filters answer and nothing is logged. The overlay's reads
  are `/lookup` (derived), the four listing and documentation paths,
  `/holds`, `/anchors` and `/admitted` above, each with the engine's function as its filter. Called as a filter
  (the input's `filter: true`), the engine answers `{answer: {status,
  type, body}}`, the same http answer as before inside it; anyone, signed
  or not. A read route names no program, so the engine finds its app by
  the route's `app` (src/config.zig `matchedApp`). The libp2p row
  `/skein/overlay/sync/1.0.0` is a read too: its filter `sync` answers each
  frame (0.15.0, "Anchors" below).
- One box per function class (shruggr/skein#128), three boxes:
  `<app>/submit` for submissions, `<app>/register` for registration, `<app>`
  for the engine's own events and messages.
- The route `submit` (`<app>/submit`, `kernel.beef`: anyone whose BEEF
  validates) is where submissions by message arrive (`{fn: "submit", args:
  {beef, topics}}`; the door decodes the BEEF). The answers go to the
  sender in that box. `POST /submit` (the derived http route) runs in the
  request's step and waits; its threads and `wait` messages use the derived
  `<app>` routes.
- The route `register` (`<app>/register`, handler `overlay.register`) takes
  `register` / `deregister` and `registerLookup` / `deregisterLookup`; they
  are refused in any other box. (The `market` / `validator` switches of
  0.9.2 are gone, 0.12.0.) `roles: {root: ["register", …]}` gates it:
  only a key holding root runs it (a message from any other key is
  recorded and runs nothing). Root may grant the function to others with
  an app role of its own; the manifest declares none.
- The derived routes on `<app>` take the libp2p routes' admits (a gossiped
  or streamed submission's routed event, a peer's admit; the `event`
  route) and the engine's own `watch`, `resume` and `wait` (the `mailbox`
  route, by the host's loopback). The engine takes only the instance's
  own messages there (`NotFromThisInstance` otherwise). An app that puts
  another program on its box `<app>` overrides the derived mailbox route
  and breaks those: keep `<app>` the engine's.
- The libp2p route `/skein/overlay/beef/1.0.0` is the want-answer stream
  (shruggr/skein#112): a peer the engine wants a parent from answers on
  it, one Atomic BEEF per frame; the door decodes it (`kernel.beef`)
  and `submit` takes it as a submission from that peer. Keep it in your
  manifest for catch-up to work.
- The name rule: every head your programs write is under your app's name.
  Install under another name (`amm`, say) and its state is `amm/state`,
  `amm/ls_<service>`.
- `config.overlay` is read from the app record at every step: a reinstall
  with a changed configuration takes effect at the next step.

### Register a topic

Topics may be declared in `config.overlay.topics` (an overlay with fixed
topics, e.g. OpNS's one global topic) or registered at runtime: one call
per topic. A dynamic overlay (one topic per token, `tm_<txid>`) declares
none and registers the ones the operator runs. The engine's two functions:
root sends them to the app's `register` box (the manifest's route
`{"address": "register", "handler": "overlay.register"}`, gated by `roles:
{root: ["register", …]}`, shruggr/skein#143; a mailbox address is relative
to the app, so installed it is `<app>/register`, shruggr/skein#128):

```
{fn: "register",   args: {topic, program}}   program: the role in `programs` that judges it
{fn: "deregister", args: {topic}}
```

Both are idempotent and answer `{topic, active}`; an unknown role is
refused. The set is the engine's own head `<app>/topics` (`{kind:
"overlay-topics", topics: [{topic, program}]}`), served beside the declared
topics from the next step or call. `register` emits `subscribe {topic,
program, fn}` for `<topic>` (`submit`: one mesh, two kinds of message,
`{kind: "submit", beef}` and `{kind: "admit", txid, topics}`, the function
reads the kind) and `<topic>-proof` (`peerProof`), `program` the engine's
own role, no door filter (the bodies are dag-cbor: a `submit` message's
BEEF is inside it, where the door does not look, and the engine decodes
and checks it itself, as for a body framed with off-chain values);
`deregister` emits `unsubscribe {topic}` for the two (skein #119): the
host subscribes and routes by them. Until 0.12.0 the verdicts had a third
topic, `<topic>-admit` (`peerAdmit`). Who may call is your manifest's
`roles` for the route's handler `register` (the function the engine runs
is the body's `fn`). The engine takes
them only in the box `register` (`<app>/register`, one box per function
class, shruggr/skein#128, 0.7.5, 0.7.7); in any other box — `<app>`,
`<app>/submit` — they are refused with `bad-args` (`register: not taken in
box <box>; send it in <app>/register`), writing and emitting nothing. The
answer goes back in the box they came in. A lookup service without a `topics`
list listens to every topic, declared or registered. Every skein is a
market and a validator, always (0.12.0, David 2026-10-09): a register also
emits `liveness {topic: "<topic>-live", window}` and `beacon {topic:
"<topic>-live", every, body}` (the body below); a deregister emits
`unliveness` and `unbeacon`. `window` and `every` are
`config.overlay.market: {window}` and `config.overlay.validator: {every}`,
else 40 000 and 30 000 ms; neither can be turned off (the owner's switch
of 0.9.2, `{fn: "market" | "validator"}`, is gone, and with it the switch
kept in `<app>/topics`). docs/OVERLAY.md "Register a topic" has the rest.

**By call** (0.18.0, skein-overlay#10): a registration is also taken as a
call from a program of the instance, in its step (an in-VM call, skein
docs/VM.md "Calls") — `call(<the engine>, "register", {topic, program,
seed?})`, likewise `deregister`, `registerLookup`, `deregisterLookup`, the
`arg` what the message's `args` is. So an app's own program registers the
topics it derives (skein-amm: a token's `tm_color_<id>`, `ls_color_<id>`,
`ls_amm_<id>` from its deploy) in the step that derives them, without a
message from root. It does what the message does — the set, the events
emitted on the calling step, `seed` judged, the records kept on it — with
no box and no role check: only a program of the instance can call in a
step. The engine's app is the calling step's: its thread's program's app
record, whose role `overlay` is the engine. Answered `{fn, result: {topic |
service, active, seeded?, missing?, untaken?}}`, or `{fn, error: {code:
"bad-args", message}}` with the message form's words; the result record
(op the fn) carries the call's `caller`. A kernel call (no step: it writes
nothing), or a thread whose program is of no app with an overlay engine,
is answered `bad-args`.

### Beats

Beats are libp2p service discovery (David, 2026-10-09: they replace
SHIP/SLAP on the libp2p network; they are not SHIP/SLAP, and no SHIP/SLAP ad
is published p2p). Every topic manager and every lookup service the engine
runs, registered or (0.17.0) configured, beats on its own topic, named after itself:
`<topic>-live`, `<service>-live`.

- **A topic's body** is dag-cbor `{view: {count, digest}, terms?,
  tipHeight?, tipAnchor?, tailDigest}` (the last three 0.14.0, "Anchors"
  below):
  `terms` (0.16.0) is the root record of the head `<app>/terms`, a
  dag-cbor record the app writes at runtime (skein-amm: root's `terms`
  message), opaque to the engine and copied as is; the record `null`
  (cleared), no field: a market only. No head: `config.overlay.terms`
  (0.17.0), the INITIAL value (the admin's, given at a create's config —
  a token instance beats its default terms before any program of its app
  has stepped); neither, no field. A change of the head
  re-declares every registered and configured topic's beacon, on the message `{fn:
  "rebeat"}` the writer sends the instance itself in box `<app>`. `view` is the topic's
  **view digest**: `count` the topic's admitted-and-unspent outputs, and
  `digest` (32 bytes) the sum mod 2^256 of `sha256(txid ‖ vout)` over them
  (txid 32 bytes in internal byte order, vout 4 bytes little-endian, each
  hash read as a big-endian number; written big-endian). Order-independent:
  folded in when the topic admits an output, out when it is spent (a
  previous coin a transaction the topic admits consumes); a rejection takes
  its transaction's outputs out and gives the coins it consumed back. Kept
  incrementally in the topic's state record (`<app>/state`, map `views`),
  read in one lookup: no sort, no log read. An empty topic: count 0, 32
  zero bytes. Two peers holding the same outputs in a topic beat the same
  view.
- **Updating a beat** is re-declaring the beacon: the host publishes the
  declared body and reads no state at beat time, and an app's new `beacon
  {topic, every, body}` for the same topic replaces its previous one (skein
  `src/host/p2p.ts`); a receiver's liveness tool keeps the latest beat per
  sender. So a step that changes a registered topic's beat (an admission, a
  rejection, a proof, a register's seeds) emits `beacon` again with the new
  body: one logged event per change.
- **A lookup service's body** is the lookup program's own. `registerLookup`
  declares the beacon on `<service>-live` with the body its program's fn
  `beat` answers (`Spec.beat`; a program without one beats an empty body),
  and liveness on it with the market's window (0.12.1: a skein keeps the
  other peers' lookup beats as it keeps topic beats); `deregisterLookup`
  ends both (`unliveness`, `unbeacon`). A hook (`admitted`, `spent`, `rejected`)
  updates it by answering `{beats: {<service>: bytes}}` (`Service.beat` in
  the hook): the engine re-declares that registered service's beacon.
- `origin` is the host's, not the engine's. What goes in `terms` is the
  app's (the engine never reads it).
- "Spent" in the view is the topic's own reading: a previous coin a
  transaction the topic admits consumes. A spend the chain app records of a
  transaction never submitted to the topic is not folded out: the engine
  hears of no such spend (the chain app answers an ingest's caller about
  that transaction only), so `inTopic` and a lookup, which read the chain's
  `spent`, can count fewer outputs than the view. Not built (stopped, 0.12.1).
- A topic or service declared in `config.overlay` (not registered) does not
  beat, as before.

### Anchors (0.14.0, shruggr/skein#150)

Per topic the engine keeps BRC-136's anchor chain, in `<app>/state`:

- `root(H)`: the merkle root over the txids the topic judged that are mined
  at height H, in block order (32 zero bytes when none; the txid itself when
  one; else Bitcoin's tree, sha256d, the odd last node paired with itself).
- `anchor(H) = sha256d(anchor(H-1) ‖ blockhash(H) ‖ root(H))`, from the
  topic's genesis height (`anchor(genesis-1)` is 32 zero bytes), all in
  internal byte order.
- The genesis height is the lowest height a transaction the topic judged is
  mined at; the tip, the highest. Every height between has an anchor.
- The tail is the outputs the topic admitted in transactions not mined, as
  a view digest (count and sum).

A transaction is placed when the engine learns its proof: admitted at its
proof, or a watch hearing `proven` (a reorg's proof moves it). A rejection
removes it. The anchors from the lowest height touched to the tip are
computed again at the end of the step, and the beacon is declared again
when the beat changed. The beat carries `tipHeight` and `tipAnchor` (absent
before anything is mined) and `tailDigest`.

Three http reads give the same answers to an app that chooses to publish
them:

- `GET /anchors?topic=&heights=h1,h2,…` → `{topic, genesisHeight,
  tipHeight, anchors: [{height, anchor}]}` for the heights in the span
  (anchor hex, internal byte order). Without `heights`: the locator's — tip,
  tip-1, tip-2, tip-4, tip-8 … then genesis. Before anything is mined:
  `{topic, anchors: []}`.
- `GET /admitted?topic=&fromHeight=&toHeight=&limit=` → `{topic, blocks:
  [{height, blockHash, txids, bump}], nextHeight}`: only heights with
  transactions the topic judged, txids in block order (hex, display order),
  `bump` a compound BUMP over them (BRC-74, hex). At most 1 000 blocks and
  10 000 heights per read; `nextHeight` is where to go on, or `null`.

The sync protocol (0.15.0, skein-overlay#5, shruggr/skein#154): libp2p
`/skein/overlay/sync/1.0.0` is answered through the front door, by the
engine's filter `sync` on the libp2p row of that address an app declares
(the manifest above; an app that declares no such row does not serve sync).
Each frame is one front-door call; the filter decodes it (the package's
`body`) and answers one dag-cbor frame (the filter's answer body, type
`application/vnd.ipld.dag-cbor`), which the host writes back on the
stream. A read: the current state only, nothing written, nothing logged.

```
{kind: "locator", topic, locator: [{height, anchor: bytes(32)}]}
    → {kind: "locator", topic, genesisHeight?, agreedHeight?, tipHeight?}
{kind: "admitted", topic, fromHeight, toHeight, limit}
    → {kind: "admitted", topic, blocks: [{height, blockHash, txids, bump}], nextHeight}   (hex, as /admitted)
{kind: "tx", topic, txid}
    → {kind: "tx", txid, beef?: bytes}                                                   (absent: not held)
anything else, a topic not served here, a frame that is not dag-cbor → {kind: "error", message}
```

`agreedHeight` is the highest height in the peer's locator where our anchor
equals theirs (absent: none; an empty locator asks for none). The ranges
take `/admitted`'s defaults and bounds; `tx` is `/holds` over the served
topics, with the chain state's Atomic BEEF as bytes. The pulling half (the
beat trigger, the locator, the ranged pulls checked against the headers,
the fetches into `/skein/overlay/beef/1.0.0`, the wants) is the host's
(skein `src/host/sync.ts`).

Not built: a reorg that replaces a block the engine hears no proof for (a
block with nothing of the topic's in it, or a proof never re-sent) leaves
the anchors at that height until a proof at or below it lands.

### Register a lookup service

Lookup services have their own pair of calls (0.11.0; David Case,
2026-10-08: separate from the topics'), in the same box `<app>/register`,
gated the same way (or, 0.18.0, as a call from a program of the instance,
as `register`):

```
{fn: "registerLookup",   args: {service, program, topics?}}   program: the role in `programs` that answers it
{fn: "deregisterLookup", args: {service}}
```

Idempotent, answered `{service, active}`; another program or other
topics for a registered service, or an unknown role, are refused. The set
is the head `<app>/lookups` (`{kind: "overlay-lookups", lookups:
[{service, program, topics?}]}`), served as if `config.overlay.lookups`
named each: `/lookup` routes it, `/listLookupServiceProviders` lists it,
the hooks reach it. A name neither declared nor registered answers 400
"Lookup service not supported" (no wildcard). The hooks reach each lookup
**program** once per admitted transaction and topic, not once per name,
and a program serving many names keeps one index: its `Spec.index`
(`ls_demo`), else `ls_<role>`; each call names the service it was called
as (`Service.name`). docs/OVERLAY.md "Register a lookup service".

### Root routes

The @bsv/sdk clients take a bare origin and call `<origin>/submit` and
`<origin>/lookup`. One overlay app per skein, so root may answer both at
the origin's root with two root routes (shruggr/skein#143) to the app's
`submit` handler and `lookup` filter (an app installed as `mandala`):

```
skein routes add --transport http --filters kernel.beef --fn submit /submit mandala.overlay <origin>
skein routes add --transport http --filters mandala.lookup /lookup <origin>
```

The engine finds its app from either (the handler's program record; the
filter `<app>.lookup`). An install that asks for them is not built: the
manifest format has no such request (a skein change; docs/OVERLAY.md
"Root routes" sketches one).

## Build and test

Zig 0.16.0 (`mise.toml`).

```
zig build          # zig-out/bin/{overlay,topic-demo,lookup-demo}.wasm
zig build bin      # the same, into bin/ (committed; the build is reproducible)
zig build test     # the submission flow and the contracts, natively
```

With a local SDK checkout: `zig build --fork=../skein-sdk`. skein runs this
app end to end in `kernel-zig/equiv/overlay.ts` and `install-overlay.ts`,
which clone this repo at a pinned commit (or take `$SKEIN_OVERLAY_DIR`).

## Docs

| what | where |
|---|---|
| the overlay in full: submission, state, contracts, the wire, gossip, two overlays, a system tree | [docs/OVERLAY.md](docs/OVERLAY.md) |
| the chain app's contract | shruggr/skein-chain `docs/CHAIN.md` |
| apps, manifests, install; an overlay as an app | skein `docs/APPS.md` §6 |

Not built: BRC-88 SHIP/SLAP (decided 2026-10-08, stopped: revoking an ad
spends it, and the skein's wallet program takes no caller-supplied inputs;
docs/OVERLAY.md "Not built"), GASP, the `historical-tx` modes. Catch-up
from a peer is pulled by the host (shruggr/skein#150): the engine keeps
the anchors and answers the sync protocol's frames (0.15.0).

## Versions

| | |
|---|---|
| this app and package | 0.19.0 (tag `v0.19.0`) |
| skein-sdk | v0.12.0, by tag URL and hash in `build.zig.zon` (modules `chain` and, for the engine, `sk`; bsvz comes through it) |
| requires | `chain/1` (shruggr/skein-chain 0.3.0) |
| skein | log format 10, the BEEF envelope beside the pointer record (shruggr/skein#146); the routes / filters / roles manifest (shruggr/skein#143); skein's equivs pin this repo by commit |

0.3.0 moved the state under `<app>/…`, made the chain app's answer the gate
and exported the modules (shruggr/skein#79).

0.4.0 gave the topic and lookup contracts `metadata` and `documentation`,
answered by the programs on the listing and documentation routes (#2), and
made submit take the BEEF as its pointer record, with no re-proof at submit
and the CID carried by ingest and gossip (shruggr/skein#121).

0.4.1 keeps the submission as handed over on the `applied` record (`beef`,
for internalizing) and serves lookups by the chain state's `beefOf` on
skein-sdk v0.5.1, which stops at a proven transaction's own path (#3).

0.5.0 added `config.overlay.prefixes` (topics an app activated live under
a prefix); 0.6.0 removes it — no topic prefixes anywhere — and adds the
engine's `register {topic, program}` / `deregister {topic}`: the topics
registered at runtime under `<app>/topics`, served beside the declared
ones, with the `subscribe` / `unsubscribe` events the host routes by
(shruggr/skein#119, #120).

0.6.1 puts `filter: "beef"` on the `<topic>` subscribe, so the door
decodes a gossiped submission's BEEF as it does for `/submit`.

0.6.2 takes `register` / `deregister` in any box a row routes to the
engine, and the manifest routes the owner's to the app's `overlay` box
(`<app>/overlay`, shruggr/skein#128).

0.7.0 walks the submission's BEEF oldest first (skein-overlay#1): every
transaction before the subject is judged, each one taken is ingested and
admitted on its own answer, in order; a submission missing a parent pauses
(`pending` with `waiting`, a `want` event per parent, a `resume` to itself
when a later submission brings one). The submit event gains `earlier`,
`wanted`, `requested` and `waiting`; the state gains the map `wants`.

0.7.1 (shruggr/skein#112, revised): the want is `{event: "want", txid,
peer}` — one per (parent, peer), the peer that announced the submission or
something needing it; no topic. The map `wants` is `parent ‖ peer →
[subject]`; all of a subject's wants clear when it resumes and are recorded
again for what it still lacks. Only a submission from a libp2p peer
pauses; over HTTP a BEEF lacking parents is refused, 400, naming them. The
manifest gains the stream row `/skein/overlay/beef/1.0.0` (filter `beef`,
fn `submit`), where a peer answers a want with one Atomic BEEF per frame.

0.7.2 (shruggr/skein#112, settled 2026-10-05): a submission is a message,
`{fn: "submit", args: {beef, topics, offChainValues?}}`, into the app's box
`<app>` (a new row, open to anyone, `filter: "beef"`); `POST /submit`
carries the same message and answers delivery only, `200 {id}` (the request
record's CID) — no STEAK on the connection, no 503. The submitter is
answered by message in the box it wrote to (`{fn: "submit", request,
replyTo, result}`): `admitted` with status `pending` and the STEAK, then
each `proven` (a reorg's too), or `rejected`. Every submission missing a
parent pauses (no 400 over HTTP). The want is `{event: "want", txid, topic,
peer?}`, one per (txid, topic, peer?): a gossip pause's peers are the
publisher and every peer whose `-admit` for it was seen (the peer-admit
record gains `peer`), more as admits arrive; a pause by message or HTTP
wants with no peer. Each want's end is the event `{event: "unwant", txid,
topic, peer?}` (the builder's smallest option, David to review). The map
`wants` is `txid ‖ tp ‖ peer? → [subject]`. A `register` / `deregister` in
`<app>` is taken from the instance itself only.

0.7.3: `POST /submit` launches nothing (a step that launches a thread waits
on it, so the request did not end: 500 `ERR_FRONT_DOOR`). It answers `200
{id}` (still the request record's CID) with `admit: [{event, box: <app>}]`,
the event `{kind: "submission", body: {fn: "submit", args}, request,
transport: "http", sender?}`, routed into the app's box as the libp2p route
admits its submit event; the engine's step on it is the message step's.

0.7.4, on skein-sdk v0.7.1 (the address book has no roles, shruggr/skein#126):
the libp2p provider is the address book's entry at (`local`, `libp2p`)
(the SDK's `peerAt`), so gossip out publishes again. A submission by
message is answered once per state change: the message step's wake at the
end of the thread it launched (`resolved` in its input) routes nothing and
answers nothing (outcome `woke`) — before, it answered `admitted` a second
time, from the state.

0.7.5: one box per function class (shruggr/skein#128, as decided for
0.6.2): `register` / `deregister` are taken only in the box the manifest
names `overlay` (`<app>/overlay`); in any other box, the app's own
included and whoever sent them, they are refused with `bad-args`. `submit`
is taken in any box a row routes to the engine, so an app may open
`{"address": "submit", "sender": "*", "program": "overlay", "filter":
"beef"}` when its own box belongs to another program.

0.7.6: one box per function class, completed (shruggr/skein#128): the
submission box is `<app>/submit` everywhere. The stock manifest's
submission row is `{"address": "submit", "sender": "*", "program":
"overlay", "filter": "beef"}` (was `""`, the app's own box), and `POST
/submit` admits its `submission` event into `<app>/submit` (was `<app>`),
so an app whose own box belongs to another program gets HTTP and message
submissions in one box; the answers go to the sender in that box. The
skein install's derived http row `/<app>/submit` is unchanged (only where
its handler admits moved). The libp2p routes still admit their routed
`submit` event (and `peer-admit`) into `<app>` through the derived `event`
row, and the engine's `watch` / `resume` stay there; registration stays in
`<app>/overlay` (renamed in 0.7.7).

0.7.7: the registration box is `register` (`<app>/register`; was
`overlay`): the manifest row is `{"address": "register", "sender":
"$owner", "program": "overlay"}`, named for its function class like
`submit`. Why: a manifest row whose address equals the app's name is the
app's own box (shruggr/skein#128), so for an app named `overlay` the row
`overlay` resolved to `overlay`, not `overlay/overlay`, and 0.7.5's
register-only-in-`<app>/overlay` refused the owner. An app embedding the
engine renames its row `overlay` → `register`; the owner sends to
`<app>/register`.

0.7.8: `register {topic, program, seed?: [txid…]}` seeds the topic from
what the chain state already holds: each held seed is judged under the new
topic only, oldest first over its held ancestry, and admitted from the
state as a submission of it would be (no resubmission, no wallet); the
answer adds `seeded` and `missing` (and `untaken` when a held seed is taken
by nothing). Idempotent: a seed already admitted under the topic is not
judged again. docs/OVERLAY.md "Register a topic" has the rest. The manifest's
rows are unchanged.

0.8.0: the listings and the documentation are reads (shruggr/skein#135,
two doors): the manifest declares `/listTopicManagers`,
`/listLookupServiceProviders`, `/getDocumentationForTopicManager` and
`/getDocumentationForLookupServiceProvider` in `reads[]` (`{address,
program: "overlay", fn}`) and drops the four `http` rows that served them.
The host serves each as a call over the current state: any method, signed
or not, no entry, nothing logged. `/lookup` stays derived (a read);
`/submit` stays a derived http row (a message route: a signed request), and
the rows `submit` and `register` are unchanged. The engine is unchanged:
its four functions only ever read (the configured programs' `metadata` /
`documentation`), as `/lookup` did. An app that embeds the engine moves the
same four rows into its `reads`.

0.9.0: market and validator (shruggr/skein#120, David 2026-10-06 evening:
"a skein runs as a market and/or a validator by two settings in the engine's configuration (`config.overlay.market: {window}`, `config.overlay.validator: {every}`), and registering a token's topic is the one act that drives both"). Two optional settings: `config.overlay.market: {window: <ms>}` and
`config.overlay.validator: {every: <ms>}`. A `register` that changes the
set emits, after its three subscribes, `liveness {topic: "<topic>-live",
window}` when a market and `beacon {topic: "<topic>-live", every, body:
<empty>}` when a validator; a `deregister` emits `unliveness` / `unbeacon`
likewise. Nothing extra at a start or re-read. A value that is not an
integer from 1 000 ms to a day refuses the registration (`bad-args`).
docs/OVERLAY.md "Market and validator". The manifest's rows are unchanged.

0.9.1: `POST /submit` is BRC-22 and synchronous again (shruggr/skein#112;
David, 2026-10-07: "the HTTP `/submit` route is BRC-22 or it does not exist; it never returns a different shape").
The route launches the submission's thread and waits on it (skein's
wait-on-thread, as 0.7.1 did), answering the STEAK; 400 for a BEEF that
does not verify or a transaction the chain app rejected; 200 with the empty
STEAK when no topic takes it; 503 + `Retry-After` when nothing is decided.
A resubmission is a poll on the same flow: in progress, it waits on the
same thread; judged, the first submission's STEAK from the state, nothing
run again. A submission lacking a parent pauses as before, and its requests
wait for the pause to end (the engine's `wait` message, answered when the
pause ends); several waiters are all answered. A submission by message into
`<app>/submit` is unchanged, answered by messages. 0.7.3–0.9.0's
`submission` event is still stepped (a log written then).
docs/OVERLAY.md "Submitting". The manifest's rows are unchanged.

0.9.2: the roles are the owner's switch (David, 2026-10-07: "this
shouldn't have been a config in the manifest. This should be a setting
that the user is configuring"). The owner sends, in `<app>/register` (the
`register` row), `{fn: "market", args: {window: <ms>}}` or `{fn: "market",
args: {off: true}}`, and `{fn: "validator", args: {every: <ms>}}` or `{fn:
"validator", args: {off: true}}`; no reinstall. The answer is the roles in
effect, `{market?: {window}, validator?: {every}}`. The switch is kept in
the set's record `<app>/topics` beside `topics` and has precedence over
`config.overlay.market` / `.validator` from then on (the manifest sets the
initial value; never switched, the manifest's). On emits `liveness` /
`beacon` for every registered topic, off `unliveness` / `unbeacon`;
`register` / `deregister` emit by the roles in effect. Idempotent.
docs/OVERLAY.md "Market and validator". The manifest's rows are unchanged.

0.10.0: skein's routes, filters and roles (shruggr/skein#143). The
manifest's `dispatch` and `reads` are `routes`: the box `register` is the
handler `overlay.register`, gated by `roles: {root: ["register", "market",
"validator"]}` (was the row from `$owner`); the box `submit` and the libp2p
stream `/skein/overlay/beef/1.0.0` list `kernel.beef` (was `filter:
"beef"`, sender `*`); the four listing and documentation reads are read
routes, each with the engine's function as its filter (`filters`). The
engine: a read called as a filter (`filter: true` in the call's input)
answers `{answer: <the http answer>}` (src/routes.zig); a read route's
call names no program, so the engine's configuration comes from the app
the route names (`match.app`, src/config.zig `matchedApp`). Nothing else
changed; the engine never read an `owner` input.

0.11.0: lookup registration and root routes (David Case, 2026-10-08). The
engine's own pair of calls for lookup services, separate from the topics'
`register` / `deregister` (unchanged): `registerLookup {service, program,
topics?}` / `deregisterLookup {service}` in `<app>/register`, idempotent,
answered `{service, active}`, the set under the head `<app>/lookups`
(src/lookups.zig), served as `config.overlay.lookups` is (src/config.zig
`withRegistered`); an unregistered name still answers "Lookup service not
supported". The admitted-output hooks reach each lookup program once, not
once per name (src/calls.zig `hookTargets`), and a program keeps one index
whatever names it serves: `Spec.index`, else `ls_<role>` (src/lookup.zig
`indexOf`; the calls carry `program`, the role; `Service.name` is the
called name, `Service.index` the index) — before, `lookup.main` read
`<app>/ls_<called name>` while the hooks wrote under each configured
name. `ls_demo` keeps `<app>/ls_demo` (`.index = "ls_demo"`). Root routes:
the engine finds its app from a root read route's filter `<app>.lookup`
(src/config.zig `filterApp`), so `/submit` and `/lookup` work at the
origin's root (README "Root routes"). The manifest's roles list the two
new functions. BRC-88 SHIP/SLAP ads: not built (stopped; docs/OVERLAY.md
"Not built").

0.12.0: on skein-sdk v0.11.0 (shruggr/skein#146, log format 10), gossip
topics and beats (David, 2026-10-09). The door puts the BEEF's envelope
`{form, beef: <pointer record>, subject?, vout?}` where the bytes were, the
pointer record the BEEF alone: `submit.Input` is the envelope or bytes, a
submission's subject the envelope's (`record.subjectOf`), the bytes as
received `record.wireOf` (gossip, the cut Atomic BEEFs), and the
`applied` record's `beef` the envelope as a block of its own (it links the
record; `wireOf` gives the bytes). Gossip: `<topic>` carries submit and
admit as two message kinds (one mesh), `<topic>-proof` and `<topic>-live`
stay separate; a register subscribes `<topic>` and `<topic>-proof` (no
`-admit`, no door filter). Every skein is a market and a validator,
always: the `market` / `validator` switch functions and their stored state
are removed; a register starts liveness and the beacon at
`config.overlay.market` / `.validator`'s ms, else 40 000 / 30 000. Beats:
the topic's view digest in the state (`views`), its beat body re-declared
when it changes; lookup services beat on `<service>-live` with their
program's body (fn `beat`; a hook's `beats`). README "Beats".

0.12.1 (David, 2026-10-09): `registerLookup` keeps liveness on
`<service>-live` beside its beacon (the market's window), and
`deregisterLookup` ends it (`unliveness`); `config.overlay.terms`, opaque,
is copied into each topic's beat body as `terms` (absent: no field;
config.zig `rolesOf`, topics.zig `beatBody`). Not built: folding out spends
the chain app records of transactions never submitted to the topic
(README "Beats").

0.13.0 (David, 2026-10-15; skein-overlay#4): ancillary txids. A topic's
answer may name `ancillaryTxids` (`topic.Instructions.ancillary_txids`);
the route refuses a judgement naming one that does not resolve to a
`bitcoin-tx` block (`UnknownAncillary`) or naming one twice; the
admittance record keeps them as `ancillary: [<tx CID>]` with a `mentions`
ref each, and `<app>/state` indexes them (`ancillary`: txid ‖ tp ‖
outpoint → admittance, removed with it). The read `/holds` (filter
`overlay.holds`, `State.holds`) answers whether the state reaches a
transaction: admitted, retained, or ancillary.

0.14.0 (shruggr/skein#150, David, 2026-10-15): anchors. `<app>/state`
gains `mined`, `placed`, `anchors` and `tips`; the beat body gains
`tipHeight`, `tipAnchor` and `tailDigest`; the reads `/anchors` and
`/admitted`; `/holds` answers `judged` for a transaction a topic took that
admitted no output, and carries the chain state's Atomic BEEF (`beef`).
A BEEF on `/skein/overlay/beef/1.0.0` that no one here waits on is taken
when it proves its subject mined (a pull), judged by every served topic.
README "Anchors".

0.14.1 (David, 2026-10-22): a BEEF out of order (a child before its
parent; ts-sdk's writer puts a proven child before its proven parent) is
sorted parents-first, not refused `NotParentsFirst`: `decode` (bytes,
skein-sdk v0.11.1 `beef.sorted`), `decodeRecord` (the door's envelope;
the pointer record keeps the wire's order) and `atomicFor`. The walk, the
ingests and the checks then go oldest first as before; a cycle is the one
order refused.

0.15.0 (skein-overlay#5, David, 2026-10-23): the sync protocol
`/skein/overlay/sync/1.0.0` is answered by the engine through the front
door, not by the host (shruggr/skein#154): fn `sync`, a filter on a libp2p
row (`filters.sync: "overlay.sync"`, the row `{transport: "libp2p",
address: "/skein/overlay/sync/1.0.0", filters: ["sync"]}`), decodes the
frame and answers one frame — the locator (the comparison moved in from
the host's `OverlaySync.answer`), a range of the admitted lists, a
transaction's BEEF, or an error. An app serves sync only when it declares
the row (skein-amm's and skein-1color's manifests each carry it, pinned on
this release). The http reads `/anchors`, `/admitted` and `/holds` are
unchanged. README "Anchors".

0.15.1 (skein-overlay#6, David, 2026-10-23): a submission whose parent is
held but not yet admitted (in flight: its own submission ingested, the
chain app's answer not in) pauses on that parent as on a missing one, with
no want, and the parent's thread resumes it when the chain app answers
(accepted or proven: admitted; rejected; an error answer). Before, it was
judged at once against a parent whose outputs were not admitted yet and
refused `NotAdmitted` (a block's transactions delivered back to back by the
topic catch-up admitted one dependency level per beat, shruggr/skein#154).
The paused event carries the parents in flight as `held`; a parent
answered for between the route and the pause is resumed by the pause step
itself. No wire, host or kernel change; the missing-parent pause and its
wants are as they were.

0.16.0 (shruggr/skein-overlay#7, David, 2026-10-23: "The configs should
not be published in the image. This will be a dynamic, competitive
marketplace."): a topic's beat carries `terms` from the head `<app>/terms`
(the root record the app writes at runtime, opaque; config.zig `termsOf`),
read at each beacon declaration; no head, or the record `null`, no
`terms`: terms set, a validator; unset, a market only, the beat itself
kept for the sync. `config.overlay.terms` (0.12.1) is removed (no longer
read; `defaults.overlayTerms` gone). A terms change re-declares every
registered topic's beacon: the message `{fn: "rebeat"}` in box `<app>` from
the instance itself, sent by the program that wrote the head (engine.zig
`rebeatStep`, topics.zig `rebeatEvents`). No wire, host or kernel change.

0.16.1 (shruggr/skein-sdk#1, shruggr/skein#156): the chain app's state is
read through the SDK's one opener, skein-sdk v0.12.0 `chain.open` (network
from the record; none yet, an empty state on the configured network):
`state.chainView` is gone, the engine and the lookup handler call it. No
behaviour change. (skein-chain 0.7.0's chain state names the host chain's
`headers` and `heights` roots, read through the host/chain exception: the
same layout, nothing here changes.)

0.17.0 (shruggr/skein-overlay#8, for shruggr/skein-amm#4: one token
instance per token id, its topic from its config at birth): a topic in
`config.overlay.topics` and a lookup service in `config.overlay.lookups`
beat as a registered one does — liveness and a beacon on `<name>-live`,
the same bodies — declared on the engine's first step after it sees the
configuration (src/configured.zig; the head `<app>/configured`, `{kind:
"overlay-configured", topics, lookups, terms?}`, keeps what was declared:
the same configuration again declares nothing; a changed one declares
every configured name again and undeclares a dropped one), re-declared on a
view change and by `rebeat` as a registered one, and kept across a restart
as every beacon is (the host folds them from the log). A name registered
too is the registration's. `config.overlay.terms` is accepted again, as
the beat's INITIAL terms: the head `<app>/terms` wins once written (its
`null` too); a change of the configured terms re-declares the registered
topics' beacons too. skein's install check accepts the field (`terms`: a
map; shruggr/skein, the same build). No wire or kernel change.

0.18.0 (shruggr/skein-overlay#10, for shruggr/skein-amm#5): `register`,
`deregister`, `registerLookup` and `deregisterLookup` are also taken as a
call from a program of the instance in its step ("Register a topic", "By
call"): the same code as the message in `<app>/register` (src/registry.zig,
the box path unchanged), the engine's app the calling thread's, answered
`{fn, result}` or `{fn, error}`. No wire, manifest, host or kernel change.

0.19.0 (David 2026-10-30: "we don't mark items which are undecided as
invalid"): **undecided is not rejected.** Admitted and rejected stay the
only verdicts. A topic manager that cannot decide because it cannot read
an input's source (not in the BEEF, not held) fails as a refusal fails,
with the error `MissingParents` naming every source it lacks (topic.zig
`missingParents`, `Call.lacking`; the line `topic: MissingParents:
<hex>,…`). The engine catches that error: the whole submission pauses
(the existing pause, `waiting` the named sources minus what is in the BEEF
or held), wants them from the peers that announced it, and is judged again
from the start of the walk as each arrives (a `resume`, never a
resubmission); paused again with what it still lacks; no timeout. Nothing
is recorded or answered as rejected while it is undecided. A topic that
decides with the BEEF and what is held asks for nothing (a mined funding
parent is never wanted). A submission spending a transaction that is
itself paused here waits on it, with no want (`held`, as a parent in
flight), and is routed again when that one is decided. The want's answer
path is unchanged: the host asks the announcing peer on
`/skein/overlay/sync/1.0.0` (`{kind: "tx"}`), the peer's engine answers
its chain state's Atomic BEEF of a transaction its state reaches, and the
host hands it to `/skein/overlay/beef/1.0.0` through `kernel.beef`. The
pre-SPV `missingParents` scan stays for BEEF bytes the door does not see
(a gossip `submit {beef}`); the door makes it unreachable for an envelope.
The topic-call carries `unheld` (a field the brief did not foresee): the
input sources neither in the BEEF nor held by the chain app, which
`Call.transaction` treats as unreadable whatever the store holds — reads
are global by CID, and a replay's store holds blocks that came later, so
"can the topic read it" must be the instance's chain state, the same live
and in a replay. The caller's error buffer (`sk`) holds 64 KiB. No wire,
manifest, host or kernel change.

## Contributing

Work is tracked in shruggr/skein; start at issue
[#31](https://github.com/shruggr/skein/issues/31). MIT, as skein.
