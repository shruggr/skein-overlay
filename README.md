# skein-overlay

The overlay services engine for a [skein](https://github.com/shruggr/skein),
as an app: BRC-22 submit and BRC-24 lookup, served by the instance's own
front door, with topic managers and lookup services as programs the engine
calls. It is also a Zig package: an overlay of your own depends on it for
the topic and lookup contracts. Version **0.7.4**.

## What it is

- **The engine** (`bin/overlay.wasm`): a submission is a message, `{fn:
  "submit", args: {beef, topics}}`, into the app's box (`POST /submit`
  carries the same message and answers delivery only). The engine decodes
  the BEEF once, asks the topic managers to judge it by CID, and hands it to
  the chain app ([shruggr/skein-chain](https://github.com/shruggr/skein-chain),
  required as `chain/1`) with `ingest`. It is admitted on the chain app's
  first `accepted` or `proven` answer. The submitter is answered by message,
  in its own box: **admitted** (status `pending`, the STEAK per topic), then
  **every proof**, or **rejected**. Nothing persists unless a topic takes
  it, apart from the request. `/lookup` is a read.
- **State under its own name.** The engine and its lookup services write
  only `<app>/state`, `<app>/gossip` and `<app>/ls_<service>`; the app record
  is `<app>/app`. The chain state is the chain app's `chain/state`, read by
  CID. Two overlay apps on one instance share the chain and nothing else.
- **Gossip** over libp2p, per topic: `<topic>` (the raw submission),
  `<topic>-admit`, `<topic>-proof`.
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
peer whose `-admit` for it was seen, more as admits arrive) the host asks
that peer on a direct stream; without one (a submission by message or
HTTP) it asks peers from its mesh for the topic. Each want that ends is
cleared by `{event: "unwant", txid, topic, peer?}`. A peer answers a want
on the stream `/skein/overlay/beef/1.0.0` (one Atomic BEEF per frame, the
wanted txid its subject; no reply frame), routed to `submit` as a
submission from that peer; when the parent is in, the paused one is routed
again. The pause is internal: the submitter hears nothing of it. A
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
`POST http://127.0.0.1:8100/@alice/overlay/submit`), `POST <base>/lookup`,
the listing and documentation routes, all open. The @bsv/sdk
`TopicBroadcaster` and `LookupResolver` reject a base URL with a path, so
call the endpoints directly (`POST <base>/submit` with the BEEF and
`X-Topics`). `/submit` answers `200 {id}` on delivery, not BRC-22's STEAK:
the verdict comes later, by message (docs/OVERLAY.md, "Submitting").

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

A lookup service is a `lookup.Spec` (its map names, `answer`, and the
`admitted` / `spent` / `rejected` hooks); `src/lookup_demo.zig` is a complete
one with its own index.

Either may also define `pub fn metadata(a, name) !topic.Metadata` (or
`lookup.Metadata`: name, shortDescription, iconURL?, version?,
informationURL?) and `pub fn documentation(a, name) ![]const u8`
(markdown); the listing and documentation routes call them. Without them it
lists under its configured name with an empty description. Where the text
comes from (a literal, a file in the tree) is the program's own.

The manifest (`etc/app.json`, this repo's own, description left out):

```json
{
  "kind": "app",
  "name": "overlay",
  "version": "0.7.4",
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
  "dispatch": [
    {"address": "overlay", "sender": "$owner", "program": "overlay"},
    {"address": "", "sender": "*", "program": "overlay", "filter": "beef"},
    {"transport": "http", "address": "/listTopicManagers", "sender": "*", "program": "overlay", "fn": "listTopicManagers"},
    {"transport": "http", "address": "/listLookupServiceProviders", "sender": "*", "program": "overlay", "fn": "listLookupServiceProviders"},
    {"transport": "http", "address": "/getDocumentationForTopicManager", "sender": "*", "program": "overlay", "fn": "topicDocumentation"},
    {"transport": "http", "address": "/getDocumentationForLookupServiceProvider", "sender": "*", "program": "overlay", "fn": "lookupDocumentation"},
    {"transport": "libp2p", "address": "/skein/overlay/beef/1.0.0", "sender": "*", "program": "overlay", "fn": "submit", "filter": "beef"}
  ]
}
```

- `programs.overlay` is the engine: copy `bin/overlay.wasm` from this repo
  into your tree (or `bin/overlay.cid` when the instance already holds it).
- The rest of the wiring is derived from `config.overlay` by the install:
  http `/submit` and `/lookup` (open, under `/<app>/`), the libp2p rows
  `<topic>`, `<topic>-admit`, `<topic>-proof`, and box `<app>` from `event`
  and from `$self`. The install prompt reads them all aloud.
- The row for the app's own box `""` (`<app>`), open to anyone, is where
  submissions arrive as messages (`{fn: "submit", args: {beef, topics}}`;
  the door decodes the BEEF, `filter: "beef"`). A `register` / `deregister`
  in that box is taken from the instance itself only; the owner's go to
  `overlay` (`<app>/overlay`).
- The libp2p row `/skein/overlay/beef/1.0.0` is the want-answer stream
  (shruggr/skein#112): a peer the engine wants a parent from answers on
  it, one Atomic BEEF per frame; the door decodes it (`filter: "beef"`)
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
the owner sends them to the app's `overlay` box (the manifest row
`{"address": "overlay", "sender": "$owner", "program": "overlay"}`; a
mailbox address is relative to the app, so installed it is `<app>/overlay`,
shruggr/skein#128):

```
{fn: "register",   args: {topic, program}}   program: the role in `programs` that judges it
{fn: "deregister", args: {topic}}
```

Both are idempotent and answer `{topic, active}`; an unknown role is
refused. The set is the engine's own head `<app>/topics` (`{kind:
"overlay-topics", topics: [{topic, program}]}`), served beside the declared
topics from the next step or call. `register` emits `subscribe {topic,
program, fn, filter?}` for `<topic>` (`submit`, `filter: "beef"`: the
door decodes the BEEF as for `/submit`), `<topic>-admit` (`peerAdmit`) and
`<topic>-proof` (`peerProof`), `program` the engine's own role;
`deregister` emits `unsubscribe {topic}` for the three (skein #119): the
host subscribes and routes by them. Who may call is your manifest's row,
e.g. the one above (the function is the body's `fn`); the engine takes
them in any box a row routes to it (`<app>` too) and answers in the box
they came in. Until skein's install resolves a relative mailbox address
(shruggr/skein#128, landing separately), a local run takes the address as
written: the box `overlay`. A lookup service without a `topics`
list listens to every topic, declared or registered. docs/OVERLAY.md
"Register a topic" has the rest.

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

Not built: BRC-88 SHIP/SLAP, GASP sync and catch-up from a peer, the
`historical-tx` modes.

## Versions

| | |
|---|---|
| this app and package | 0.7.4 (tag `v0.7.4`) |
| skein-sdk | v0.7.1, by tag URL and hash in `build.zig.zon` (modules `chain` and, for the engine, `sk`; bsvz comes through it) |
| requires | `chain/1` (shruggr/skein-chain 0.3.0) |
| skein | log format 8; skein's equivs pin this repo by commit |

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

## Contributing

Work is tracked in shruggr/skein; start at issue
[#31](https://github.com/shruggr/skein/issues/31). MIT, as skein.
