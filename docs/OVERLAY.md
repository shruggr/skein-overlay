# Overlay services in the VM (0.7.7)

An overlay is an app (skein docs/APPS.md §6). It judges transactions with
its topic managers and indexes them with its lookup services; it does not
keep the chain. The chain state — headers, transactions, proofs, spends,
settlement, broadcasts — is global to an instance and has one writer, the
chain app ([shruggr/skein-chain](https://github.com/shruggr/skein-chain),
its docs/CHAIN.md), under `chain/state`. The overlay reads it by CID and
asks the chain app to take a transaction; what the chain app answers
(accepted, proven, rejected) is the overlay's gate.

**A submission is a message** (shruggr/skein#112): `{fn: "submit", args:
{beef, topics}}` into the overlay's submission box `<app>/submit`; `POST
/submit` carries the same message into the same box and answers its
delivery only. The submitter hears the verdict
later, by message to its own box — **admitted** (status `pending`), then
**every proof**, or **rejected** — as Arcade answers a broadcast: nothing
holds a request open ("Submitting", below).

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
lookup service's index), `<app>/topics` (the topics registered at runtime,
"Register a topic", below); its app record is `<app>/app`. Two overlay apps on
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
  The engine's half of catch-up is the want of a paused submission —
  `{event: "want", txid, topic, peer?}` — its clear (`unwant`), and the
  stream a peer answers it on (`/skein/overlay/beef/1.0.0`; "Paused on a
  missing parent", below); asking the peer, or the topic's mesh, is the
  host's (shruggr/skein#112, #126).
- The `historical-tx` modes.
- BRC-64 history queries beyond "spent too" (`includeSpent`).

## Pieces

| where | what |
|---|---|
| `src/engine.zig` → `overlay.wasm` | The engine: called, the front door's route handlers (`routes.zig`); stepped, a submission by message, the submission's thread, a watch, a resume, a peer's admit. |
| `src/submit.zig` | A submission from the wire to the state: the route's half (decode, missing parents, verify, judge oldest first), a submission by message (`received`), the submission's thread (one ingest per item to the chain app; each admitted, in order, on its answer), a pause and its `resume`, the watch, the answers to the submitter. |
| `src/state.zig` | The overlay's state (`<app>/state`) over the chain state (read only): the maps, the previous coins, recording a judgement (`apply`), removing one (`unapply`), `inTopic`, `spender`; a paused submission's `wants` and the step's want / unwant events (`wantEvents`); the parents a BEEF lacks (`missingParents`) and an item's Atomic BEEF cut from a submission's (`atomicFor`); the door's pointer record read (`decodeRecord`, #121) or the one BEEF parse of bytes (`decode`), SPV over the records (`verifyDecoded`; BUMPs only for bytes); the bytes of a BEEF that came as bytes kept as a raw block (`putRaw`), which the `applied` record names; BEEF out for a lookup (`beefFor`, `beefOfMany`). |
| `src/calls.zig` | The configuration as the engine reads it (`configObject`, `listeners`, the app's name) and its calls of topics and lookup services (`Caller`, `hookAdmitted`, `hookRejected`). |
| `src/routes.zig` | The route handlers (#40): the overlay-express wire contract (`/submit` a transport for the submission message: `httpSubmission`), and the gossip's inbound routes (`peerAdmit`, `peerProof`, #74). |
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

The SDK (shruggr/skein-sdk v0.7.1) is a URL+hash dependency in
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

## Submitting (shruggr/skein#112)

A submission is a message into the overlay's submission box, a function
call as any app's (skein docs/APPS.md §4):

```
box:  <app>/submit   (the manifest's row {"address": "submit", "sender": "*", "program": "overlay", "filter": "beef"})
body: {fn: "submit", args: {beef: <the BEEF>, topics: [<topic>, …], offChainValues?: bytes}}
```

**One box per function class** (shruggr/skein#128; 0.7.5 register, 0.7.6
submit, 0.7.7 the registration box named `register`). An overlay app has three boxes, each for one class:

| box | row (stock manifest) | takes |
|---|---|---|
| `<app>/submit` | `{"address": "submit", "sender": "*", "program": "overlay", "filter": "beef"}` | **submissions**: the `submit` message from anyone, and the `submission` event `POST /submit` admits |
| `<app>/register` | `{"address": "register", "sender": "$owner", "program": "overlay"}` | **registration**: `register` / `deregister` from the owner; refused (`bad-args`) in any other box ("Register a topic", below) |
| `<app>` | derived by the install: from `event` and from `$self` | **the engine's own traffic**: the libp2p routes' admits (a gossiped or streamed submission's routed `submit` event, a peer's `peer-admit`), its own `watch` and `resume` |

So an app whose own box `<app>` belongs to another program (skein-amm: its
box is the AMM's) takes submissions — by message and over HTTP — in the
same box, `<app>/submit`, as this repo's does. The engine still takes a
`submit` in any box a row routes to it, from whoever that row admits; the
answer goes back in the box the message came in. Before 0.7.6 the stock
manifest's submission row was `""` (the app's own box) and `POST /submit`
admitted into `<app>`.

The door decodes `args.beef` into its pointer record (`filter: "beef"`,
shruggr/skein#121). Delivery is the only acknowledgement: nothing answers
until there is a verdict, and no request stays open. The engine routes the
submission in its step on the message (`submit.received`, the same route's
half as below): whole, it launches the submission's thread; lacking a
parent, it pauses — internally: the submitter hears nothing of the pause or
the parents; refused (a BEEF that does not decode or verify), taken by no
topic, or for no topic served here, it answers `rejected` at once.

**POST /submit is a transport for the same message.** The route checks only
that the request is a submission (`X-Topics`, a body, the off-chain
framing; else 400), builds the message `{fn: "submit", args: {beef, topics,
offChainValues?}}` and answers **200 `{id}`**, the request record's CID
(hex): the `request` every answer names, with `admit: [{event, box:
<app>/submit}]` — the event `{kind: "submission", body: <the message>,
request: <the request record>, transport: "http", sender?: <the BRC-104
session's identity>}`, routed into the submission box like a delivered
message (the manifest's row `submit`, sender `*`, which takes events too;
0.7.6 — before, the app's own box `<app>`). The skein install's derived http
row `/<app>/submit` is unchanged: only where its handler admits moved. The route launches nothing (0.7.3: a step that launches a
thread waits on it, so the request would not end): the request ends at
once, and the engine's step on the event is the message step's — the same
route's half, the same thread. No
STEAK, no 503, no 400 for a verdict. **BRC-22's synchronous STEAK is no
longer answered on `/submit`.** A client that wants the verdict submits by
message from its own identity (its messagebox in the instance's reach), or
over a BRC-104 session to `/submit` (the session's identity is the
sender), and reads the answers in its box; a client on the open route (no
session, the @bsv/sdk `TopicBroadcaster`'s way) gets delivery only, its
answers in the instance's log, and reads the outcome with a lookup.

**The answers** go to the sender, in the box it wrote to (`/submit`: the
submission box `<app>/submit`), when a message can reach it (the instance itself, an
address-book entry); otherwise they are in the step's result record only
(`answers: [{to, box, body | message, sent}]`). Each is

```
{fn: "submit", request: <the message's (or request record's) CID>, replyTo: <the same>, result}
{fn: "submit", request, replyTo, error: {code: "bad-args", message}}     a body not that shape
```

| result | when |
|---|---|
| `{txid, state: "admitted", status: "pending", steak: {<topic>: {outputsToAdmit, coinsToRetain, coinsRemoved}}}` | the chain app's `accepted` answer for the subject (its broadcast succeeded): admitted under each topic, the STEAK per topic |
| `{txid, state: "admitted", status: "proven", steak}`, then a proof | admitted at its proof (no status provider, or proven before accepted) |
| `{txid, state: "proven", block: <the header's CID>, height}` | **every proof** of the transaction the overlay hears: the chain app's `proven` answer, relayed; a reorg's proof is another, a different block |
| `{txid?, state: "rejected", reason}` | the chain app's `rejected` (a status, a competing proof, a rejected input) or its error answer to the ingest; a BEEF refused (no `txid` when it did not decode); `NotAdmitted: …` when no topic took the subject |
| `admitted` (and its proof if proven), from the state | a resubmission every requested topic judged before |

A submission's answers are about its subject. A subject no topic takes
(only transactions before it in the BEEF, or one only wanted by a paused
submission) is answered `rejected`, `NotAdmitted`, at once; the
transactions before it go on as items (below). A resubmission while the
first is with the chain app is not answered (open, below). Gossip and
want-answer submissions (libp2p) have no submitter: nothing is answered.

**The proofs and a reorg.** The chain app answers an ingest's caller on
each state change until the transaction is proven or rejected
(shruggr/skein-chain docs/CHAIN.md, "Its interface"). Admitted with a
submitter to answer, the subject gets a watch (below) whatever admitted
it; each `proven` it hears is relayed, and it hands over to a new watch
(`proven: true`) that awaits the next. A reorg that replaces the block a
proof names turns the transaction back to unproven in the chain app, which
registers its broadcast again and answers its proof again when it comes —
relayed as another `proven`, a different block. (The chain app as built
re-registers a reorged transaction's broadcast with no watchers, so that
second answer reaches no one yet: shruggr/skein-chain, "Where it is going",
a registration for the life of the transaction.)

## A submission, from the wire to the state (#50)

**Decoded at the door** (shruggr/skein#121). The submit rows (`/<app>/submit`,
the submission box `<app>/submit`, and the libp2p `<topic>`) name `filter: "beef"`. Before the request's
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

**Missing parents pause** (skein-overlay#1). Before SPV, the route lists
the parents the BEEF lacks (`state.missingParents`): for every transaction
its BUMPs do not prove, each input's source that is neither a transaction
before it in the BEEF nor held by the chain app, and each txid-only entry
the chain app does not hold. Any → the submission **pauses** (below,
"Paused on a missing parent"), however it came: a message, `/submit`, a
`<topic>` message, a frame on the want-answer stream. "There never is a
missing parent; the status is pending." Nothing is judged.

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

**Judge in the step, oldest first** (skein-overlay#1). The handler walks
the BEEF's transactions in order, up to and including the subject. Each one
that is not pending in a submission of its own is judged by each requested
topic this overlay serves that has not judged it before (its `applied`
record): the topic's program (fn `identify`, below) is called with the
transaction's CID and its previous coins. The topic reads the transaction
and its inputs' sources through the same cache. The previous coins of a
transaction in the walk are the inputs spending an output live in the topic
**or an output the same topic took earlier in the walk**
(`State.previousCoinsWith`): those are not admitted yet — nothing is until
the chain app answers — but will be before this one is (below). Off-chain
values go with the subject's call only.

Every transaction a topic takes is an **item** of the submission, and so is
one a paused submission wants (`wants`, below), taken or not, so that the
chain app holds it.

**Nothing moves until admitted.** If there is no item (no topic takes
anything in the walk — no output admitted and no previous coin consumed —
or every such topic's program fails, and no transaction is wanted), or the
subject is one the chain app rejected, the submission is answered
`rejected` (the reasons in `reason`) and starts nothing: no head moves. So
is a BEEF that does not decode or verify. A resubmission of a transaction
every served topic judged before (a dupe) is answered `admitted` from the
state at once; one of a transaction pending (below) is not answered.

**The submission's thread.** Otherwise the submission's step launches the
submission's thread — the engine on the submit event (args `{event, box:
"submit"}`). (A gossiped submission admits the same event into the app's
box `<app>` instead, and the app's row from `event` starts the same engine;
its verdict goes back at once.)

```
{kind: "submit", txid (hex: the subject), beef: <the pointer record's CID> | bytes (the BEEF as received, off-chain framing taken off),
 topics: [{topic, previousCoins, outputsToAdmit, coinsToRetain}],     the subject's judgements ([] when no topic took it)
 earlier?: [{txid (hex), topics: [{topic, previousCoins, outputsToAdmit, coinsToRetain}]}],
                                       the items before the subject, oldest first (topics [] for one only wanted)
 wanted?: true,                        no topic took the subject, but a paused submission wants it: it is an item all the same
 offChainValues?: bytes,
 source?: {transport: "mailbox" | "http" | "libp2p", topic?, protocol?, from?, box?, sender?, request}}
                                       where it came from; `sender` and `box`: whom its answers go to
```

The items are `earlier`, then the subject when a topic took it (or it is
`wanted`).

1. **To the chain app, one ingest per item.** Its first step sends the
   instance itself (skein #79: a message to the instance's own key is looped
   back, from the instance) the chain app's ingest, box `chain`, for each
   item, oldest first:

   ```
   {fn: "ingest", args: {beef}}     the subject's: the pointer record's CID (#121), or the bytes, as handed;
                                    an earlier item's: its Atomic BEEF cut from the submission's (`state.atomicFor`:
                                    it and its ancestors in that BEEF back to the ones its BUMPs prove, those BUMPs) — bytes
   ```

   notes each item `pending` (`<app>/state` map `pending`: `{kind:
   "submission", txid, submission: <the subject, hex>, thread, ingest: <its
   message>}`) and rests awaiting those messages' answers. The chain app
   records each BEEF (SPV against its headers), and — unproven — registers
   its broadcast and broadcasts it: the overlay never broadcasts. Each item
   is a watcher of its own transaction, so the chain app answers for each.
2. **The gate is the chain app's answer, per item** (#73). Each answer is
   `{fn, request, replyTo: <an ingest message>, result: {txid, tx, state,
   …}}` (or `{…, error}`), the input `reply`; it is about the item whose
   ingest it names:
   - `accepted` (a status provider's first word that is not a rejection) or
     `proven` (its proof, validated by the chain app against its headers) —
     noted on the item's pending record (`heard`; a later `proven` replaces
     `accepted`);
   - `rejected` (a status provider's rejection, a competing proof,
     abandonment, a rejected input) — the item resolved, nothing admitted;
   - an error answer (the chain app refused the ingest) — the item resolved,
     nothing admitted;
   - anything else — nothing.

   Then, oldest first, each item whose answer admits it is **admitted**, up
   to the first item still unanswered: an item is never admitted before the
   ones before it in the BEEF are resolved, so its previous coins are the
   ones it was judged with. Admitting one: each judgement recorded (`apply`:
   the admittances and the `applied` record, naming the submission's BEEF;
   the previous coins are taken again and, if they moved since the call, the
   topic is asked again), then each listening lookup service's hooks
   (`admitted`, then `spent` for each previous coin consumed), then the
   gossip out (`<topic>-admit` for every item; the raw submission on
   `<topic>` with the subject's). An item only wanted records nothing. The
   subject's admission is answered to the submitter (`admitted`, above);
   its rejection or an error answer, `rejected`.
   Each item admitted or rejected **resumes** the paused submissions waiting
   on it (below).

   With no status provider, no status ever accepts an item: it is admitted
   at its proof. Admission on validation alone is not a mode.
3. **It finishes** when none of its items is pending, admitted or not. For
   each item admitted on `accepted` (not yet proven), and for the subject
   admitted with a submitter to answer, it sends the app itself a
   **watch**, box `<app>`:

   ```
   {fn: "watch", args: {txid (hex), ingest: <that item's ingest message>,
                        source?: <the submission's source: the submitter>, proven?: true (a proof was relayed)}}
   ```

**The watch.** The app's row from `$self` steps the engine on it. It reads
the chain state first — what the chain app said in between: proven →
`<topic>-proof` published and the proof relayed, done; rejected → unwound
and answered, done — and otherwise awaits the same ingest message (any
thread awaiting a message the instance sent gets its answers): `proven`
publishes `<topic>-proof` (unless the proof came by gossip: `via`; and once
per transaction: not from a watch with `proven`) and is relayed to the
submitter; `rejected` **unwinds** — each served topic's judgement of the
transaction removed (`State.unapply`: its `applied` record and its
admittances) and each listening lookup service told (`rejected`) — and is
answered `rejected`; then it finishes. With a submitter, a proof heard
hands over to a new watch (`proven: true`), which at its start relays
nothing already relayed and awaits the next proof (a reorg's). No
deadline: abandonment is the chain app's, and reaches the watch as a
`rejected` answer.

### Paused on a missing parent (skein-overlay#1)

A submission whose BEEF lacks a parent (above, "Missing parents pause") is
not judged and goes nowhere yet. **Which inputs pause it: every input** of
every transaction its BUMPs do not prove. Not only the inputs spending an
output live in a topic: such an output is always held (it was admitted on
the chain app's answer), so that rule would never pause; and an input whose
source is missing cannot have its script verified, and the chain app's
ingest refuses the BEEF (`MissingInput`) — no topic could judge it either.

**Every submission lacking a parent pauses** (shruggr/skein#112, 0.7.2):
from a peer, from a message, over HTTP. The pause is internal: the
submitter hears nothing until the verdict.

From a peer, the route answers accept, admitting the paused event into box
`<app>`; by message or HTTP, the submission's step pauses it itself —

```
{kind: "submit", txid (hex), beef, topics: [], requested: [<topic>, …] (the topics requested this overlay serves),
 waiting: [<txid hex>, …] (the parents, in BEEF order), offChainValues?,
 source: {transport: "libp2p", topic? | protocol?, from: <the peer ID's multihash>, request}
       | {transport: "mailbox" | "http", box, sender?, request}}
```

— a step that notes it pending, records its wants, emits the `want` events
and finishes:

- the pending record of the subject: `{kind: "submission", txid,
  submission, thread, waiting: [<txid hex>, …], event: <the paused event>}`
  (no `ingest`);
- **the wants**: one per (parent, topic requested, peer?), the map `wants`:
  `<parent txid> ‖ tp ‖ <peer>? → [<subject txid>, …]` (the paused
  submissions that wait on that parent and that the peer announced, or
  announced something needing). The peers: the event's `from` (the
  publisher of the gossip message, or the stream's remote peer); **every
  peer whose `-admit` for the subject was seen** (`<app>/gossip`, the
  peer-admit record's `peer`), and more as admits arrive (the `peer-admit`
  step adds that peer's wants to a pause that requested the admit's topic);
  every peer its wants stood against already (an earlier announcement of
  the same subject; a resume); and every peer its own subject is wanted
  from — the peers that announced something needing it, so a parent's
  parent is asked of those that announced the top-level submission too.
  **No peer** — a submission by message or HTTP, or one whose wants had a
  want with no peer — adds the want with no peer: the host asks peers from
  its mesh for the topic. A later submission of the same subject from
  another peer adds that peer's wants; from a peer whose wants stand
  already it is `ignore`.
- **the events**: the step's want journal (`State.wantEvents`): for each
  want it touched, one event if it stands now and did not before, and one
  if it stood and does not now (skein docs/VM.md "emit", open events,
  recorded once in the step's `emitted`):

  ```
  {event: "want",   txid: <hex>, topic, peer?: <bytes: the libp2p peer ID's multihash, as a gossip message's `from`>}
  {event: "unwant", txid: <hex>, topic, peer?}        the same want, ended
  ```

  The kernel records each as `{kind: "event", event, app, txid, topic,
  peer?}`. With a peer, the host asks that peer for the BEEF of `txid` on a
  direct stream; without one, the topic is the context and the host asks
  peers from its mesh for that topic (shruggr/skein#112). The skein's part
  ends at the want: the host reads the standing wants (folded from the log,
  `want` minus `unwant`, as subscriptions are) and the answers, and
  delivers once; the answer lands in the overlay's stream row (below).
  **`unwant`** is the builder's smallest option (David to review): the
  engine emits it in the step that ends the want — the parent's admission
  or rejection, which sends the resume, or the resume or submission that
  drops or replaces the pause — so the log alone says whether a want is
  resolved.

**The answer on the stream.** A peer answering a want opens a stream to
this instance on **`/skein/overlay/beef/1.0.0`** (the manifest's row
`{"transport": "libp2p", "address": "/skein/overlay/beef/1.0.0", "sender":
"*", "program": "overlay", "fn": "submit", "filter": "beef"}`) and sends one
Atomic BEEF per frame, the wanted txid its subject; "The wire", below. The
door decodes it (`filter: "beef"`) and `submit` routes it as a submission
from that peer, with the topics the paused submissions waiting on its
subject requested (`submit.wantedTopics`); a BEEF no one here wants is
`ignore`. It is an item even if no topic takes it (below), and it may
itself pause and want.

**Resumed.** A submission whose BEEF carries a wanted parent makes it an
item (above), ingested even if no topic takes it. When the chain app
answers for it (admitted, or rejected) the thread removes **every want for
that parent** (whatever the topic and peer; an `unwant` each) and sends the
app itself, box `<app>`, for each paused submission waiting on it:

```
{fn: "resume", args: {txid: <the paused subject, hex>}}
```

The engine (row from `$self`) routes the paused submission again — its
BEEF, the topics requested, its off-chain values, its source — as the route
does. **All its wants clear.** Whole now, it **launches** the submission's
thread on the new event (args `{event, box: "submit"}`, as `/submit` does)
and drops the pause; still missing a parent, it pauses again, its wants
recorded again for what is still missing against every peer that announced
it or something needing it by then (a `want` event only for a want new in
the step, an `unwant` for one that no longer stands); routed to nothing
(refused, taken by no topic, judged before), the pause is dropped and its
submitter answered (`rejected`, or `admitted` for one judged before). A
`resume` for a submission no longer paused does nothing. A submission of
the subject that is whole (by message or HTTP too) replaces the pause and
clears its wants.

**Not resumed: a parent fed to the chain app's ingest directly.** The
engine learns of an arriving parent only through a submission to this
overlay (`/submit`, the `<topic>` gossip, the want-answer stream). A BEEF
the host feeds to the chain app's `ingest` itself reaches no overlay
thread: the chain app answers only the callers of an ingest, about the
transactions it ingests, and has no registration for a transaction it does
not hold yet — and the kernel's `await` refuses a CID not in the store.

**Next (not built).** The decided direction of shruggr/skein#31 ("Decided
2026-10-02 (night)"): the one-shot watch becomes a registration for the life
of the transaction, there is no unwind as an action (whether an admission
counts is a read of the chain state), and a judgement is re-run when the
chain state it depended on changes.

**Open (David to review).** A resubmission of a transaction already with
the chain app (pending in another submission) is not answered: the first
submission's thread answers only its own submitter.

## The state: `<app>/state`

```
{kind: "overlay-state", maps: {admitted, applied, pending, wants}}
```

`tp` is len ‖ topic. The outpoint is txid (internal order) ‖ vout (u32 BE).

| map | key → value | |
|---|---|---|
| `admitted` | tp ‖ outpoint → admittance record | an output a topic admitted |
| `applied` | tp ‖ txid → applied record | the topic's judgement of this transaction: a later submission is a dupe; which previous coins it retained |
| `pending` | txid → submission record | a submission's transaction handed to the chain app, not yet admitted (or rejected); or a paused submission (skein-overlay#1) |
| `wants` | parent txid ‖ tp ‖ peer? → [subject txid] | a want: a parent paused submissions wait on, wanted under that topic, to be asked of that peer — or, with no peer, of the topic's mesh (skein-overlay#1, shruggr/skein#112) |

**Records.**

- **Admittance:** `{kind: "admitted", topic, txid, vout, script, satoshis,
  admittedAt, tx: <tx CID>, refs: [{to: <tx CID>, rel: "admits"}]}`.
- **Applied:** `{kind: "applied", topic, txid, outputsToAdmit,
  coinsToRetain, coinsRemoved, at, tx, beef, refs}`. `beef` is the
  submission's BEEF as the overlay was handed it: the pointer record the
  kernel's door wrote (shruggr/skein#121), or, for a BEEF that came as
  bytes (framed with off-chain values, or a host with no door), the raw
  block of those bytes. It is kept for internalizing the transaction as
  handed over; a lookup does not serve it (below).
- **Submission:** `{kind: "submission", txid, submission, thread?, ingest,
  heard?, via?}` for a transaction of a submission handed to the chain app
  (`submission` the subject, hex — the transaction itself, or a later one of
  the same BEEF; `heard` the admitting answer heard while an item before it
  is unanswered, `via` a proof's); `{kind: "submission", txid, submission,
  thread?, waiting: [txid hex], event}` for a paused one (skein-overlay#1).
  A record without `submission` (before 0.7.0) is its own.

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
| a message in box `<app>/submit` from anyone (the manifest's row `submit`, sender `*`), or the `submission` event POST /submit admits there (0.7.3; that box 0.7.6) | `{fn: "submit", args: {beef, topics, offChainValues?}}`, or `{kind: "submission", body: <that message>, request, transport: "http", sender?}` | a submission (shruggr/skein#112): routed — its thread launched, paused, or answered (`rejected`, or `admitted` for one judged before); the step's wake at the end of the thread it launched (`resolved`) answers nothing (0.7.4: the submitter is answered once per state change) |
| a submission's launch, or the submit event in box `<app>` (the `libp2p:<topic>` route's admit, row from `event`) | `{kind: "submit", …}` | the submission's thread: the ingest message, pending; on each answer (`reply`) admit, reject or await on; the submitter answered |
| a message in box `<app>` from the instance itself (row from `$self`) | `{fn: "watch", args: {txid, ingest}}` | the watch: the later proof (`-proof`) or rejection (unwound) |
| a message in box `<app>` from the instance itself (row from `$self`) | `{fn: "resume", args: {txid}}` | a paused submission routed again (skein-overlay#1): its thread launched, paused again, or dropped; its wake at that thread's end, nothing |
| the `peer-admit` event in box `<app>` (the `-admit` route's admit) | `{kind: "peer-admit", …}` | recorded under `<app>/gossip` ("Gossip", below); nothing admitted; a pause of that transaction wants its parents from that peer too |
| a message in box `register`, i.e. `<app>/register` (the manifest's row, from `$owner`; 0.7.7) | `{fn: "register", args: {topic, program}}` or `{fn: "deregister", args: {topic}}` | the registered set under `<app>/topics` and its events ("Register a topic", below); in any other box, refused (`bad-args`) |

One box per function class (shruggr/skein#128, 0.7.5, 0.7.6, 0.7.7): submissions in `<app>/submit` (by message and over HTTP; the engine takes a `submit` in any box a row routes to it, from anyone that row admits), registration in `<app>/register`, the engine's own traffic in `<app>`; `register` / `deregister` only in `<app>/register`, and refused with `bad-args` in every other box, whoever sent them (the instance itself too); any other message from anyone but the instance itself is refused; from the instance itself, only `watch` and `resume`. There is no `lookup`
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
  role in `programs`: the topics declared at install. It may be empty or
  absent (a dynamic overlay); the topics registered at runtime are served
  beside them ("Register a topic", below).
- `config.overlay.lookups = {"ls_demo": {"program": "lookup-demo",
  "topics": ["tm_demo"]}}` maps each lookup service to a role and the
  topics it listens to. Without `topics` — `{"ls_demo": {"program":
  "lookup-demo"}}`, or the short form `{"ls_demo": "lookup-demo"}` — it
  listens to every topic the overlay serves, declared or registered: a
  dynamic overlay's lookup service needs no topic list.
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
`/<app>/`); and the mailbox rows `<app>` from `event` (the libp2p routes'
admitted events) and from `$self` (its own watch and resume) — all to the
role `overlay`. The manifest lists the submission box `submit` (open), the
registration box `register` (`$owner`), the listing and documentation
routes, and `requires: ["chain/1"]`: the chain app must be installed.
`POST /submit`'s submission event goes to `<app>/submit` (0.7.6), not
through the derived `<app>` rows.

### Register a topic (shruggr/skein#120)

Registering a topic is one call: register this topic, deregister this
topic. A dynamic overlay — one topic per token, `tm_<txid>`, the topics
the operator chooses to run (Mandala, the AMM) — declares no topics in
its manifest and registers each at runtime. An overlay may still
pre-configure topics in `config.overlay.topics` (OpNS: one global topic,
nothing to choose); both kinds are served alike. There are no topic
prefixes anywhere: not in the configuration, not in the rows.

The engine's two functions, a message `{fn, args}` (skein docs/APPS.md §4)
the owner sends to the app's `register` box — installed, `<app>/register`: a
manifest's mailbox address is relative to the app, like its http paths and
heads (shruggr/skein#128). One box per function class (#128, 0.7.5): the
engine takes them only in that box, the one the manifest names `register`;
in any other box a row routes to it — the app's own `<app>`, the submission
box `<app>/submit` — they are refused, whoever sent them, with `error:
{code: "bad-args", message: "register: not taken in box <box>; send it in
<app>/register"}`, writing and emitting nothing. The app is the step's,
never the box's:

- `register {topic, program}` adds `topic` to the registered set, judged by
  the topic manager `program` (a role in `programs`: the manifest of a
  dynamic overlay lists no topic, so the call names it; an unknown role is
  refused);
- `deregister {topic}` removes it.

Both are idempotent: a topic registered already with the same program, or
not registered, changes nothing and emits nothing. A topic registered with
another program is refused (deregister it first). The answer is `{topic,
active}`, `active` whether the topic is in the registered set now, sent to
the sender, in the box the message came in, as `{fn, request, replyTo, result}` (or `error: {code:
"bad-args", message}` for a refusal, which writes nothing) when a message
can reach it (the instance itself, or an address-book entry); the step's
result record says the same.

Who may call them is the embedding app's manifest: a row for a box of its
own to the engine, for the sender it chooses; this repo's manifest has the
owner's:

```json
{"address": "register", "sender": "$owner", "program": "overlay"}
```

The install resolves the address to `<app>/register`; the engine takes
registrations in that resolved box only (`src/topics.zig` `mayRegister`).

The function is the body's `fn`: a mailbox row's own `fn` is not handed to
the program (the kernel launches the row's program on the message), and
one row per sender takes both functions. Another program of the same app
reaches them through the instance's own row (`$self`), which the install
derives.

**The set** is the engine's own head, `<app>/topics`:

```
{kind: "overlay-topics", topics: [{topic, program}, …]}     sorted by topic, each once
```

read at every step and call with `config.overlay` (`src/config.zig`): each
registered topic is served as if `config.overlay.topics` named it, judged
by its `program` (a declared topic keeps its own). Submit, lookup listening,
the listings, gossip publishing and the three gossip routes all see the one
set.

**The events** (skein docs/MESSAGES.md "Topics an app asks for", #119),
emitted when the set changes:

| call | events |
|---|---|
| `register` | `{event: "subscribe", topic: "<topic>", program: <engine's role>, fn: "submit", filter: "beef"}`, the same without `filter` for `<topic>-admit` with `fn: "peerAdmit"` and for `<topic>-proof` with `fn: "peerProof"` |
| `deregister` | `{event: "unsubscribe", topic}` for `<topic>`, `<topic>-admit`, `<topic>-proof` |

`program` is the engine's own role in `programs` (`overlay` in this repo's
manifest) and `fn` its function for that topic: the handler the host routes
the topic's messages to (the kernel records the event as `{kind: "event",
event, app, topic, program, fn, filter?}`). `filter: "beef"` on `<topic>`
only: its body is the submission's BEEF, which the kernel's door decodes
into its pointer record as for the `/submit` row (skein #121), so `submit`
takes it the same way whether a row or the subscription routed it;
`-admit` and `-proof` bodies are dag-cbor, handed over as received. The install derives no rows for a
registered topic: the host subscribes it and routes its messages by these
events. A message arriving on a registered topic is handled as on a
declared one: the routes take the topic from the message and look it up in
the served set (`<topic>` → `submit`, `<topic>-admit` → `peerAdmit`,
`<topic>-proof` → `peerProof`).

**Result.** Each step keeps a result record and prints its CID:

- `{kind: "overlay-result", op: "submit" | "answer" | "watch" | "watched",
  txid, ingest?, ingests? (op submit: one per item), waiting?, wanted? (the
  parents; how many `want` / `unwant` events), heard?, admitted?,
  steak?: {topic: {outputsToAdmit, coinsToRetain, coinsRemoved}} (the last
  transaction admitted), admissions?: [{txid, steak}] (more than one
  admitted in the step), unapplied?: [topic], watch?, resumes?, published?,
  awaiting?, answers?, refs (mentions), state}`;
- `{kind: "overlay-result", op: "received" | "resume", txid? (resume),
  outcome: "none" | "paused" | "launched" | "dropped", waiting?, wanted?,
  event?, launched?, why?, answers?, state}`;
- `{kind: "overlay-result", op: "peer-admit", topic, txid, record, wanted?, state}`;
- `answers`: the answers to submitters the step made, `[{to, box, message
  (sent) | body (no message reaches `to`: the log only), sent}]`;
- `{kind: "overlay-result", op: "register" | "deregister", topic, active,
  changed, topics?}` (`topics`: the set's new record), or `{op, error}`
  for a refusal;
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

**BEEF out for a lookup** (skein-overlay#3): a lookup returns, for one
transaction, the BEEF that proves it exists on chain — its merkle path if
it is proven, else its parents handled the same way, back to proven ones.
That is the chain state's `chain.state.State.beefOf` (skein-sdk), read
only; each `beef` is that Atomic BEEF of the output's transaction. Any BEEF
handed out is built this way; anything else is not a valid BEEF. That is
the least a BEEF carries: one may carry more transactions when there is a
reason (a proof packet for a token's history, say), each built by the same
rule. Token provenance is the topic manager's, judged at submission; history across
overlays is GASP's (not built). The submission as handed over (the
`applied` record's `beef`) is not what a lookup serves.


The query is the client's JSON as dag-cbor; integers only.

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
| `POST /submit` | `submit` | body BEEF (`application/octet-stream`); `X-Topics` a comma list (the SDK's form) or a JSON array; `x-includes-off-chain-values: true` → VarInt(len) ‖ BEEF ‖ values | **200 `{id}`**: delivered — the request record's CID (hex), which the answers name as `request`; 400 `{status: "error", message}` only when it is not a submission (no `X-Topics`, no body, bad framing). The verdict is a message to the submitter ("Submitting", above) |
| `POST /lookup` | `lookup` | `{service, query}` JSON; `X-Aggregation: yes` | `{type: "output-list", outputs: [{beef: [bytes], outputIndex, context?}]}`, or the compact octet-stream (count, per output txid ‖ index ‖ context, then one BEEF of them all, `state.beefOfMany`); a freeform answer as `{type, result}` |
| `GET /listTopicManagers`, `/listLookupServiceProviders` | `listTopicManagers`, `listLookupServiceProviders` | | `{name: {name, shortDescription, iconURL?, version?, informationURL?}}`: each configured topic's or service's fn `metadata` |
| `GET /getDocumentationForTopicManager?manager=`, `/getDocumentationForLookupServiceProvider?lookupService=` | `topicDocumentation`, `lookupDocumentation` | | `text/markdown`: its fn `documentation`; 400 if not configured |

**A submit is the one write**, and only when a topic takes the transaction
(above). Over HTTP it is the submission message on another transport: the
route admits `{fn: "submit", args}` into the submission box `<app>/submit`
as the `submission` event (above; 0.7.6), and answers its delivery. **BRC-22's synchronous STEAK is not
answered on `/submit`** (shruggr/skein#112): a client takes the verdict from its box (a message, or `/submit` over a BRC-104
session), or reads what was admitted with a lookup.

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
instance's missing headers rather than the publisher's fault. A BEEF lacking
parents is accepted and pauses, wanted from the message's `from` (above).

**The want-answer stream** (skein-overlay#1, shruggr/skein#112). The libp2p
row `/skein/overlay/beef/1.0.0` (a direct-stream protocol, sender `*`,
`filter: "beef"`) names the same fn. A peer answering a want dials it and
writes **one Atomic BEEF per frame** (length-prefixed, as every skein
stream frame), the wanted txid its subject; it may send several on one
stream. Each frame is a request (`{kind: "p2p-frame", protocol, from,
body}`, skein docs/MESSAGES.md "libp2p", "Streams": not signed; Noise
authenticates the stream, `from` is the remote peer); the door decodes the
BEEF into its pointer record, and the handler routes it as a submission
from `from`, with the topics its waiters requested. The answer is the
route's verdict, as for a topic message: **accept** admitting the submit
event into box `<app>`, or **ignore** (not wanted here, nothing new,
refused). It writes **no reply frame** (no `body`) and does not close the
stream; nothing else answers the sender. An admission from the stream
publishes its `-admit` verdict but not the BEEF on `<topic>` (its holders
published it long since).

**A lookup writes nothing.** The handler calls the service's program and
shapes its answer for the wire. Listings and documentation call the
programs too (fn `metadata`, fn `documentation`) and read no file; a call
that fails answers 500.

**The STEAK.** It is the `steak` of an `admitted` answer, per topic, with
exactly the three fields the @bsv/sdk client accepts (`outputsToAdmit`,
`coinsToRetain`, `coinsRemoved`).

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
and not awaited. The libp2p provider is the address book's entry at
(`local`, `libp2p`) (skein-sdk `peerAt`; the address book has no roles,
shruggr/skein#126); with none, nothing is published. The raw submission is the submit event's `beef` (the off-chain
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
                                                 peer?: bytes (its peer ID's multihash, the message's `from`: 0.7.2),
                                                 outputsToAdmit, coinsToRetain}
```

A later admit from the same peer for the same transaction replaces the
record. It is a read and **never admits anything**; a submission of that
transaction paused here wants its parents from `peer` too (shruggr/skein#112).

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
