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

   Service starts on completion. `serviceEndEpoch` is derived from
   `serviceStartEpoch + durationEpochs` and stored with the deal. It should not
   be supplied later by an off-chain bot.

3. `termMax` is claimability slack, not paid service duration

   Current tooling will use 40 days of slack. That creates extra sector time the
   SP may need to maintain, so this should be documented for providers. The
   alternative is to prepare sectors manually and use SnapDeals where that
   operational path makes sense.

4. Provider identity is `CommonTypes.FilActorId`

   No synthetic provider id in the starting scope.

5. Payee is provider-level

   Token-specific payees are deferred.

6. Offers are living configuration; deals are frozen snapshots

   Offer edits affect future proposals only. Existing deals keep the provider,
   offer id, payment token, payee, price, duration, capacity, and SLI terms that
   were frozen at proposal/completion time.

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

    The final value depends on `billed32GiBUnits`, so it belongs at completion /
    rail creation time, not proposal time.

11. Direct offer selection is the first useful path

    `proposeDealForOffer` should work first. `proposeDealAuto` can stay in the
    interface as the same flow with offer selection resolved by `SPRegistry`.

12. Strict SLI enforcement is deferred

    First deals can run with simpler pilot SLI tooling. Strict SLI checking,
    slashing, and penalty math should be specified separately before becoming
    payment-affecting contract logic.

## Still Worth Reviewing

1. Release shape

   Should V2 ship as fresh canonical contracts or as an in-place upgrade /
   migration?

   Current recommendation: design the spec as fresh V2 canonical contracts.
   Treat migration as a release-plan question unless it changes the storage
   shape.

2. Billing source for `billed32GiBUnits`

   Should it be rounded from actual completed bytes, Filecoin claim size, or
   another authoritative completion value?

   Current recommendation: use the value closest to what is actually claimed /
   committed on Filecoin, then round up to 32GiB units.

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

   Replacement allocation `termMin` should use remaining paid service duration,
   not the original full duration. The exact rescue helper behavior belongs in
   tooling docs.
