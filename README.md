# skein-overlay

The overlay services engine for a [skein](https://github.com/shruggr/skein)
instance (shruggr/skein#36, #50, #57, #73, #74), as an app (skein
`docs/APPS.md` §6: an overlay is an app). Split out of skein by
shruggr/skein#71, with its history (`programs/overlay`, `docs/OVERLAY.md`).

BRC-22 submit and BRC-24 lookup, served by the instance's own front door
with overlay-express's wire contract. Topic managers and lookup services are
programs the engine calls. The engine holds the chain and settlement state
through the SDK's wallet library, gates admission on the first of a status
provider's accepted status or a validated proof, and gossips submissions,
admissions and proofs over libp2p. `docs/OVERLAY.md` is the full contract:
the submission flow, the maps, the topic and lookup contracts, the wire, the
gossip, and a system tree for an overlay node.

## The tree

```
bin/overlay.wasm       the engine (wasm32-wasi, committed; `zig build bin` rewrites it)
bin/topic-demo.wasm    tm_demo, the example topic manager
bin/lookup-demo.wasm   ls_demo, the example lookup service (its own index under ls:ls_demo)
etc/app.json           the manifest (skein docs/APPS.md §2, §6)
src/                   the engine (engine.zig, submit.zig, routes.zig, gossip.zig, config.zig, vm.zig),
                       the contracts (topic.zig, lookup.zig) and the two examples
test.zig               the submission flow and the contracts, natively
docs/OVERLAY.md        the overlay, in full
```

The examples are what the engine is tested with. An overlay app of your own
ships the engine with its own topic managers and lookup services in one
tree, and names them in `config.overlay`.

## The manifest

`etc/app.json` runs `tm_demo` and `ls_demo`. Its `config.overlay` is
`topics`, `lookups`, `status` (`"$status"`: the status provider whose
messages the `status` box takes; none means admit at the proof) and `gossip`
(per topic, `false` turns its publishing off).

**The engine reads `config.overlay` from its app record** (skein #72,
`src/config.zig`): the head's root that `skein-host install` writes, found
through the engine's own program record (`app: <name>`), at every step and
call. A reinstall with a changed `config.overlay` takes effect at the next
step, with no restart. The genesis defaults (`overlayTopics`,
`overlayLookups`, `overlayGossip`) are read only by an engine with no app
record: one wired into an instance's genesis by a system tree
(docs/OVERLAY.md, "A system tree for an overlay node").

**The wiring is derived** from `config.overlay` by the install (skein
docs/APPS.md §6), so the manifest does not list it: the boxes `submit` and
`chain` (from anyone) and `status` (from `$status`); the routes `/submit`
and `/lookup` (served at `/overlay/submit`, `/overlay/lookup`) and
`libp2p:tm_demo`, `libp2p:tm_demo-admit`, `libp2p:tm_demo-proof` (the
host's libp2p node subscribes them as they are installed); the head
`ls:ls_demo`. The manifest adds the listing and documentation routes and
the heads `overlay`, `wallet`, `overlay:gossip` and `ls:*`.

```
skein-host install https://github.com/shruggr/skein-overlay --instance <handle>
```

## Build and test

Zig 0.16.0 (`mise.toml`). The SDK is a URL+hash dependency in
`build.zig.zon` (`shruggr/skein-sdk` v0.1.0, fetched by `zig build`; bsvz
comes through it). To build against a local SDK checkout:
`zig build --fork=<skein-sdk checkout>`.

```
zig build          # zig-out/bin/{overlay,topic-demo,lookup-demo}.wasm
zig build bin      # the same, into bin/
zig build test     # the submission flow and the contracts (natively)
```

The build is reproducible: `zig build bin` on a fresh clone leaves `bin/`
unchanged.

skein runs this app end to end in its `kernel-zig/equiv/overlay.ts`. That
test clones this repo at a pinned commit (or takes `$SKEIN_OVERLAY_DIR`),
boots instances from trees carrying `bin/*.wasm`, and drives them through
the router with the stock `@bsv/sdk` clients: submit and lookup, the
broadcast gate, the gossip on three routers, and a replay of every store.

MIT, as skein.
