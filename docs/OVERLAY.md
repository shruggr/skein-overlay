# Overlay services in the VM (issues #36, #50)

An overlay is the same transaction graph the wallet holds (#29), judged and
indexed differently. A submitted transaction is decoded once into records,
checked against the headers the instance holds, then judged by topic
managers. Topic managers are programs. Lookup services are programs too, and
they are pluggable in the submission flow as topic managers are: the engine
calls their hooks when a topic admits a transaction, when a previous coin is
spent, and when a judgement is rejected, and each keeps its own indexes under
its own head. A lookup answers from those indexes.

Only the wire contract is taken from the standard libraries. That contract is
BRC-22 submit, BRC-24 lookup, and overlay-express's listing and documentation
routes. The go-sdk `overlay/` engine and ts-stack `packages/overlays`
storage are not ported.

**Not built:**

- BRC-88 SHIP/SLAP advertisement. Clients reach an instance through the
  `hostOverrides` / `facilitator` options of the stock clients.
- Sync between overlay nodes (GASP).
- The `historical-tx` modes.
- BRC-64 history queries beyond "spent too" (`includeSpent`).

## Pieces

| where | what |
|---|---|
| `wallet-zig/src/overlay.zig` | The overlay's state in the chain and settlement core, and the submission's records: `decode` (the one BEEF parse), `verifyDecoded` (SPV over the records), `holdDecoded`, the previous coins, recording a topic's judgement (`apply`), the derived map, the hooks' dispatch (`Caller`, `listeners`, `hookAdmitted`, `hookRejected`), each output's BEEF for a lookup answer. |
| `programs/overlay/src/engine.zig` → `overlay.wasm` | The engine: called, the front door's route handlers (`routes.zig`); stepped, the handler for the `submit` and `chain` entries. |
| `programs/overlay/src/submit.zig` | A submission from the wire to the state: the route's half (decode, verify, judge — in the call) and the step's half (hold, record, hooks). |
| `programs/overlay/src/routes.zig` | The route handlers (#40): the overlay-express wire contract. |
| `programs/overlay/src/topic.zig` | The topic contract (a library). |
| `programs/overlay/src/lookup.zig` | The lookup contract (a library): hooks, own storage, answers. |
| `programs/overlay/src/topic_demo.zig` → `topic-demo.wasm` | `tm_demo`, an example topic. |
| `programs/overlay/src/lookup_demo.zig` → `lookup-demo.wasm` | `ls_demo`, an example lookup service with its own index. |
| `kernel-zig/equiv/overlay.ts` | End to end, with the stock `@bsv/sdk` clients. It is part of `equiv/run.sh`. |

Build and test the programs from `programs/overlay`:

```
zig build        # zig-out/bin/{overlay,topic-demo,lookup-demo}.wasm
zig build test   # the submission flow and the contracts, natively
```

wallet-zig is a path dependency. Its library module is exported as `wallet`,
and bsvz comes through it. The programs are not pinned. An instance takes
them from its system tree's `bin/`.

## A submission, from the wire to the state (#50)

**Decode once.** The `/submit` route handler is a front-door call (#40): it
writes nothing. It decodes the submitted BEEF (V1, V2 or Atomic; the subject
is the Atomic one's, or else the last) exactly once, into records:

- each transaction a `bitcoin-tx` block (its CID is its txid);
- each BUMP the merkle nodes it reveals, 64-byte `bitcoin-tx` blocks (#29,
  #42: a node's CID is its merkle hash).

The blocks are `putblock`ed, so they land in the call's in-memory overlay.
No BEEF object crosses a program boundary after that: the store is the
hydrated object. SPV (`verifyDecoded`), the previous coins and the topic
managers read typed records through `get`, which reads through the overlay:

- every BUMP's root is our header's merkle root at its height (an unknown
  height is refused), and each transaction a BUMP proves is reached from that
  root through the merkle nodes;
- every other transaction's inputs come from a transaction decoded before it
  or held, with their scripts verified;
- a subject already rejected is refused (`TransactionRejected`), and so is
  one spending an output a proven transaction spends (`DoubleSpend`).

In a test build `wallet-zig/src/beef.zig` counts its parses
(`beef.parses`); programs/overlay's test asserts one parse per submit,
across the route, the topic, the step and the hooks.

**Judge in the call.** For each requested topic this instance serves and has
not judged the transaction for, the handler calls the topic's program (fn
`identify`, below) with the transaction's CID and its previous coins. The
topic reads the transaction and its inputs' sources through the same
overlay.

**Nothing persists until admitted.** If no topic takes anything (no output
admitted and no previous coin consumed), or every such topic's program fails,
or the transaction is one we already rejected, the call answers **200 with the
empty STEAK** (BRC-22 and overlay-express's answer; the reasons are kept for
the log) and returns no entry. The overlay is dropped with the call, and the
store is byte for byte what it was (equiv/overlay.ts checks the store file).
Only a BEEF that does not decode or verify answers 400
`{status: "error", message}`. A transaction every served topic judged before
(a dupe) answers the empty STEAK too, also writing nothing.

**Admitted: one step.** Otherwise the handler returns the entry for the host
to admit: a plain event in box `submit` carrying the decoded records and the
judgements, not a BEEF:

```
{kind: "submit", txid (hex), txs: [bytes], nodes: [bytes], proofs: [{txid: bytes, height, depth, position}],
 topics: [{topic, previousCoins, outputsToAdmit, coinsToRetain}], offChainValues?: bytes}
```

The engine, stepped on it, does everything in that one step:

1. **Holds the records** (`holdDecoded`): each transaction's block is kept and
   put in `txs` (so #42's `spends` edges appear), the merkle nodes are kept
   (no edges: a proof reads down from the root), and each proven transaction's proof is recorded from the
   header its nodes reach (`Wallet.putProofAt`).
2. **Records each judgement** (`apply`): the admittances and the `applied`
   record. The previous coins are taken again. If they moved since the call
   (another submission in between), the topic is asked again, in the step,
   over the held records.
3. **Calls the lookup services' hooks** for each topic that took something:
   `admitted`, then `spent` for each previous coin the transaction consumed.
   The services' map updates are that step's head moves.

Only the host admits plain entries (the front door's answer, the feeds). A
message into box `submit` is not a plain event, and the engine refuses it,
so the judgements an entry carries are always the route's. The route's
`then` call reads the STEAK back from the `applied` records.

## One chain, one settlement: how the wallet and the overlay split

There is one state record, the one the head `wallet` names (`wallet-state`).
It holds the chain tracker, the transactions, the proofs, the `dependents`
relations and the settlement (`rejected`). Who spends what is the kernel's
`spends` edges (#42: every held transaction is a kept bitcoin-tx block, each
input an edge). These are the wallet's records and maps, unchanged. The
overlay's maps are added to the same record (wallet.zig `map_names`), and
wallet-zig's `Wallet` is the core both programs load:

- **The wallet program** writes actions, outputs, drafts and broadcasts.
- **The overlay engine** writes the transactions a topic took (held like any
  other, through `putTx`: kept, so each input is a `spends` edge) and the
  overlay maps.
- **Both** apply headers, proofs and statuses the same way (`addHeaders`,
  `applyStatus`), and both call the lookup services' `rejected` hooks for
  the judgements a rejection removes (`Wallet.unapplied`).

The derived map is maintained where a fact changes (#41; docs/WALLET.md
"Derived maps are maintained"), not rebuilt at save.

When an instance runs both programs, the chain feed (box `chain`) should be
routed to the wallet, because only the wallet re-broadcasts after a reorg. An
overlay-only instance routes `chain` to the engine.

## Maps

`tp` is len ‖ topic. The outpoint is txid (internal order) ‖ vout (u32 BE).

| map | key → value | |
|---|---|---|
| `admitted` | tp ‖ outpoint → admittance record | an output a topic admitted |
| `applied` | tp ‖ txid → applied record | the topic's judgement of this transaction: a later submission is a dupe; which previous coins it retained |
| `byTopic` | tp ‖ 0 (unspent) \| 1 (spent) ‖ outpoint → null | derived: `admitted` joined to the spends edge |

Indexes for answering queries are not here: each lookup service keeps its
own (below). The shared `byScript` map was only the demo lookup's, so it
left with #50.

**Spent within a topic is a join, not a table (#36 notes).** An admitted
output is spent when the wallet's `spent[outpoint]` names a spender — the
first transaction we hold that spends it and is not rejected (the `spends`
edge in the kernel's index, read with `edges`, topic-independent:
docs/WALLET.md). The one bit a consumed table would carry — whether the
topic kept the coin for history — is the topic's judgement of the
*spending* transaction, so it lives on that transaction's `applied` record
(`coinsToRetain`, input indices; the STEAK as stored).
`overlay.spender(topic, txid, vout)` gives both: the spender, and whether
this topic judged it and retained the coin.

**Maintained (#41).** A judgement (`apply`) writes each admittance's
`byTopic` key under its current state. The previous coins it consumes turn
spent through the transaction's own `spends` edges: `Wallet.refreshSpent` →
`overlay.spentChanged` moves the keys of every topic that admitted the
outpoint (found through `dependents`, tag `m`). A rejection
(`Wallet.reject`) removes each vanished admittance with its keys (`unadmit`)
and its `applied` record; the coins the rejected transaction spent move back
to unspent the same way, unless another spender stands.

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
hold that is not rejected (the one being judged does not count).

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
  spenders are rejected in turn (its `spends` edges), so the rejection
  bubbles down a token's history.
- **A rejected spend gives back what it consumed.** `spent` counts only
  spenders that are not rejected, so the admitted outputs it spent are live
  in the topic again as the rejection is applied; its `applied` record (the
  retention) vanishes with it.
- **The lookup services are told.** Each removed `applied` record is noted
  (`Wallet.unapplied`: topic, txid, in the walk's order). The program that
  applied the rejection — the engine on the `chain` feed, or the wallet
  program — then calls `rejected(topic, tx)` on each service listening to
  that topic, in the same step.

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
| `submit` | the submit event above (what `POST /submit` admits) | Holds the records, records each topic's judgement, calls the lookup services' `admitted` / `spent` hooks; saves and advances `wallet`. |
| `chain` | `header` / `proof` / `status` | Handled as the wallet handles them, then `rejected` for each judgement a rejection removed. This is for an instance without a wallet program. |

There is no `lookup` box: a lookup is a read, and writes nothing.

**Config.** The config is the genesis `defaults`, from `etc/config.json`:

- `overlayTopics = '{"tm_demo":"topic-demo"}'` maps each topic to a `bin/`
  program name.
- `overlayLookups = '{"ls_demo":{"program":"lookup-demo","topics":["tm_demo"]}}'`
  maps each lookup service to a `bin/` program name and the topics it
  listens to (its hooks are called for those). The short form
  `'{"ls_demo":"lookup-demo"}'` listens to every topic in `overlayTopics`.
- `walletNetwork` is the chain's network.

One instance may serve several topics and services.

**Result.** Each step keeps a result record and prints its CID:

- `{kind: "overlay-result", op: "submit", txid, steak: {topic:
  {outputsToAdmit, coinsToRetain, coinsRemoved}}, refs (mentions), state}`
- `{kind: "overlay-result", op: "event", event, …, state}` for the chain feed
- `{op, error}` when the step fails.

A topic whose instructions do not fit the transaction admits nothing.

## The topic contract

A topic manager is a program called, not launched: an in-VM call of fn
`identify`, in the `/submit` call (and, only if its previous coins moved, in
the step), with the argument

```
{kind: "topic-call", topic, tx: <bitcoin-tx CID>, previousCoins: [input index], offChainValues?}
```

It answers (dag-cbor on stdout)

```
{kind: "admittance", topic, txid, outputsToAdmit: [output index], coinsToRetain: [input index]}
```

That is `identify(tx: cid, previousCoins, offChain?) → {outputsToAdmit,
coinsToRetain}`, BRC-22's `identifyAdmissibleOutputs` on a CID instead of a
BEEF. With `topic.zig`, a topic is only its identify function:

```zig
pub fn identify(a: std.mem.Allocator, call: topic.Call) anyerror!topic.Instructions { … }
pub fn main() u8 { return topic.main(identify); }
```

`Call` carries the transaction (decoded from its block, read through `get`),
its CID, the previous coins, the off-chain values, and `sourceOutput(i)` /
`transaction(txid)`, which read other transactions through `get` as well.

**Documentation and metadata.** These come from the program record, which is
`bin/<name>.json` `description`. The first line is the `shortDescription`,
and the whole text is the documentation. The engine's listing and
documentation routes read them from the store, running no topic or lookup.

**`tm_demo`.** An output whose script starts `<"tm_demo"> OP_DROP` and
carries at least 1 satoshi is a token, and every token is admitted. A
transaction that admits a token retains the tokens it spends. One that admits
none removes them.

## The lookup contract (#50)

A lookup service is a program with its own storage and four functions, all
in-VM calls. The hooks are called by the engine (or the wallet program, for
`rejected`) in the step that admits a submission or applies a rejection;
they receive CIDs, never bytes, and read the transactions through `get`:

| fn | argument | when |
|---|---|---|
| `admitted` | `{kind: "lookup-hook", service, topic, tx: <CID>, outputsToAdmit: [vout], coinsRetained: [input index]}` | a topic it listens to admitted a transaction (or consumed previous coins) |
| `spent` | `{kind: "lookup-hook", service, topic, outpoint: {tx: <CID>, vout}, spendingTx: <CID>}` | for each previous coin that transaction consumed (retained or removed) |
| `rejected` | `{kind: "lookup-hook", service, topic, tx: <CID>}` | a judgement of that topic was removed by a rejection (#37's walk) |
| `lookup` | `{kind: "lookup-call", service, query}` | `POST /lookup`: a read |

A hook may be a no-op. **Own storage:** a service keeps named maps (the
shared MST module, wallet-zig `store.zig`) under its own head `ls:<service>`,
a record `{kind: "lookup-state", service, maps: {name: root | null}}`. The
maps are written only through the hooks: a hook that changes them puts the
new nodes and state record and advances the head, which is the step's head
move. `lookup` reads them (and the chain+settlement core, read only, for
the BEEF), and writes nothing.

The `lookup` answer (dag-cbor on stdout) is one of:

```
{kind: "lookup-answer", type: "output-list", outputs: [{beef, outputIndex, context?}]}
{kind: "lookup-answer", type: "freeform", result}
```

Each `beef` is the Atomic BEEF of the output's transaction, built from the
held records. It carries the ancestry back to proven transactions, with
their BUMPs (`Wallet.beefOf`). The query is the client's JSON as dag-cbor.
Integers only: a non-integral number is refused.

With `lookup.zig`, a service is a `Spec`:

```zig
pub const spec: lookup.Spec = .{
    .maps = &.{ "outputs", "byTopic", "byScript" },
    .answer = answer,       // (arena, *Service, *Wallet, query) !Answer
    .admitted = admitted,   // (arena, *Service, topic, Tx, outputs_to_admit, coins_retained) !void
    .spent = spent,         // (arena, *Service, topic, Outpoint, spending: Tx) !void
    .rejected = rejected,   // (arena, *Service, topic, Tx) !void
};
pub fn main() u8 { return lookup.main(spec); }
```

`Service.map(name)` is one of its maps; `lookup.handle` runs one call over a
given store and head (the tests call it directly).

**`ls_demo`** keeps its own index through the hooks:

| map | key → value |
|---|---|
| `outputs` | tp ‖ outpoint → sha256(locking script) [‖ spending txid] |
| `byTopic` | tp ‖ 0 (unspent) \| 1 (spent) ‖ outpoint → null |
| `byScript` | sha256(locking script) ‖ tp ‖ 0 \| 1 ‖ outpoint → null |

`admitted` adds the admitted outputs (unspent); `spent` moves an output to
spent and names its spender; `rejected` drops the rejected transaction's
outputs and gives back the ones it had spent. It answers from these maps
alone:

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

**A submit is the one write**, and only when a topic takes the transaction
(above). Otherwise the handler returns the entry and `then`: a call of fn
`submitted` (program `overlay`, the genesis's program of that name) that the
host makes once the entry is processed. `submitted` reads the STEAK from the
state: each topic's `applied` record for the transaction, empty for a topic
that was a dupe or admitted nothing.

**A lookup writes nothing.** The handler calls the service's program and
shapes its answer for the wire. Listings and documentation read the program
records. equiv/overlay.ts checks it: across the lookups, a dupe, the
refusals and the listings, only the submits and the status entry are
entries, and a refused submit leaves the store file byte-identical.

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
etc/config.json          {"defaults": {"walletNetwork": "regtest", "overlayTopics": "{\"tm_demo\":\"topic-demo\"}",
                          "overlayLookups": "{\"ls_demo\":{\"program\":\"lookup-demo\",\"topics\":[\"tm_demo\"]}}"}}
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
