# skein-overlay

The overlay services engine for a [skein](https://github.com/shruggr/skein),
as an app: BRC-22 submit and BRC-24 lookup, served by the instance's own
front door, with topic managers and lookup services as programs the engine
calls. It is also a Zig package: an overlay of your own depends on it for
the topic and lookup contracts. Version **0.3.0**.

## What it is

- **The engine** (`bin/overlay.wasm`): `/submit` decodes the BEEF once,
  asks the topic managers to judge it by CID, and hands it to the chain app
  ([shruggr/skein-chain](https://github.com/shruggr/skein-chain), required as
  `chain/1`) with `ingest`. The submission is admitted on the chain app's
  first `accepted` or `proven` answer. Nothing persists unless a topic takes
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

**What is built and where it goes.** A submission admitted on `accepted`
sends the app itself a one-shot `watch`, which waits for `proven` (publishes
`-proof`) or `rejected` (unwinds). Next is skein-overlay#1: submit walks the
whole BEEF oldest-first and judges every transaction of the topic before the
subject, and a submission whose parent is neither in the BEEF nor held
pauses. With it comes the decided direction of shruggr/skein#31 ("Decided
2026-10-02 (night)"): a reference to a transaction is a registration for the
life of the transaction, and a judgement is re-run when the chain state it
depended on changes. Neither is built yet.

## Use it

Install the chain app, then the overlay:

```
skein-host install https://github.com/shruggr/skein-chain --instance <handle>
skein-host install https://github.com/shruggr/skein-overlay --instance <handle>
```

Its endpoints are under its BRC-23 base URL, `/<handle>/<app>`:
`POST /overlay/submit`, `POST /overlay/lookup`, the listing and
documentation routes, all open. The @bsv/sdk `TopicBroadcaster` and
`LookupResolver` reject a base URL with a path, so call the endpoints
directly (`POST <base>/submit` with the BEEF and `X-Topics`).

### Write an overlay of your own

An overlay app is a tree with the engine's module, your topic managers and
lookup services, and `etc/app.json` naming them in `config.overlay`.

`build.zig.zon`:

```zig
.dependencies = .{
    .skein_overlay = .{
        .url = "https://github.com/shruggr/skein-overlay/archive/refs/tags/v0.3.0.tar.gz",
        .hash = "skein_overlay-0.3.0-IMuNgUtjEwCMjfeG0MOYcGW1uD8gssDxdSEn8Ixx1Eta",
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

The manifest (`etc/app.json`, this repo's own, description left out):

```json
{
  "kind": "app",
  "name": "overlay",
  "version": "0.3.0",
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
    {"transport": "http", "address": "/listTopicManagers", "sender": "*", "program": "overlay", "fn": "listTopicManagers"},
    {"transport": "http", "address": "/listLookupServiceProviders", "sender": "*", "program": "overlay", "fn": "listLookupServiceProviders"},
    {"transport": "http", "address": "/getDocumentationForTopicManager", "sender": "*", "program": "overlay", "fn": "topicDocumentation"},
    {"transport": "http", "address": "/getDocumentationForLookupServiceProvider", "sender": "*", "program": "overlay", "fn": "lookupDocumentation"}
  ]
}
```

- `programs.overlay` is the engine: copy `bin/overlay.wasm` from this repo
  into your tree (or `bin/overlay.cid` when the instance already holds it).
- The rest of the wiring is derived from `config.overlay` by the install:
  http `/submit` and `/lookup` (open, under `/<app>/`), the libp2p rows
  `<topic>`, `<topic>-admit`, `<topic>-proof`, and box `<app>` from `event`
  and from `$self`. The install prompt reads them all aloud.
- The name rule: every head your programs write is under your app's name.
  Install under another name (`amm`, say) and its state is `amm/state`,
  `amm/ls_<service>`.
- `config.overlay` is read from the app record at every step: a reinstall
  with a changed configuration takes effect at the next step.

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
| this app and package | 0.3.0 (tag `v0.3.0`) |
| skein-sdk | v0.4.0, by tag tarball and hash in `build.zig.zon` (module `chain`; bsvz comes through it) |
| requires | `chain/1` (shruggr/skein-chain 0.2.0) |
| skein | log format 8; skein's equivs pin this repo by commit |

0.3.0 moved the state under `<app>/…`, made the chain app's answer the gate
and exported the modules (shruggr/skein#79).

## Contributing

Work is tracked in shruggr/skein; start at issue
[#31](https://github.com/shruggr/skein/issues/31). MIT, as skein.
