# PoRep Market V2 Starting Spec

Status: draft for PR review.

This folder is the repo review surface for the V2 starting shape. The goal is to
make the contract split commentable without turning the spec into a full
implementation plan.

## Files

| File | Purpose |
| --- | --- |
| `porep-v2-overview.md` | short client/SP view |
| `porep-v2-shared-types.sol` | request, selection, SLI, activation, settlement, and rail-status vocabulary |
| `porep-v2-market-interface.sol` | market settlement interface used by Validator |
| `porep-v2-storage-evidence-adapter.sol` | adapter interface for DataCap-backed evidence and later evidence sources |
| `porep-v2-datacap-evidence-adapter.sol` | DataCap / VerifReg adapter sketch |
| `porep-v2-spregistry-storage.sol` | living provider, offer, token, and capacity storage |
| `porep-v2-market-storage.sol` | frozen deal snapshot and lifecycle storage |
| `porep-v2-validator-storage.sol` | per-deal rail identity and settlement guard storage |
| `porep-v2-architecture-diagrams.md` | storage layout, offer freeze, and lifecycle/payment diagrams |
| `porep-v2-storage-layout.excalidraw` | editable storage-layout diagram source |
| `porep-v2-propositions.md` | proposed shape and review points |
| `porep-v2-datacap-sunset.md` | DataCap removal transition plan and on-chain evidence requirements |

## Starting Point

V2 starts from:

- provider-owned offers
- SP-defined offer names for client/UI discovery
- multiple payment tokens per offer
- provider-level shared capacity
- frozen deal snapshots
- deal-keyed storage evidence
- token-bound FilecoinPay rails
- auto-match and direct offer selection over the same storage model

## Contract Split

`SPRegistry` owns living provider configuration. Providers can change offers,
payment rows, and availability for future proposals.

`PoRepMarket` owns deals and activation. A deal freezes the selected offer
terms, payment token, payee, duration, capacity, piece-set commitment, evidence
adapter, and SLI terms. Later offer/provider edits do not change existing deals.

Storage-evidence adapters own the checks and IDs for their evidence type.
DataCap / VerifReg is one adapter, not market architecture. The market stores
the selected adapter and activation fields: deal state, committed bytes, billed
units, service start/end, and rail ceiling. It does not store allocation IDs,
claim IDs, or raw evidence rows.

PoRepMarket is the adapter caller. External actors submit activation evidence to
PoRepMarket; PoRepMarket calls the selected adapter, validates the adapter
result against the frozen deal, stores committed bytes / billed units / service
start / service end / rail ceiling, and moves the deal to `DealState.ACTIVE`.

`Validator` owns rail identity and settlement guard state. It reads frozen
deal/payment data from `PoRepMarket`; a write-once cache is only a later gas
optimization.

## Release Boundary

V2 starts as fresh canonical contracts. Existing V1 deals are not migrated into
V2 state in the starting scope; they continue on the V1 path until closed or
terminated.

Any optional import or migration tooling is a later release-plan item and must
not constrain the V2 storage shape unless explicitly accepted as a product
requirement.

## Contract Deployment Index

| Surface | V2 deployment status | Why |
| --- | --- | --- |
| `PoRepMarket` | deploy fresh V2 contract | Owns frozen deals, activation, service timing, and settlement interface. |
| `SPRegistry` | deploy fresh V2 contract | Owns living provider registration, offers, token rows, and shared capacity. |
| `Validator` | deploy fresh V2 implementation behind a new V2 beacon | Owns FilecoinPay rail identity and settlement guard state; reads deal/payment truth from PoRepMarket. |
| `ValidatorFactory` | deploy fresh V2 factory and beacon | Creates V2 validator instances and records valid validator contracts. |
| V1 `Client` | do not deploy as V2 `Client` | The V1 deal-completion authority is removed. Its useful DataCap guardrail responsibility moves into `DataCapEvidenceAdapter`. |
| `DataCapEvidenceAdapter` | deploy for DataCap-backed pilot | Evidence adapter and guarded DataCap gateway for DataCap-backed deals. Owns allocation/claim IDs, DataCap posting, and VerifReg claim checks. |
| `SLIOracle` | optional pilot deployment | Strict SLI slashing is deferred; keep it only if pilot tooling needs oracle attestations. |
| `SLIScorer` | optional pilot deployment | Strict payment-affecting scoring is deferred; keep only if pilot settlement needs it. |
| `IStorageEvidenceAdapter` | not deployed | Interface used by PoRepMarket for DataCap-backed and later evidence adapters. |
| `MetaAllocator` | external dependency | Existing Filecoin Plus / DataCap allowance path. |
| `FilecoinPay` | external dependency | Existing payment rail system. |

This index is deployment-oriented. Libraries, storage-layout sketches, shared
types, and interfaces can be source artifacts without becoming standalone
deployments.

V2 must not upgrade the live V1 `PoRepMarket`, V1 `Client`, V1
`ValidatorFactory`, V1 `ValidatorBeacon`, or existing V1 Validator proxies. Any
in-place upgrade or migration would need a separate storage-layout and migration
proof.

## External Interface Shape

The external API stays small.

- command functions show how deals/offers move
- read functions return composed views (`DealView`, `OfferView`, `ProviderView`)
- storage mappings stay inside storage sketches
- full event/error/pagination design is not part of this starting pass

## State Codes

V2 must not use Solidity `enum` for stored or externally visible state.

State-like values use `uint8` constants in small libraries:

- `DealState` for deal lifecycle
- `EvidenceType` for adapter output type
- `EvidenceResult` for adapter validation result
- `RailStatus` for FilecoinPay rail progress

Numeric values are append-only. Do not reorder, reuse, or renumber them. Leave
gaps for future states and validate transitions explicitly.

These are codes, not sortable ranks. External clients must use equality checks
against known constants and view helpers, not assumptions like
`state > ACCEPTED`.

Implementation must expose stable read helpers for these codes so indexers and
clients do not have to scrape internal library constants from source.

## Payment Rule

Commercial price stays monthly:

```text
monthlyTotal = pricePer32GiBPerMonth * billed32GiBUnits
```

V2 bills from the accepted covered bytes, clamped to the frozen request:

```text
committedBytes = min(coveredBytes, requestedSizeBytes)
billed32GiBUnits = ceil(committedBytes / 32GiB)
```

Activation requires covered bytes to be within a tolerance band of the frozen
requested size. The starting threshold is configurable:

```text
coveredBytes >= requestedSizeBytes * activationToleranceBps / 10_000
```

Deals that fall below the tolerance are not activated. The tolerance applies at
activation only; it does not constrain the billing clamp above. The tolerance
percentage, whether it should be adaptive, per-deal, or per-offer, and whether
a stricter mode (exact match) should be available are implementation decisions
that can evolve separately from the billing math.

FilecoinPay gets a ceiling rate:

```text
railMaxRatePerEpoch = ceil(monthlyTotal / EPOCHS_IN_MONTH)
```

Validator settlement uses the exact cumulative amount for the window:

```text
dueAt(epoch) = floor(monthlyTotal * (epoch - serviceStartEpoch) / EPOCHS_IN_MONTH)
settlementAmount = dueAt(toEpoch) - dueAt(fromEpoch)
```

The rail rate is the FilecoinPay ceiling, not the commercial payment rate.

The deal freezes the offer's `pricePer32GiBPerMonth` at proposal time. The
client's `maxPricePer32GiBPerMonth` is a proposal-time guard only; it is not
stored with the deal.

Cumulative floor-based settlement underpays by at most 1 base token unit over
the entire deal lifetime. Per-window settlements may fluctuate by +/−1 base
unit due to independent floor truncation, but the cumulative total always
converges. This is inherent to integer division and is accepted.

## Duration Rule

`durationDays` is the request unit. The market stores `durationEpochs` as the
frozen paid service duration.

Service starts when storage evidence is accepted. Payment ends
at:

```text
serviceEndEpoch = serviceStartEpoch + durationEpochs
```

`termMax` is Filecoin claimability slack. It is not paid service duration.

Current tooling will use 40 days of `termMax` slack. This can require extra
sector time for the SP, so provider-facing docs must call it out. The
alternative path is manual sector preparation with SnapDeals where
that fits the provider workflow.

Conversion from `durationDays` (uint32) to `durationEpochs` (uint64) is
overflow-safe for all uint32 values (`uint32_max * 2880 < uint64_max`).
Implementation must validate against the offer's `maxDurationEpochs` before
storing.

## Piece Set Identity Rule

The market freezes a `pieceSetCommitment` with the deal. `manifestLocation` is
only a URL/path for humans and tools; contracts do not fetch it or trust it.

`pieceSetCommitment` is `keccak256(manifest file bytes)`, not a single
PieceCID. A completed mainnet deal can contain many pieces; for example, deal
8's manifest contains 11 pieces and 11 matching Filecoin claims.

The starting contract does not treat a `bytes32` hash as an on-chain proof of
the whole manifest. The hash lets tools and reviewers check that the manifest
file used off-chain is the same file the client committed to at proposal time. A
contract can only validate concrete piece rows it receives or data returned by
Filecoin actors.

For DataCap / VerifReg, the adapter validates concrete evidence: decoded
allocation `Data` CIDs and sizes before DataCap transfer, returned allocation
IDs, VerifReg claim existence, `claim.data`, `claim.size`, provider, sector, and
the required termMin/termMax checks. Accepted claim bytes must satisfy the
activation tolerance threshold (see Payment Rule).

Claimed byte count alone is not enough, but whole-manifest equality proofs are
deferred. Do not add Merkle proof verification, per-piece permanent market
storage, or accumulator-based piece membership in the starting contract.

## Storage Evidence Rule

Payment starts only after accepted evidence proves the deal's required
data/pieces have approved storage coverage.

DataCap / VerifReg claims are handled by a storage-evidence adapter while
available. They are not the permanent V2 invariant. V2 stores the adapter used
for the deal and the activation fields used for payment, not VerifReg-specific
data in PoRepMarket.

DataCap-backed deals still use a guarded contract path for allocation posting.
The client submits DataCap allocation batches directly through
`DataCapEvidenceAdapter`. The adapter must validate the selected deal, frozen
client, accepted state, provider, DataCap recipient, amount, size,
termMin/termMax rules, and posting-open flag before DataCap is transferred.
Posting allocations does not activate payment.

The adapter interface is the contract boundary:

- PoRepMarket calls the adapter for activation checks
- adapter validates concrete allocation/claim evidence for its evidence type
- adapter can accept evidence in multiple batches before activation
- adapter validates concrete allocation and claim facts it can observe
- adapter returns covered bytes, not commercial payment fields
- market accepts only `EvidenceResult.ACCEPTED`
- market clamps covered bytes against the frozen deal and derives committed bytes,
  billed units, service start/end, and rail ceiling
- adapter keeps allocation IDs, claim IDs, and aggregate byte counts needed by
  tooling and activation

Validator must not call DataCap / VerifReg adapters directly. It asks
PoRepMarket for the deal's settlement decision so DataCap details remain inside
the adapter.

`DataCapEvidenceAdapter` is the concrete sketch for the current VerifReg claim
path. It can accept claim evidence in multiple batches and track aggregate claim
count / claimed bytes. It stores exact allocation and claim IDs for tooling,
retry logic, and review. Normal activation and settlement read aggregate counts
and byte totals; they do not iterate every stored ID. PoRepMarket does not store
VerifReg allocation or claim IDs.

`activateEvidence` does not re-verify individual claims. It reads the adapter's
accumulated totals from prior `submitEvidenceBatch` calls and checks whether
those totals satisfy the frozen deal requirements. This keeps activation cheap
even for huge deals.

For DataCap-backed deals, `DataCapEvidenceAdapter` is also the guarded DataCap
gateway; it is not a separate V2 `Client` contract.

The deal is the paid agreement. Sector placement is evidence and can change over
time.

`DataCapEvidenceAdapter` has a finite operational lifetime bound to Filecoin Plus
/ VerifReg availability. The adapter abstraction is designed for this transition.
See `porep-v2-datacap-sunset.md` for the full transition plan, on-chain evidence
requirements, and replacement adapter paths.

## DataCap Posting Boundary

DataCap allocation batches are posted before storage evidence can activate the
deal. Batch submission is append-only while posting is open. The caller is the
frozen deal client unless PoRepMarket explicitly forwards the client action.

`submitDataCapBatch` must reject wrong deal state, wrong caller, wrong selected
adapter, closed posting, non-VerifReg recipient, mismatched DataCap amount,
wrong provider, invalid terms, zero size, and returned allocation ID count
mismatches.

When the client has posted all intended allocation batches, the client calls a
separate finish method. The finish method requires posted allocation bytes to
satisfy the activation tolerance threshold, closes posting, and emits
`DealEvidenceReady(dealId, adapter)`. Later batches must revert. Duplicate
finish behavior must be explicit in implementation; the starting preference is
to emit readiness once and make later finish calls revert.

`finishDataCapPosting` is a separate transaction to prevent batch submission
from atomically closing the deal. In V1, the `dealCompleted` flag on transfer
could trigger deal completion before the SP had an opportunity to begin claim
work. Separating the finish call ensures: (a) the client explicitly confirms all
allocation batches are submitted, (b) `DealEvidenceReady` fires as a clean
signal for SP tooling, (c) no deal state transition or payment activation occurs
at this point.

`DealEvidenceReady` is an event consumed by SP/client tools, not a deal
lifecycle state. SP tooling can use it as the concrete hook to start
provider-side claim work. Client tooling can use it as confirmation that
allocation posting is closed. The deal remains `DealState.ACCEPTED` until
storage evidence is accepted and the FilecoinPay payment path is authorized for
activation.

Events are notification, not the only source of truth. The adapter exposes read
helpers for late-starting or retrying tools: whether posting is finished and
paginated allocation/claim ID getters. These getters return adapter-owned
allocation and claim IDs; they are not settlement authority and must not refresh
Filecoin state.

An upper allocation tolerance can be added later if prepared data and requested
deal size routinely differ. The starting rule is only that posted allocation
bytes must not be below the frozen requested size.

## Large Deal Evidence

V2 must not impose a product-level cap on pieces, claims, or total deal size.
A large deal can accumulate DataCap allocation and storage evidence over
multiple adapter calls before activation. Unlike V1, batch submission never
carries a completion boolean and never activates payment.

Any batch-size limit is a gas/transaction safety limit, not a deal-size limit.
The adapter stores aggregate counts and byte totals for the deal and emits
events for off-chain reconstruction. Normal settlement must not loop over every
piece or claim in a huge deal.

Activation reads the adapter's already-verified aggregate counts and byte totals
instead of rechecking every claim in one call. If piece or claim counts are too
large for a single transaction, tooling splits them across allocation/evidence
batches.
Normal settlement must not iterate every stored allocation or claim ID.

## Payment Activation Gate

A deal can become `DealState.ACTIVE` only when both conditions are true:

- the selected storage-evidence adapter accepts activation evidence
- the FilecoinPay payment path is authorized and can be activated for the frozen
  payment terms

The client can authorize or escrow the payment path before evidence is complete.
The nonzero rail ceiling is derived at activation from the accepted covered
bytes. `RailStatus.PREPARED` means the payment path is authorized, but payment
cannot accrue yet. Activation moves the deal to `DealState.ACTIVE` and the rail
to `RailStatus.ACTIVE`.

The rail must use the frozen payment token and payee, the configured deal
Validator, the authorized operator path, and the market-derived rail ceiling.

For DataCap / VerifReg, activation checks the claim term fields required by the
current DataCap rules. The market must not model `claim.term_max` as the
DataCap end or the paid service end. Paid service duration remains
`serviceEndEpoch`.

## Activation Permissions

`activateEvidence` is permissionless. The caller is not checked because
activation authority comes from prior steps: the client authorized the payment
rail, the client posted and finished allocations, the SP claimed data, and
evidence batches verified claims. Any account can call activation for any deal;
the market validates all preconditions from stored state.

The adapter must reject activation when aggregate covered bytes are below the
activation tolerance threshold, which prevents premature activation even without
caller restrictions.

## Termination Authority

Termination authority is split at rail creation:

Pre-rail (PROPOSED or ACCEPTED without rail): PoRepMarket methods terminate the
deal. `rejectDeal` (by provider), `releaseExpiredProposal` (by anyone after
expiry), and `terminateDeal` (by admin/authorized role) are market-initiated
transitions that release pending capacity.

Post-rail (ACCEPTED with rail, or ACTIVE): Termination flows from FilecoinPay.
When a rail is terminated in FilecoinPay, the FilecoinPay contract calls the
Validator's termination callback, and the Validator calls PoRepMarket to
transition the deal to `DealState.TERMINATED`. The market does not independently
terminate post-rail deals; termination is rail-driven.

The Validator records `earlyTerminatedEpoch` to cap settlement at the
termination point. Settlement after termination uses `earlyTerminatedEpoch` as
the final `toEpoch`.

## Duplicate Deal Guard

The auto-match picker must not assign the same provider to the same data twice.
When `proposeDealAuto` selects a provider, it must check whether the provider
already has a non-terminal deal (PROPOSED, ACCEPTED, or ACTIVE) for the same
`pieceSetCommitment`. If so, the picker skips that provider and tries the next
candidate.

Terminal deal states (REJECTED, TERMINATED, FINALIZED, EXPIRED) do not block future
assignment. A provider whose prior deal for the same data was rejected or
terminated can be re-picked. Whether a previously-failed provider should be
deprioritized or cooled down is a picker policy question, not a hard constraint.

This guard is per-provider, not per-market. Two different providers holding the
same data is intentional (replicas). The starting implementation is a simple
uniqueness check. Future extensions may include explicit replica count requests
(assign N providers for the same data in one pass) and cross-deal replica
tracking; the starting uniqueness check does not block these.

The check uses `pieceSetCommitment` as the data identity. Two deals with the same
`pieceSetCommitment` are assumed to contain the same data. If a client needs the
same data stored differently (different terms, different adapter), they produce
a different manifest and thus a different commitment.

## FilecoinPay Constraints

V2 depends on FilecoinPay for payment rails. Known constraints that affect deal
flow:

- **Operator approval must precede rail creation.** The client must approve the
  operator (Validator) on FilecoinPay before the rail can be created. The
  `preparePayment` step in the deal flow must enforce this ordering.
- **Token decimals affect minimum viable price.** FilecoinPay computes
  `ratePerEpoch` from the total amount and duration. Tokens with few decimals
  (e.g., 6) can truncate small per-epoch rates to zero, breaking settlement.
  This is why `minPricePer32GiBPerMonth` exists per token in SPRegistry: it
  prevents offers whose per-epoch rate would truncate to zero.
- **Lockup period updates have ordering constraints.** The FilecoinPay lockup
  period is a payment-safety mechanism (how long funds are committed to the rail),
  not a DataCap allocation lifetime. When the required lockup changes (e.g., due
  to term extensions), the Validator must update the FilecoinPay lockup before
  further deal progress. The current flow handles this via the allocation posting
  path.

These constraints are FilecoinPay's interface contract. V2 must respect them but
does not attempt to abstract over them. If FilecoinPay changes its operator or
lockup model, the Validator and deal flow adapt accordingly.

## Settlement Rule

Normal settlement must be deterministic from frozen deal state, active rail
state, and the accepted activation fields stored by PoRepMarket. Caller-supplied
evidence is not authority for ordinary settlement.

Validator calls PoRepMarket's settlement interface. PoRepMarket checks the deal,
rail, service window, and accepted activation state before returning a settlement
decision that includes the settlement amount and settle-up-to epoch.

Live VerifReg refreshes belong in separate maintenance/challenge functions that
cap claim IDs per transaction, not in every FilecoinPay settlement.

After the paid service window has ended and settlement has caught up, the deal
can move from `DealState.ACTIVE` to `DealState.FINALIZED`. `FINALIZED` is the
terminal successful lifecycle state; it is not a DataCap readiness state and
does not add another evidence status.

## Rules

- matching never compares prices across tokens
- active offer payment requires a nonzero price
- offer name is a capped service/offer label for clients and UI (`MAX_OFFER_NAME_BYTES = 64`)
- provider capacity is shared across offers and payment tokens
- proposal creation reserves pending capacity
- reject/expire releases pending capacity
- accepted storage evidence freezes committed capacity, billed 32GiB units, service start, and rail ceiling
- activation requires covered bytes within a configurable tolerance of requested size
- if committed bytes are less than reserved bytes at activation, the difference is
  released back to provider available capacity
- finalize closes an active deal only after the paid service window and required settlement are complete
- adapter selection is allow-listed and frozen for the deal before activation
- adapters expose `isOperational()` so the market can detect a non-functional adapter
  and allow admin rejection of stuck deals
- payment and validation read frozen deal state, not living offer state
- strict SLI slashing/checking is deferred from the first pilot deals
- events are the offer/deal history source

## Deferred / Out Of Starting Scope

### Token and pricing

- **Native FIL**: requires WFIL wrapping or native value handling; not needed for
  pilot tokens
- **Token fallback lists**: auto-selecting an alternative token when the primary
  is unavailable
- **Cross-token price comparison**: matching never compares prices across tokens
  by design; cross-token equivalence would require an oracle
- **Token-specific payees**: payee is provider-level; per-token routing adds
  complexity without current demand
- **Short-deal economics**: deals shorter than one settlement period (one month)
  create edge cases in the commercial framing and first-partial-month settlement.
  The pilot uses 6-month minimum deals (DataCap duration floor). When shorter
  deals become possible post-DataCap, the settlement math still works (per-epoch
  cumulative), but the commercial UX and pricing presentation need attention

### Offer and matching

- **Immutable offer versions**: offer edits affect future proposals only; version
  snapshots add storage with no current consumer
- **Offer-level capacity**: capacity is provider-level; per-offer capacity splits
  add accounting overhead
- **Service-class codes**: a categorical `uint8 offerType` on offers could label
  cold/warm/hot tiers for SLI scoring and matching. Currently the offer's SLI
  terms and name implicitly define the service tier. Adding a type constant that
  no contract logic reads is pure overhead. Can be added to the Offer struct via
  upgrade when contract logic needs it
- **Extra matching constraints**: geo-preferences, SP reputation scores, client
  allow/deny lists
- **Explicit replica requests**: assigning N providers for the same data in one
  pass. The starting duplicate guard prevents accidental double-assignment; future
  replica support builds on the same `pieceSetCommitment` uniqueness check but
  adds an explicit replica count parameter

### Evidence and proofs

- **Whole-manifest on-chain equality proofs**: proving the full piece set matches
  the commitment, beyond individual piece checks
- **Merkle or accumulator proofs for piece membership**: cryptographic proof that
  a piece is in the committed set
- **Per-piece permanent market storage**: storing individual piece CIDs in
  PoRepMarket (they stay in the adapter)
- **Normal-settlement VerifReg refreshes**: live claim re-verification during
  settlement; belongs in separate maintenance/challenge functions

### Client and payment policy

- **Non-paying client handling**: when a client's payment rail drains or the
  client disputes, deal termination flows through FilecoinPay's rail termination
  callback into the Validator and then PoRepMarket (proposition 23). The
  mechanical path exists. What is deferred is the policy layer: grace periods
  before termination, notification events to the SP during grace, client
  re-proposal paths after termination, and dispute resolution flows. The pilot
  operates with a trusted client where this is not a launch concern. The upgrade
  path: add a configurable grace period to the Validator, add pre-termination
  notification events, and optionally add a `SUSPENDED` deal state between
  `ACTIVE` and `TERMINATED`. None of these require storage layout changes to
  PoRepMarket; they are Validator-side and event-surface additions
- **Collateral or proposal bonds**: client-side deposits against abandonment or
  SP-side bonds against rejection

### Adapter interface

- **Normalized status queries**: high-level boolean queries on the adapter
  (`isDealSecured`, `isDataProving`, `isSectorAlive`) that abstract over the
  evidence model. Useful for monitoring and UI but not needed for the contract
  flow. `isOperational()` covers the adapter-health case. Additional status
  queries can be added to the interface via adapter upgrade without changing
  PoRepMarket
- **Piece change notifications / hooks**: adapter callbacks when piece membership
  changes (pin/unpin/sector termination). Depends on post-DataCap evidence
  primitives

### Monitoring and observability

- **Per-deal monitoring events**: specific events for deal health checks,
  evidence progress tracking, and settlement anomaly detection. Basic lifecycle
  events (proposal, acceptance, activation, termination, finalization) are in
  scope. Detailed monitoring events can be added without storage changes
- **Anti-gaming observability**: detecting patterns like SPs accepting but never
  sealing, clients proposing then abandoning, or evidence submission anomalies.
  Requires analysis of real pilot data before designing detection heuristics
- **Provider tier/status field**: a quality or tier indicator on the Provider
  struct beyond `paused`/`blocked`. Can be added to the Provider struct via
  upgrade when matching logic or governance needs it

### Operations

- **V1 import or migration tooling**: V1 deals continue on V1 until closed
- **Upper allocation tolerance**: for when prepared data routinely differs from
  requested size
- **Client tooling and retrieval**: retrieval verification, manifest protection,
  and client portal are separate projects. V2 contracts should expose clean read
  interfaces that make tooling straightforward, but the tooling itself is not
  contract scope
- **Full implementation-level events, errors, pagination, or test matrix**: these
  are implementation details, not starting-spec decisions
