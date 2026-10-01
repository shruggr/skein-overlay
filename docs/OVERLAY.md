# Overlay services in the VM (issues #36, #50, #57)

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
- Sync between overlay nodes (GASP); catch-up from a peer. The push half —
  submissions, admits and proofs as they happen — is the gossip (#74, below).
- The `historical-tx` modes.
- BRC-64 history queries beyond "spent too" (`includeSpent`).

## Pieces

| where | what |
|---|---|
| the SDK's `wallet/src/overlay.zig` (shruggr/skein-sdk) | The overlay's state in the chain and settlement core, and the submission's records: `decode` (the one BEEF parse), `verifyDecoded` (SPV over the records), `holdDecoded`, the previous coins, recording a topic's judgement (`apply`), the derived map, the hooks' dispatch (`Caller`, `listeners`, `hookAdmitted`, `hookRejected`), each output's BEEF for a lookup answer. |
| `src/engine.zig` → `overlay.wasm` | The engine: called, the front door's route handlers (`routes.zig`); stepped, the handler for the `submit` and `chain` entries. |
| `src/submit.zig` | A submission from the wire to the state: the route's half (decode, verify, judge — in the front door's step on the request), the step's half (hold, broadcast — an event, #65 — then record and call the hooks once the gate lets it through: the first of a status or the proof, #73), and the steps while it is pending (#57). |
| `src/routes.zig` | The route handlers (#40): the overlay-express wire contract, and the gossip's inbound routes (`peerAdmit`, `peerProof`, #74). |
| `src/gossip.zig` | The three gossip topics (#74): message shapes, what an admission and a proof publish, a peer's proof checked, the peer-admit records. |
| `src/topic.zig` | The topic contract (a library). |
| `src/lookup.zig` | The lookup contract (a library): hooks, own storage, answers. |
| `src/topic_demo.zig` → `topic-demo.wasm` | `tm_demo`, an example topic. |
| `src/lookup_demo.zig` → `lookup-demo.wasm` | `ls_demo`, an example lookup service with its own index. |
| skein's `kernel-zig/equiv/overlay.ts` | End to end, with the stock `@bsv/sdk` clients, over this repo's `bin/` (cloned at a pinned commit, or `$SKEIN_OVERLAY_DIR`). It is part of skein's `equiv/run.sh`. |

Build and test the programs from this repo (Zig 0.16.0, `mise.toml`):

```
zig build        # zig-out/bin/{overlay,topic-demo,lookup-demo}.wasm
zig build bin    # the same, into bin/ (committed)
zig build test   # the submission flow and the contracts, natively
```

The SDK (shruggr/skein-sdk) is a URL+hash dependency in `build.zig.zon`. Its
wallet library module is `wallet`, and bsvz comes through it. The programs
are not pinned in skein. An instance takes them from its system tree's `bin/`
(this repo's `bin/*.wasm`, committed).

Paths below that are not this repo's (`docs/*.md`, `programs/frontdoor`,
`src/host/*`, `wasm/`, `equiv/*.ts`) are shruggr/skein's.

## A submission, from the wire to the state (#50)

**Decode once.** The `/submit` route handler runs in the front door's step
on the request (#68: the request is appended as received). It decodes the
submitted BEEF (V1, V2 or Atomic; the subject
is the Atomic one's, or else the last) exactly once, into records:

- each transaction a `bitcoin-tx` block (its CID is its txid);
- each BUMP the merkle nodes it reveals, 64-byte `bitcoin-tx` blocks (#29,
  #42: a node's CID is its merkle hash).

The blocks are `putblock`ed, so they land in the step's write cache. No
BEEF object crosses a program boundary after that: the store is the
hydrated object. SPV (`verifyDecoded`), the previous coins and the topic
managers read typed records through `get`, which reads through the cache:

- every BUMP's root is our header's merkle root at its height (an unknown
  height is refused), and each transaction a BUMP proves is reached from that
  root through the merkle nodes;
- every other transaction's inputs come from a transaction decoded before it
  or held, with their scripts verified;
- a subject already rejected is refused (`TransactionRejected`), and so is
  one spending an output a proven transaction spends (`DoubleSpend`).

In a test build the SDK's `wallet/src/beef.zig` counts its parses
(`beef.parses`); this repo's test.zig asserts one parse per submit,
across the route, the topic, the step and the hooks.

**Judge in the step.** For each requested topic this instance serves and has
not judged the transaction for, the handler calls the topic's program (fn
`identify`, below) with the transaction's CID and its previous coins. The
topic reads the transaction and its inputs' sources through the same
cache.

**Nothing moves until admitted.** If no topic takes anything (no output
admitted and no previous coin consumed), or every such topic's program fails,
or the transaction is one we already rejected, the handler answers **200 with
the empty STEAK** (BRC-22 and overlay-express's answer; the reasons are kept
for the log) and starts nothing: the request is recorded, and no head moves
(equiv/overlay.ts checks the overlay's and the lookup service's heads). Only
a BEEF that does not decode or verify answers 400 `{status: "error",
message}`. A resubmission of a transaction every served topic judged before
(a dupe) is answered from the state at once (the STEAK of what was
admitted); one of a transaction held and pending (below) waits on the
first submission's thread ("The answer", below).

**Admitted into the graph, then broadcast (#57).** Otherwise the handler
launches the submission's thread — the engine on the submit record, as a
`submit` event would start it (args `{event, box: "submit"}`) — carrying
the decoded records and the judgements, not a BEEF, and answers `{wait:
true}`: the request's thread waits on it (#66). (A gossiped submission
admits the same record as an event in box `submit` instead, and the
`submit` subscription starts the same engine; its verdict goes back at
once.)

```
{kind: "submit", txid (hex), txs: [bytes], nodes: [bytes], proofs: [{txid: bytes, height, depth, position}],
 topics: [{topic, previousCoins, outputsToAdmit, coinsToRetain}], offChainValues?: bytes}
```

The record puts the transaction in the graph. No output is admitted until
the broadcast gate lets it through (#65, #73, below). The engine, stepped on it:

1. **Holds the records** (`holdDecoded`): each transaction's block is kept and
   put in `txs` (so #42's `spends` edges appear), the merkle nodes are kept
   (no edges: a proof reads down from the root), and each proven transaction's proof is recorded from the
   header its nodes reach (`Wallet.putProofAt`).
2. **Gates on broadcast** (#57, #65, #73). A subject the entry proves (its
   BUMP reaches a header we hold) is mined: no broadcast, straight to 3.
   Otherwise the step broadcasts it — an event, `{event: "broadcast", tx,
   beef}` (its Atomic BEEF built from the held records, `Wallet.beefOf`),
   addressed to no one; the host's wiring carries it (the reference host:
   its broadcaster's durable queue and Arcade session, docs/WALLET.md) —
   and leaves it pending: there is no setting. It is admitted on the first
   of a status provider's word that the network has it (with none
   subscribed, address book role `status`, nothing ever says so) or its
   proof, whichever arrives first; the other, after, only settles or notes
   it. Admission on validation alone is not a mode: an instance with no
   status feed admits at the proof.

   Pending: the `broadcast` record says `submission: "pending"`, nothing is
   admitted, and the thread awaits (4).
3. **Admits.** Each judgement recorded (`apply`): the admittances and the
   `applied` record. The previous coins are taken again; if they moved since
   the call (another submission in between), the topic is asked again, over
   the held records. Then the lookup services' hooks for each topic that took
   something: `admitted`, then `spent` for each previous coin the
   transaction consumed. The services' map updates are that step's head
   moves.
4. **Awaits while pending.** The step `await`s the transaction's CID and
   sets a `deadline` at its abandonment (`walletAbandonMs` after its first
   broadcast). What steps it again:
   - a **status message** from the status provider it subscribes to (input
     `message`, routed by its subject): a rejection (`REJECTED`,
     `DOUBLE_SPEND_ATTEMPTED`, `INVALID`, `MALFORMED`) rejects it (#37's
     walk); any other status admits it (3) — the first of the two signals;
   - its **proof event** (box `chain`, input `event`): proven — admitted (3,
     gate `mined`); a path whose header we do not hold yet leaves it pending;
   - the **deadline**: abandoned if still pending (rejected, `abandoned`).

   Once admitted, the other signal — arriving after — only settles it (the
   proof) or is noted (a status): no second admission.

   Admitted or rejected, the submission's thread **finishes** (#66): the
   requests waiting on it answer. What follows for an admitted, unproven
   transaction — its statuses, its proof, a double spend — comes through
   the chain feed (box `chain`) and the status subscription (box `status`),
   to the engine or the wallet, nobody waiting: a merkle path proves it, a rejection
   (`DOUBLE_SPEND_ATTEMPTED`, …) unwinds its admittances and lookup entries
   through `admits` (#37, below); a reorg that unproves it is re-proven the
   same way.

Only a front
door's step (the submit handler: a launch, or the gossip route's admitted
event) and the host's feeds start the engine; a message into box `submit`
is not an event, and the engine refuses it, so the judgements it carries
are always the route's.

**The answer** (#66). When the submission's thread comes to rest, the
request waiting on it calls the handler again (`resolved`), which reads the
answer from the state:

| state of the transaction | answer |
|---|---|
| admitted (or judged before) | 200, the STEAK from each topic's `applied` record (empty for a topic that took nothing) |
| still pending (the thread errored before it was admitted) | **503** `{status: "error", message}` with `Retry-After: 30`: nothing admitted; resubmit |
| rejected (a status provider's rejection, a competing proof, abandonment) | **400** `{status: "error", message: "Transaction rejected: <reason>"}` (overlay-express's error form; the stock `TopicBroadcaster` counts it a failure) |

While the thread waits on the gate the client waits too, up to the host's bound
(`answerWaitMs`): then 503 + `Retry-After` from the host, and the thread
goes on. A resubmission while pending waits on the same thread (the
`broadcast` record names it) and gets the same answer; after admission it
gets the STEAK at once. A resubmission of a rejected transaction is refused
in its step (`TransactionRejected`: 200, the empty STEAK, unchanged from
#50).

## One chain, one settlement: how the wallet and the overlay split

There is one state record, the one the head `wallet` names (`wallet-state`).
It holds the chain tracker, the transactions, the proofs, the `dependents`
relations and the settlement (`rejected`). Who spends what is the kernel's
`spends` edges (#42: every held transaction is a kept bitcoin-tx block, each
input an edge). These are the wallet's records and maps, unchanged. The
overlay's maps are added to the same record (wallet.zig `map_names`), and
The SDK wallet's `Wallet` is the core both programs load:

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
| `awaiting` (the wallet's, shared) | txid → broadcast record | a submission broadcast and not yet proven or rejected (#57): `submission: "pending"` until the gate admits it |

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
- **Broadcast** (#57, the wallet's record, in the shared `awaiting` map:
  txid → record while the transaction awaits its status): `{kind:
  "broadcast", txid, subject: <tx CID>, txStatus, since, submission, thread}`.
  `txStatus` is the status provider's last word, `since` the first
  broadcast's time (the abandonment clock), and `submission` the overlay's:
  `"pending"` while the gate has not admitted it (nothing admitted),
  `"admitted"` once it has (`Wallet.noteSubmission`). A later status re-notes
  the record through `noteBroadcast`, which drops the field; only `pending`
  is read. Proven or rejected, the transaction leaves `awaiting`.

The step keeps the admittance and applied records. Their `refs` give the
kernel `admits` edges (docs/VM.md, "Edges").

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

- a status provider's rejection (#65: Arcade's 400 or its `REJECTED`,
  `DOUBLE_SPEND_ATTEMPTED`, …), which steps the submission's awaiting thread
  while it is pending, or reaches the engine by the status subscription
  after;
- the submission abandoned, never mined within `walletAbandonMs` (while
  pending);
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
| `submit` | the submit event above (what `POST /submit` admits) | Holds the records; unless mined, broadcasts the transaction (an event, #65); once the gate admits it (the first of a status or the proof, #73), records each topic's judgement and calls the lookup services' `admitted` / `spent` hooks; saves and advances `wallet`; awaits the transaction while pending or unproven (#57). |
| `submit` | `peer-admit` (what the `-admit` route admits, #74) | Recorded under the head `overlay:gossip` ("Gossip", below); nothing admitted. |
| `chain` | `header` (`raw`, or a run `raws`, parents first: a reorg's heavier branch in one event) / `proof` / `status` | Handled as the wallet handles them, then `rejected` for each judgement a rejection removed. This is for an instance without a wallet program. A `status` / `proof` for a transaction whose submission thread awaits it steps that thread instead. A proof recorded for an admitted transaction is published on `<topic>-proof` (#74). |

There is no `lookup` box: a lookup is a read: its request is recorded, and it moves nothing.

**Config.** The config is the genesis `defaults`, from `etc/config.json`:

- `overlayTopics = '{"tm_demo":"topic-demo"}'` maps each topic to a `bin/`
  program name.
- `overlayLookups = '{"ls_demo":{"program":"lookup-demo","topics":["tm_demo"]}}'`
  maps each lookup service to a `bin/` program name and the topics it
  listens to (its hooks are called for those). The short form
  `'{"ls_demo":"lookup-demo"}'` listens to every topic in `overlayTopics`.
- `walletNetwork` is the chain's network.
- There is no admission setting (#73): an unproven submission is admitted on
  the first of a status provider's word that the network has it, or its
  proof — with no status provider in the address book, nothing ever says
  so, so it is admitted at the proof.
- The broadcaster is not config: a broadcast is an event the host carries
  (#65). A status provider is the address book's role `status` plus the
  subscription `{"sender": "$status", "box": "status", "handler":
  "overlay"}` in etc/subscriptions.json.
- `overlayGossip = '{"tm_demo": false}'` turns a topic's gossip publishing
  off (#74; default on, "Gossip" below).
- `walletAbandonMs` (default 86400000) is shared with the wallet: a pending
  transaction neither taken nor mined that long after its first broadcast
  is abandoned (rejected), one rule for the chain core.

The app's manifest (`etc/app.json`, skein docs/APPS.md §6) carries the same
settings as `config.overlay`: `topics` is `overlayTopics`, `lookups` is
`overlayLookups`, `gossip` is `overlayGossip`, and `status` names the status
provider whose messages the `status` box takes. The engine still reads the
genesis defaults. Reading `config.overlay` from the manifest at its head's
root is skein #72 (build 3).

One instance may serve several topics and services.

**Result.** Each step keeps a result record and prints its CID:

- `{kind: "overlay-result", op: "submit", txid, gate: "mined" | "accepted"
  | "rejected" | "pending", outcome: "proven" | "pending" | "rejected",
  arc?: {status, txStatus, extraInfo, merklePath?}, steak?: {topic:
  {outputsToAdmit, coinsToRetain, coinsRemoved}}, awaiting?, refs
  (mentions), state}` — `steak` when this step admitted it, `awaiting` when
  the thread rests;
- `{kind: "overlay-result", op: "callback", …, event: <kind> | woke: true}`
  for the awaiting thread's steps (the same fields);
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
shared MST module, the SDK wallet's `store.zig`) under its own head `ls:<service>`,
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
| `POST /submit` | `submit` | body BEEF (`application/octet-stream`); `X-Topics` a comma list (the SDK's form) or a JSON array; `x-includes-off-chain-values: true` → VarInt(len) ‖ BEEF ‖ values | the STEAK `{topic: {outputsToAdmit, coinsToRetain, coinsRemoved}}` over the requested topics this instance serves (unserved topics left out); 400 `{status: "error", message}` if refused or rejected; 503 with `Retry-After` while it is pending (#57) |
| `POST /lookup` | `lookup` | `{service, query}` JSON; `X-Aggregation: yes` | `{type: "output-list", outputs: [{beef: [bytes], outputIndex, context?}]}`, or the compact octet-stream (count, per output txid ‖ index ‖ context, then one BEEF of them all, `Wallet.beefOfMany`); a freeform answer as `{type, result}` |
| `GET /listTopicManagers`, `/listLookupServiceProviders` | `listTopicManagers`, `listLookupServiceProviders` | | `{name: {name, shortDescription}}` |
| `GET /getDocumentationForTopicManager?manager=`, `/getDocumentationForLookupServiceProvider?lookupService=` | `topicDocumentation`, `lookupDocumentation` | | `text/markdown` |

**A submit is the one write**, and only when a topic takes the transaction
(above). Otherwise the handler returns the entry and `then`: a call of fn
`submitted` (program `overlay`, the genesis's program of that name) that the
host makes once the entry is processed. `submitted` reads the answer from the
state ("The answer", above): the STEAK from each topic's `applied` record for
the transaction (empty for a topic that admitted nothing), 503 with
`Retry-After` while it is pending, 400 if it was rejected. A
resubmission returns only `then` (no entry). The `then` call's answer is
`{status, type?, headers?, body}`; the router passes its headers through
(`src/host/router.ts`, `forward`), which is how the 503 carries
`Retry-After`.

**The same submit over GossipSub** (#57). A `libp2p:<topic>` route may name
the same fn: `{"path": "libp2p:tm_demo", "program": "overlay", "fn":
"submit"}`. The front door verifies the message's signature (docs/MESSAGES.md,
"libp2p") and calls `submit` with it; the handler sees `transport: "libp2p"`
and takes the message's topic as the one requested, its body as the BEEF (no
off-chain values), and runs the same route half. Its answer is the libp2p
handler contract: **accept** with the same submit entry `POST /submit` returns
(no `then`: there is no one to answer), which the front door forwards after the
message's own `p2p` entry, so the step persists exactly what the HTTP path
does — through the same broadcast gate (#57: the step posts it to ARC and
admits it only once ARC takes it); **ignore** (no forward, no penalty) when
the topic is not served, nothing is new (a dupe, no topic takes it, or it is
held and awaiting ARC) or the BEEF is refused — a refusal may be this
instance's missing headers rather than the publisher's fault. A
redelivered message writes nothing: its `p2p` entry is refused first, and the
submit entry with it. equiv/overlay.ts checks it: a second instance fed the
token transaction by GossipSub holds the same `applied` / `admitted` records
(but for each step's time), `byTopic` map and lookup storage as the one fed by
`POST /submit`, and the redelivery leaves its store file byte-identical.

**A lookup writes nothing.** The handler calls the service's program and
shapes its answer for the wire. Listings and documentation read the program
records. equiv/overlay.ts checks it: across the lookups, a dupe, the
refusals and the listings, only the requests and the status provider's
messages are entries, and a refused submit leaves the store file byte-identical.

**The broadcast gate end to end** (#57, #65, equiv/overlay.ts): the router
runs the host's broadcaster (#58) in front of a fake Arcade
(`src/host/fake-arcade.ts`); the instances subscribe to its status provider.
Each unproven submission is broadcast as an event, which the host queues and
posts (Extended Format), and admitted on Arcade's RECEIVED (a status
message), the GossipSub one too (Arcade's duplicate answer reaches its
broadcaster); the three tokens' `SEEN_ON_NETWORK` statuses (messages) and
`MINED` proofs (events, with their merkle paths) come back over Arcade's SSE
stream and prove them; a `DOUBLE_SPEND_ATTEMPTED` after admission unwinds the
spend's admittance and lookup entries; a resubmission answers the STEAK from
the state; a mined submission is admitted with no POST; Arcade's 400 (a
REJECTED status) answers the client 400 with nothing admitted. With Arcade
busy (503), the host keeps the transaction queued: the client waits until the
router's bound (503 + Retry-After), a resubmission appends nothing and gets
503 again, and once Arcade takes the queue's next post it is admitted and the
waiting clients get the STEAK. Each store replays to itself exactly.

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

## Gossip: the three topics (#74)

For each overlay topic `<topic>` it runs, an overlay speaks three GossipSub
topics, three meanings (`src/gossip.zig`). Bodies are
dag-cbor unless said; a txid and a block hash are hex in display order.

| topic | body | published | received (route → fn) |
|---|---|---|---|
| `<topic>` | the raw submission: the BEEF as received (bytes, not dag-cbor) | after this overlay **admits** a submission that did not arrive by gossip on `<topic>` (HTTP, a stream), whichever gate admitted it (#73) | `libp2p:<topic>` → `submit`: judged as any submission (#57) |
| `<topic>-admit` | `{txid, topics: {<topic>: {outputsToAdmit: [vout], coinsToRetain: [input index]}}}` — the STEAK and the txid, **no BEEF** | on admission, every time (also for a submission that arrived by gossip) | `libp2p:<topic>-admit` → `peerAdmit`: recorded, never admits |
| `<topic>-proof` | `{txid, blockHash, blockHeight, bump: bytes}` — `bump` the BRC-74 path of this txid alone | on recording a merkle proof for a transaction a topic admitted: its first proof, and again when a reorg re-proves it in another block | `libp2p:<topic>-proof` → `peerProof`: checked, then the proof-in path |

**Publishing.** A message to the libp2p provider, box `publish`, body
`{topic, body}` (docs/MESSAGES.md, "The providers"), emitted from the step
that admits or records the proof and not awaited: the provider's answer is
an entry that runs nothing. With no libp2p provider in the address book (a
host without libp2p) nothing is published. The raw submission is the
request's own body (an HTTP submit's off-chain values framing taken off;
the off-chain values do not travel): the submit entry carries `source:
{transport, topic?, request}` for this. A submission that arrived by gossip
on `<topic>` is not re-published there (GossipSub already forwarded it); a
proof that arrived on `<topic>-proof` is not re-published (the same). A
proof is published only when the step changed the block the transaction's
proof names (the same proof twice publishes once). **Statuses never
propagate**: a status is one node's view of its own broadcast.

**One message per txid, no compound BUMP.** Each proof arrives as its own
event and is recorded in its own step, so `-proof` carries one txid's path,
rebuilt from the held merkle nodes (`Wallet.proofFor`), not a compound BUMP
of the block. Peers that hold several transactions of a block get one
message each; the nodes they share are stored once.

**Receiving `-admit`** (`peerAdmit`): the topic must be one this overlay
serves and the body that shape, else `ignore`. Accept admits a `peer-admit`
event into box `submit`; the engine records it under the head
`overlay:gossip`:

```
{kind: "overlay-gossip", maps: {peerAdmits: <MST root> | null}}
peerAdmits: tp ‖ txid (internal order) ‖ from → {kind: "peer-admit", topic, txid (hex), from: bytes(33) (the publisher's peer key),
                                                 outputsToAdmit, coinsToRetain}
```

A later admit from the same peer for the same transaction replaces the
record. It is a read — for a submitter counting admits, a lookup, a UI —
and **never admits anything**: nothing is admitted from gossip without this
node's own judgement and gate.

**Receiving `-proof`** (`peerProof`): the proof-in wiring of #65 for the
topics this overlay runs — specific wiring, not an open box. In the call
(read only), against this instance's own state: the topic is served; the
transaction is admitted under it, or held pending its gate; it is not
already proven in that block; the BUMP parses, is at `blockHeight` and
flags the txid; our header at `blockHeight` has the hash `blockHash`, and
its merkle root is the BUMP's root. Then accept, admitting the same event
the host's chain feed admits, plus `via`:

```
event (box "chain")  {kind: "proof", subject: <tx CID>, txid, path: <the bump>, blockHash, blockHeight, via: "libp2p:<topic>-proof"}
```

It steps the transaction's pending submission (admitted at the proof, #73),
else the `chain` subscription records it (a reorg's re-proof replaces the
old proof). Anything else is **`ignore`, never `reject`**: a proof we cannot
check may be our missing headers, not the publisher's fault. Only its
request entry is written.

**Late duplicates.** A `<topic>` message GossipSub's seen-cache has
forgotten is the same record as before: the front door finds it in the
`unique` map and answers `ignore` ("already admitted") with nothing run. The
same BEEF in a new message (another publisher) is decoded once, looked up,
and answered `ignore` "already judged" (or "already submitted: awaiting its
broadcast" while pending): no topic manager runs (test.zig counts the
calls). A submission no topic took leaves no record, so it is judged again.

**Config.** `defaults.overlayGossip`, a JSON object in a string: `{"<topic>":
false}` turns a topic's publishing off; a topic not named publishes (the
default is on). It maps 1:1 onto the manifest's `config.overlay.gossip`
(docs/APPS.md §6). Receiving is the routes and the subscribed topics:
`libp2p:<topic>`, `libp2p:<topic>-admit`, `libp2p:<topic>-proof` in
etc/routes.json, and the topics in etc/config.json `libp2p.topics`.

**Not built:** catch-up (asking a peer for its admitted set, or proofs by
block — the pull half of #44–#48).

equiv/overlay.ts checks it end to end on three routers with libp2p: A
(with an Arcade) admits an HTTP submission and publishes `tm_demo` and
`tm_demo-admit`; B (no status provider) judges the gossiped submission and
waits at its gate; A's proof goes out on `tm_demo-proof`, B checks it
against its own headers and admits at it, then publishes its own admit; C
(on `tm_demo-admit` only) records A's and B's admits and admits nothing; a
reorg's re-proof reaches B and replaces the old proof; a bad BUMP is
ignored; the late duplicates are as above. Every store replays exactly.

## A system tree for an overlay node

```
bin/frontdoor.wasm, bin/overlay.wasm, bin/topic-demo.wasm, bin/lookup-demo.wasm   (+ .json: description)
etc/config.json          {"defaults": {"walletNetwork": "regtest", "overlayTopics": "{\"tm_demo\":\"topic-demo\"}",
                          "overlayLookups": "{\"ls_demo\":{\"program\":\"lookup-demo\",\"topics\":[\"tm_demo\"]}}"}}
                          (+ "libp2p": {"topics": ["tm_demo", "tm_demo-proof"]} to take part in the gossip, #74;
                           "overlayGossip": "{\"tm_demo\":false}" in defaults to publish nothing for a topic)
etc/subscriptions.json   [{"box": "submit", "handler": "overlay"}, {"box": "chain", "handler": "overlay"},
                          {"sender": "$status", "box": "status", "handler": "overlay"}]
etc/routes.json          [{"path": "/submit", "program": "overlay", "fn": "submit", "auth": "none"},
                          {"path": "/lookup", "program": "overlay", "fn": "lookup", "auth": "none"},
                          {"path": "/listTopicManagers", "program": "overlay", "fn": "listTopicManagers", "auth": "none"},
                          {"path": "/listLookupServiceProviders", "program": "overlay", "fn": "listLookupServiceProviders", "auth": "none"},
                          {"path": "/getDocumentationForTopicManager", "program": "overlay", "fn": "topicDocumentation", "auth": "none"},
                          {"path": "/getDocumentationForLookupServiceProvider", "program": "overlay", "fn": "lookupDocumentation", "auth": "none"},
                          {"path": "libp2p:tm_demo", "program": "overlay", "fn": "submit"},
                          {"path": "libp2p:tm_demo-admit", "program": "overlay", "fn": "peerAdmit"},
                          {"path": "libp2p:tm_demo-proof", "program": "overlay", "fn": "peerProof"}]
```

The three overlay modules are this repo's `bin/*.wasm`. The front door must
be in `bin/` (a tree's programs are its own): equiv/overlay.ts copies the
kernel's `wasm/frontdoor.wasm`. These routes
replace the stock ones, so this node has no messagebox (add the stock
routes to keep one). The config names no broadcaster (#65: a broadcast is an
event); a host with an Arcade seeds its status provider in the address book,
and `$status` names it here (left out on a host with none); there is no
admission setting (#73).

**The loader change.** For a tree, the boot loader now asks the kernel only
for the `shell` record. `serve`'s `programs` frame takes a list of names.
Before, every pinned record was put, and the ones a tree does not use sat
unreferenced. A replay does not reproduce such records, so this change is
what lets a non-stock tree replay exactly.
