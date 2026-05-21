# PoRep Market V2 Propositions

Status: draft for PR review.

This file keeps the proposed shape that is easy to lose while reviewing
code-like spec files. Treat these as reviewable propositions until the V2
implementation plan is locked.

## Proposed Starting Shape

1. Proposal API takes `durationDays`; storage freezes `durationEpochs`

   `durationDays` stays the client-facing request unit. The market converts it once
   and stores `durationEpochs` as the paid service duration.

2. Service duration is enforced by the market

   Service starts when storage evidence is accepted.
   `serviceEndEpoch` is derived from
   `serviceStartEpoch + durationEpochs` and stored with the deal. It must not
   be supplied later by an off-chain bot.

3. `termMax` is claimability slack, not paid service duration

   Current tooling will use 40 days of slack. That can require extra sector time
   for the SP, so provider-facing docs must call it out. The
   alternative is to prepare sectors manually and use SnapDeals where that
   operational path makes sense.

4. Provider identity is `CommonTypes.FilActorId`

   No synthetic provider id in the starting scope.

5. Payee is provider-level

   Token-specific payees are deferred.

6. Offers are living configuration; deals are frozen snapshots

   Offer edits affect future proposals only. Existing deals keep the provider,
   offer id, piece-set commitment, payment token, payee, price, duration,
   capacity, evidence adapter, and SLI terms that were frozen at
   proposal/activation time.

7. Offer token enumeration is current state

   Deactivated offer payment rows leave current discovery. History comes from
   events.

8. Pricing is monthly token units per 32GiB

   The commercial unit stays readable. FilecoinPay receives a derived
   per-epoch ceiling rate.

9. Payment uses exact cumulative settlement

   Keep the truncation fix: derive `railMaxRatePerEpoch` with ceiling math, then
   settle from `dueAt(toEpoch) - dueAt(fromEpoch)` using the frozen monthly
   economics.

10. `railMaxRatePerEpoch` is frozen when payment starts

    The final value depends on `billed32GiBUnits`, so it belongs at activation /
    rail creation time, not proposal time.

11. Stored states use expandable numeric constants

    Deal lifecycle, evidence type, evidence result, and rail status are stored as
    `uint8` constants in small libraries instead of Solidity enums. Values are
    append-only, intentionally gapped, and transition-checked explicitly.
    Clients must not sort or compare state codes as ranks.

12. Storage evidence checks are adapter-owned

    DataCap / VerifReg validation lives behind `IStorageEvidenceAdapter`. The
    `DataCapEvidenceAdapter` is the adapter for the current claim path. The
    market owns activation and stores the payment activation fields: deal state,
    committed bytes, billed units, service start/end, and rail ceiling.
    Allocation IDs, claim IDs, and DataCap-specific evidence stay in the adapter.
    PoRepMarket is the activation caller. DataCap posting is direct
    client-to-adapter guarded by adapter checks. Validator goes through
    PoRepMarket's settlement path instead of calling adapters itself.

13. Market derives payment activation fields

    The adapter returns whether evidence is accepted and how many bytes are
    covered. PoRepMarket validates that output against the frozen deal, then
    derives committed bytes, billed units, service start/end, and rail ceiling.

14. Huge deals are supported by batched evidence

    There is no product-level cap on pieces or claims per deal. Adapters can
    accept evidence over multiple calls before activation. Normal settlement
    reads aggregate counts and byte totals; it does not loop over every stored
    allocation or claim ID.

15. Piece identity is checked at allocation and claim time

    DataCap allocation `Data` CIDs and VerifReg claim `Data` CIDs must be
    checked when they are submitted or returned by Filecoin actors. Claimed bytes
    alone are not enough to activate payment. `pieceSetCommitment` is
    `keccak256(manifest file bytes)`. Whole-set on-chain equality proofs are
    deferred.

16. Payment must be prepared before activation

    Accepted storage evidence can move a deal to `Active` only when the
    FilecoinPay payment path is authorized for the frozen token, payee,
    validator, operator path, and market-derived rail ceiling. DataCap claim
    termMin/termMax checks must be performed, but `claim.term_max` is not the
    paid service end.

17. `Finalized` closes successful service

    A deal must not live in `Active` forever. Once the paid service window has
    ended and required settlement has caught up, the market can move it to
    `Finalized`. This is a terminal deal lifecycle state, not a DataCap or
    evidence readiness state.

18. DataCap posting is explicit and separate from activation

    DataCap-backed deals use guarded contract calls for allocation batches. The
    adapter enforces selected deal, accepted state, frozen client, provider,
    recipient, amount, termMin/termMax, posting-open, and returned-ID checks. The
    client finishes posting with a separate method once posted allocation bytes
    cover at least the frozen requested size. Finishing emits `DealEvidenceReady`
    for SP and client tooling, but it does not change the core deal state and
    does not start payment.

19. DataCap allocation and claim IDs stay out of PoRepMarket

    `DataCapEvidenceAdapter` stores exact allocation and claim IDs for tooling,
    retry logic, and review. Normal activation and settlement use aggregate
    counts and byte totals, not loops over every stored ID. PoRepMarket stores
    the selected adapter and payment activation fields, not VerifReg-specific
    IDs. The adapter exposes whether posting is finished and paginated
    allocation/claim ID getters for tooling.

20. Direct offer selection is the first useful path

    `proposeDealForOffer` is the first path to implement. `proposeDealAuto` can
    stay in the interface as the same flow with offer selection resolved by
    `SPRegistry`.

21. Strict SLI enforcement is deferred

    First deals can run with simpler pilot SLI tooling. Strict SLI checking,
    slashing, and penalty math must be specified separately before becoming
    payment-affecting contract logic.

## Still Worth Reviewing

1. Release shape

   V2 starts as fresh canonical contracts. Existing V1 deals are not migrated
   into V2 state in the starting scope; they continue on V1 until closed or
   terminated.

2. Billing input for `billed32GiBUnits`

   PoRepMarket derives billing from adapter-returned covered bytes after
   clamping it against the frozen requested size:

   ```text
   billed32GiBUnits = ceilDiv(min(coveredBytes, requestedSizeBytes), 32 GiB)
   ```

3. Stable event surface

   Which events are stable external-consumer events for V2?

   Current recommendation: keep it rich enough for clients, SPs, UI, and
   indexers to reconstruct offer/deal history, but do not design a full event
   matrix in the starting spec.

## Implementation Notes

1. On-chain indexes

   Decide during implementation which deal indexes are contract-critical.
   Client/provider/state indexes are useful, but this is not a major spec
   question unless an external contract depends on them.

2. Pagination

   Add pagination only for views that can grow without bounds. This is an API
   hardening detail, not a starting-spec decision.

3. Rescue allocation terms

   Replacement allocation `termMin` must use remaining paid service duration,
   not the original full duration. The exact rescue helper behavior belongs in
   tooling docs.
