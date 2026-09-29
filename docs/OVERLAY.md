# Overlay services in the VM (issue #36)

An overlay is the same transaction graph the wallet holds (#29), judged and
indexed differently. A submitted transaction is checked against the headers
the instance holds, then judged by topic managers. Topic managers are
programs. What they admit is kept as index maps in the store, and lookups
answer queries over those maps. Lookup services are programs too.

Only the wire contract is taken from the standard libraries. That contract is
BRC-22 submit, BRC-24 lookup, and overlay-express's listing and documentation
routes. The go-sdk `overlay/` engine and ts-stack `packages/overlays` storage
are not ported.

**Not built:**

- BRC-88 SHIP/SLAP advertisement. Clients reach an instance through the
  `hostOverrides` / `facilitator` options of the stock clients.
- Sync between overlay nodes (GASP).
- The `historical-tx` modes.
- BRC-64 history queries beyond "spent too" (`includeSpent`).

## Pieces

| where | what |
|---|---|
| `wallet-zig/src/overlay.zig` | The overlay's state in the chain and settlement core. It verifies a submission, gives the previous coins, records a topic's judgement, maintains the derived maps, and answers lookups with each output's BEEF. |
| `programs/overlay/src/engine.zig` → `overlay.wasm` | The engine: called, the front door's route handlers (`routes.zig`); stepped, the handler for the `submit` and `chain` entries. |
| `programs/overlay/src/routes.zig` | The route handlers (#40): the overlay-express wire contract. |
| `programs/overlay/src/topic.zig` | The topic contract (a library). |
| `programs/overlay/src/lookup.zig` | The lookup contract (a library). |
| `programs/overlay/src/topic_demo.zig` → `topic-demo.wasm` | `tm_demo`, an example topic. |
| `programs/overlay/src/lookup_demo.zig` → `lookup-demo.wasm` | `ls_demo`, an example lookup. |
| `kernel-zig/equiv/overlay.ts` | End to end, with the stock `@bsv/sdk` clients. It is part of `equiv/run.sh`. |

Build and test the programs from `programs/overlay`:

```
zig build        # zig-out/bin/{overlay,topic-demo,lookup-demo}.wasm
zig build test   # the contracts, natively
```

wallet-zig is a path dependency. Its library module is exported as `wallet`,
and bsvz comes through it. The programs are not pinned. An instance takes
them from its system tree's `bin/`.

## One chain, one settlement: how the wallet and the overlay split

There is one state record, the one the head `wallet` names (`wallet-state`).
It holds the chain tracker, the transactions, the proofs, the `spenders`, the
`dependents` relations and the settlement (`rejected`). These are the
wallet's records and maps, unchanged. The overlay's maps are added to the
same record (wallet.zig `map_names`), and wallet-zig's `Wallet` is the core
both programs load:

- **The wallet program** writes actions, outputs, drafts and broadcasts.
- **The overlay engine** writes the transactions a topic took (held like
  any other, through `putTx`, so each input is a `spends` relation) and the
  overlay maps.
- **Both** apply headers, proofs and statuses the same way (`addHeaders`,
  `applyStatus`).

The derived maps, the overlay's included, are maintained where a fact
changes (#41; docs/WALLET.md "Derived maps are maintained"), not rebuilt at
save. So a rejection is reflected at once, whichever program learned it.

When an instance runs both programs, the chain feed (box `chain`) should be
routed to the wallet, because only the wallet re-broadcasts after a reorg. An
overlay-only instance routes `chain` to the engine.

An old wallet binary would drop the overlay's maps from the record, so
`wasm/wallet.wasm` was rebuilt and repinned with the new map list.

## Maps

`tp` is len ‖ topic. The outpoint is txid (internal order) ‖ vout (u32 BE).

| map | key → value | |
|---|---|---|
| `admitted` | tp ‖ outpoint → admittance record | an output a topic admitted |
| `applied` | tp ‖ txid → applied record | the topic's judgement of this transaction: a later submission is a dupe; which previous coins it retained |
| `byTopic` | tp ‖ 0 (unspent) \| 1 (spent) ‖ outpoint → null | derived: `admitted` joined to the spends edge |
| `byScript` | sha256(locking script) ‖ tp ‖ 0 \| 1 ‖ outpoint → null | derived (the demo lookup's `scriptHash` query) |

**Spent within a topic is a join, not a table (#36 notes).** An admitted
output is spent when the wallet's `spent[outpoint]` names a spender — the
first transaction we hold that spends it and is not rejected (the `spends`
edge, topic-independent: docs/WALLET.md). There is no `consumed` or
`spentAdmitted` map. The one bit those carried — whether the topic kept the
coin for history — is the topic's judgement of the *spending* transaction,
so it lives on that transaction's `applied` record (`coinsToRetain`, input
indices; the STEAK as stored). `overlay.spender(topic, txid, vout)` gives
both: the spender, and whether this topic judged it and retained the coin.

**Maintained (#41).** A judgement (`apply`) writes each admittance's
`byTopic` / `byScript` key under its current state. The previous coins it
consumes turn spent through the transaction's own `spends` edges (held by
`apply`): `Wallet.refreshSpent` → `overlay.spentChanged` moves the keys of
every topic that admitted the outpoint (found through `dependents`, tag `m`).
A rejection (`Wallet.reject`) removes each vanished admittance with its keys
(`unadmit`) and its `applied` record; the coins the rejected transaction
spent move back to unspent the same way, unless another spender stands.

**Sync note (GASP, later).** Other overlay engines answer history /
`consumedBy` from per-topic tables. Here the answer is the shared spends edge
joined to `applied`; wire answers for sync are to be derived from those, not
from a stored consumed table.

**Records.**

- **Admittance:** `{kind: "admitted", topic, txid, vout, script, satoshis,
  admittedAt, tx: <tx CID>, refs: [{to: <tx CID>, rel: "admits"}]}`.
- **Applied:** `{kind: "applied", topic, txid, outputsToAdmit,
  coinsToRetain, coinsRemoved, at, tx, refs}`.

The step keeps both. Their `refs` give the kernel `admits` edges
(docs/VM.md, "Edges").

**Previous coins** (BRC-22's `previousCoins`) are the inputs that spend an
output live in the topic: admitted, and not spent by another transaction we
hold that is not rejected (the one being judged does not count: it may be
held already, judged by another topic).

**Retained and removed coins.** A retained coin and a removed coin are both
spent. The difference is that `coinsToRetain` keeps the old output queryable
for history (`includeSpent`). overlay-express deletes the removed ones.
Here nothing is deleted, so that a rejected spend can give them back.

## Settlement: `admits` propagates (#37)

An admitted output and an applied record stand on their transaction. The
wallet's `dependents` record this with rel `admits`, tag `m` for an
`admitted` key and tag `p` for an `applied` key. `Wallet.reject` follows
them:

- **A rejected transaction's admittances and judgements vanish.** Its
  spenders are rejected in turn (`spends`), so the rejection bubbles down a
  token's history.
- **A rejected spend gives back what it consumed.** `spent` counts only
  spenders that are not rejected, so the admitted outputs it spent are live
  in the topic again as the rejection is applied; its `applied` record (the
  retention) vanishes with it.

Rejections come from the same sources as the wallet's (docs/WALLET.md,
"Settlement"):

- a `status` entry (for example ARC's `DOUBLE_SPEND_ATTEMPTED`);
- a competing spend that gets proven;
- a submission that spends an output a proven transaction already spends,
  which is refused (`DoubleSpend`);
- resubmitting a rejected transaction, which is refused
  (`TransactionRejected`).

## The engine (`overlay`)

The engine is two things. Called (#40), it is the front door's route
handlers (below, "The wire"). Stepped, it handles the plain entries admitted
into it, through sender-less subscriptions:

| box | entry | does |
|---|---|---|
| `submit` | `{kind: "submit", beef, topics, offChainValues?}` (what `POST /submit` admits) | Step one verifies the BEEF (V1, V2 or Atomic; the subject is the Atomic one's, or else the last) against the held headers with the wallet's SPV. For each requested topic this instance serves that has not judged the transaction yet, it launches the topic's program; the thread waits on them. Step two reads the admittance records (`resolved`), then `overlay.apply` for each topic. It saves and advances `wallet`. |
| `chain` | `header` / `proof` / `status` | Handled as the wallet handles them. This is for an instance without a wallet program. |

There is no `lookup` box: a lookup is a read, and writes nothing.

**Config.** The config is the genesis `defaults`, from `etc/config.json`:

- `overlayTopics = '{"tm_demo":"topic-demo"}'` maps each topic to a `bin/`
  program name.
- `overlayLookups = '{"ls_demo":"lookup-demo"}'` maps each lookup service to
  a `bin/` program name.
- `walletNetwork` is the chain's network.

One instance may serve several topics and services.

**Result.** Each step keeps a result record and prints its CID:

- `{kind: "overlay-result", op: "submit", txid, steak: {topic:
  {outputsToAdmit, coinsToRetain, coinsRemoved}}, refs (mentions), state?}`
- `{op, error}` when refused, for example `InvalidBeef`, `UnknownHeader`,
  `ScriptFailed`, `TransactionRejected` or `DoubleSpend`.

The wire's answer is not read from this record: the route's `then` call reads
the STEAK from the `applied` records (below).

A topic that fails, or answers indices that do not fit, admits nothing.

## The topic contract

The engine launches the topic's program with these args:

```
{kind: "topic-call", topic, beef (as submitted), txid (hex), previousCoins: [input index], offChainValues?}
```

The program keeps and prints this record:

```
{kind: "admittance", topic, txid, outputsToAdmit: [output index], coinsToRetain: [input index]}
```

This is `identifyAdmissibleOutputs(beef, previousCoins, offChainValues)`.
With `topic.zig`, a topic is only its identify function:

```zig
pub fn identify(a: std.mem.Allocator, call: topic.Call) anyerror!topic.Instructions { … }
pub fn main() u8 { return topic.main(identify); }
```

`Call` carries the parsed BEEF, the subject transaction, the previous coins
and `sourceOutput(i)`.

**Documentation and metadata.** These come from the program record, which is
`bin/<name>.json` `description`. The first line is the `shortDescription`,
and the whole text is the documentation. The engine's listing and
documentation routes read them from the store, running no topic or lookup.

**`tm_demo`.** An output whose script starts `<"tm_demo"> OP_DROP` and
carries at least 1 satoshi is a token, and every token is admitted. A
transaction that admits a token retains the tokens it spends. One that admits
none removes them.

## The lookup contract

A lookup is a read (#40). The engine's `/lookup` handler calls the service's
program (an in-VM `call`, fn `"lookup"`) with this argument:

```
{kind: "lookup-call", service, query}
```

The query is the client's JSON as dag-cbor. Integers only: a non-integral
number is refused. The service reads the head `wallet` read-only and answers
(dag-cbor on stdout; nothing is kept or written) one of these records:

```
{kind: "lookup-answer", type: "output-list", outputs: [{beef, outputIndex, context?}]}
{kind: "lookup-answer", type: "freeform", result}
```

Each `beef` is the Atomic BEEF of the output's transaction, built from the
held records. It carries the ancestry back to proven transactions, with
their BUMPs (`Wallet.beefOf`). With `lookup.zig`, a service is
`answer(arena, *Wallet, service, query) !Answer`.

**`ls_demo`** takes these queries:

- `{topic}`
- `{scriptHash (hex sha256 of the locking script), topic?}`
- `{txid, outputIndex, topic}`

Each also takes `includeSpent` to return spent outputs.

## The wire: the instance's own front door (#40)

The overlay is served by the instance itself: its front door
(`programs/frontdoor`) matches the request against the genesis's routes
(`etc/routes.json`) and calls the engine's handler with it. The router only
proxies to the instance's origin. The routes are open (`auth: "none"`), as
overlay-express is.

| route | fn | | answer |
|---|---|---|---|
| `POST /submit` | `submit` | body BEEF (`application/octet-stream`); `X-Topics` a comma list (the SDK's form) or a JSON array; `x-includes-off-chain-values: true` → VarInt(len) ‖ BEEF ‖ values | the STEAK `{topic: {outputsToAdmit, coinsToRetain, coinsRemoved}}` over the requested topics this instance serves (unserved topics left out); 400 `{status: "error", message}` if refused |
| `POST /lookup` | `lookup` | `{service, query}` JSON; `X-Aggregation: yes` | `{type: "output-list", outputs: [{beef: [bytes], outputIndex, context?}]}`, or the compact octet-stream (count, per output txid ‖ index ‖ context, then one BEEF of them all, `Wallet.beefOfMany`); a freeform answer as `{type, result}` |
| `GET /listTopicManagers`, `/listLookupServiceProviders` | `listTopicManagers`, `listLookupServiceProviders` | | `{name: {name, shortDescription}}` |
| `GET /getDocumentationForTopicManager?manager=`, `/getDocumentationForLookupServiceProvider?lookupService=` | `topicDocumentation`, `lookupDocumentation` | | `text/markdown` |

**A submit is the one write.** The handler first checks it as a read: the
BEEF against the held headers (the same SPV), which requested topics this
instance serves, and which of them judged the transaction before. When
nothing is new — a bad BEEF, a rejected transaction, no served topic, a dupe
in every topic — it answers at once and nothing is written. Otherwise it
returns the entry for the host to admit, the `submit` event above, and
`then`: a call of fn `submitted` (program `overlay`, the genesis's program of
that name) that the host makes once the entry is processed. `submitted`
reads the STEAK from the state: each topic's `applied` record for the
transaction, empty for a topic that was a dupe or admitted nothing.

**A lookup writes nothing.** The handler calls the service's program and
shapes its answer for the wire. Listings and documentation read the program
records. equiv/overlay.ts checks it: across the lookups, a dupe, the
refusals and the listings, only the submit and the status entry are entries.

**The STEAK.** It carries exactly the three fields the stock client accepts.
The stock `validateSTEAK` refuses any other field, so the `ancillaryTxids`
of some engines are not sent.

**The origin.** The stock clients take an overlay host as an origin, with no
path (`LookupResolver` refuses one), so an overlay instance is reached at its
host-name origin, `http://<handle>.localhost:<port>`, not under `/@<handle>`.

**Tested with the stock clients** (equiv/overlay.ts). `TopicBroadcaster`
submits, with its facilitator pointed at the instance's origin, since the
`local` preset only knows `localhost:8080`. `LookupResolver`
(`hostOverrides`, `local` preset) queries, and its BEEF verifies with
`Transaction.verify` against the fed headers.

## A system tree for an overlay node

```
bin/frontdoor.wasm, bin/overlay.wasm, bin/topic-demo.wasm, bin/lookup-demo.wasm   (+ .json: description)
etc/config.json          {"defaults": {"walletNetwork": "regtest", "overlayTopics": "{\"tm_demo\":\"topic-demo\"}", "overlayLookups": "{\"ls_demo\":\"lookup-demo\"}"}}
etc/subscriptions.json   [{"box": "submit", "handler": "overlay"}, {"box": "chain", "handler": "overlay"}]
etc/routes.json          [{"path": "/submit", "program": "overlay", "fn": "submit", "auth": "none"},
                          {"path": "/lookup", "program": "overlay", "fn": "lookup", "auth": "none"},
                          {"path": "/listTopicManagers", "program": "overlay", "fn": "listTopicManagers", "auth": "none"},
                          {"path": "/listLookupServiceProviders", "program": "overlay", "fn": "listLookupServiceProviders", "auth": "none"},
                          {"path": "/getDocumentationForTopicManager", "program": "overlay", "fn": "topicDocumentation", "auth": "none"},
                          {"path": "/getDocumentationForLookupServiceProvider", "program": "overlay", "fn": "lookupDocumentation", "auth": "none"}]
```

The front door must be in `bin/` (a tree's programs are its own):
equiv/overlay.ts copies the kernel's `wasm/frontdoor.wasm`. These routes
replace the stock ones, so this node has no messagebox (add the stock
routes to keep one).

**The loader change.** For a tree, the boot loader now asks the kernel only
for the `shell` record. `serve`'s `programs` frame takes a list of names.
Before, every pinned record was put, and the ones a tree does not use sat
unreferenced. A replay does not reproduce such records, so this change is
what lets a non-stock tree replay exactly.
