# skein-overlay

The overlay services engine for a [skein](https://github.com/shruggr/skein)
instance (shruggr/skein#36, #50, #57, #73, #74, #79), as an app (skein
`docs/APPS.md` §6: an overlay is an app). Split out of skein by
shruggr/skein#71, with its history (`programs/overlay`, `docs/OVERLAY.md`).

BRC-22 submit and BRC-24 lookup, served by the instance's own front door
with overlay-express's wire contract. Topic managers and lookup services are
programs the engine calls. The engine keeps what its topics admitted under
its app's own name (`<app>/state`, `<app>/gossip`, `<app>/ls_<service>`);
the chain state is the chain app's
([shruggr/skein-chain](https://github.com/shruggr/skein-chain), required:
`chain/1`), read by CID. A submission is handed to the chain app (`ingest`)
and admitted on its answer — the first of accepted or proven (#73).
Submissions, admissions and proofs are gossiped over libp2p.
`docs/OVERLAY.md` is the full contract.

## The tree

```
bin/overlay.wasm       the engine (wasm32-wasi, committed; `zig build bin` rewrites it)
bin/topic-demo.wasm    tm_demo, the example topic manager
bin/lookup-demo.wasm   ls_demo, the example lookup service (its own index under <app>/ls_demo)
etc/app.json           the manifest (skein docs/APPS.md §2, §6)
src/                   the engine (engine.zig, submit.zig, state.zig, calls.zig, routes.zig, gossip.zig,
                       config.zig, engine_vm.zig), the contracts (topic.zig, lookup.zig, vm.zig) and the two examples
test.zig               the submission flow and the contracts, natively
docs/OVERLAY.md        the overlay, in full
```

## The contract as Zig modules

An overlay app of your own ships the engine with its own topic managers and
lookup services in one tree, and names them in `config.overlay`. Its
programs depend on this package by URL+hash, as on the SDK, and import the
contract modules it exports:

| module | file | what |
|---|---|---|
| `topic` | `src/topic.zig` | the topic manager contract: `topic.main(identify)` |
| `lookup` | `src/lookup.zig` | the lookup service contract: `lookup.main(spec)` |
| `sk` | `src/vm.zig` | the `skein` imports as an overlay program sees them (topic and lookup use it) |

```zig
// build.zig.zon
.skein_overlay = .{ .url = "https://github.com/shruggr/skein-overlay/archive/refs/tags/v0.3.0.tar.gz", .hash = "…" },
// build.zig
const ov = b.dependency("skein_overlay", .{ .target = wasi, .optimize = .ReleaseSafe });
exe.root_module.addImport("topic", ov.module("topic"));
```

They pull in the SDK's `chain` module only (the same v0.4.0 the engine uses).

## The manifest

`etc/app.json` runs `tm_demo` and `ls_demo`. Its `config.overlay` is
`topics`, `lookups` and `gossip` (per topic, `false` turns its publishing
off). `requires: ["chain/1"]`: install the chain app first.

**The engine reads `config.overlay` from its app record** (skein #72, #77,
`src/config.zig`): the root of the head `<app>/app` that `skein-host install`
writes, found through the engine's own program record (`app: <name>`), at
every step and call. A reinstall with a changed `config.overlay` takes
effect at the next step, with no restart. The genesis defaults
(`overlayTopics`, `overlayLookups`, `overlayGossip`) are read only by an
engine with no app record (docs/OVERLAY.md, "A system tree for an overlay
node").

**The wiring is derived** from `config.overlay` by the install (skein
docs/APPS.md §6), so the manifest does not list it: the http rows `/submit`
and `/lookup` (served at `/overlay/submit`, `/overlay/lookup`), the libp2p
rows `tm_demo`, `tm_demo-admit`, `tm_demo-proof`, and the box `overlay` from
`event` (what the libp2p routes admit) and from `$self` (the engine's own
watch messages). The manifest adds the listing and documentation rows.

```
skein-host install https://github.com/shruggr/skein-chain --instance <handle>
skein-host install https://github.com/shruggr/skein-overlay --instance <handle>
```

## Build and test

Zig 0.16.0 (`mise.toml`). The SDK is a URL+hash dependency in
`build.zig.zon` (`shruggr/skein-sdk` v0.4.0, its `chain` module; bsvz comes
through it). To build against a local SDK checkout:
`zig build --fork=<skein-sdk checkout>`.

```
zig build          # zig-out/bin/{overlay,topic-demo,lookup-demo}.wasm
zig build bin      # the same, into bin/
zig build test     # the submission flow and the contracts (natively)
```

The build is reproducible: `zig build bin` on a fresh clone leaves `bin/`
unchanged.

skein runs this app end to end in its `kernel-zig/equiv/overlay.ts` and
`install-overlay.ts`, which clone this repo at a pinned commit (or take
`$SKEIN_OVERLAY_DIR`) and drive instances through the host with the stock
`@bsv/sdk` clients.

MIT, as skein.
