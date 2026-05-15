# PoRep Market V2 Starting Spec

Status: draft for PR review.

This folder is the code-review surface for the initial V2 contract shape. It is intentionally code-heavy so reviewers can comment on specific fields, structs, and function boundaries.

The files here are not deployed source. They are proposal artifacts for converging on the V2 storage and interface shape before implementation.

## Files

- `porep-v2-shared-types.sol` sketches the structs shared across V2 contracts.
- `porep-v2-spregistry-storage.sol` sketches the state owned by `SPRegistry`.
- `porep-v2-market-storage.sol` sketches the state owned by `PoRepMarket`.
- `porep-v2-validator-storage.sol` sketches the state owned by `Validator`.
- `porep-v2-interfaces.sol` sketches the external and cross-contract API surface.
- `porep-v2-open-questions.md` lists decisions that should be closed before implementation begins.

The storage files are split by intended end location so reviewers can see what lands in each contract, what is shared, and what should not cross contract boundaries.

## Starting Position

V2 should start with token-bound, offer-selected deal creation:

- providers maintain living offers
- every offer payment row is bound to one ERC-20 token
- every deal freezes token, payee, price, duration, and SLI terms at proposal time
- provider capacity stays shared at provider level, not split per offer or token
- FilecoinPay rails use the frozen deal payment token
- offer discovery and ranking can stay off-chain until on-chain matching proves necessary

This preserves the important V1 boundary: mutable provider configuration can affect future proposals, but must not affect already proposed or accepted deals.

## Main V1 Deltas

V1 has one provider registration row with one tokenless price in `SPRegistry.ProviderData`, one `PoRepTypes.DealProposal` carrying mutable-looking commercial terms, and rail setup that can drift from deal terms through external inputs.

V2 should split those concerns:

- `Provider` stores identity, owner/payee, pause/block state, and shared capacity.
- `Offer` stores provider-owned eligibility terms.
- `OfferPayment` stores token-specific price rows for an offer.
- `Deal` stores lifecycle and provenance.
- `DealTerms` stores frozen size and service window.
- `DealPayment` stores frozen token, payee, agreed monthly amount, and rail ceiling.
- `SLITerms` stays typed and separately stored so future SLI fields append cleanly.

## Payment Rule

Keep the commercial price monthly. Derive a ceil-based FilecoinPay rail ceiling:

```text
railMaxRatePerEpoch = ceil(pricePer32GiBPerMonth * billed32GiBUnits / 86_400)
```

Validator settlement should pay exact cumulative deltas:

```text
dueAt(epoch) = floor(agreedMonthlyTotal * (epoch - paymentStartEpoch) / 86_400)
settlement = dueAt(toEpoch) - dueAt(fromEpoch)
```

This keeps the FilecoinPay rate invariant while preventing per-settlement truncation drift.

## Duration Rule

Keep `durationDays` as the external UX unit. Freeze `durationEpochs` on chain and derive the paid service end from the payment start:

```text
durationEpochs = durationDays * 2_880
serviceEndEpoch = paymentStartEpoch + durationEpochs
```

`termMax` remains Filecoin claimability slack, not paid service duration.

## Deferred / Out Of Starting Scope

- native FIL or `address(0)` payment token
- token fallback lists
- cross-token price comparison
- token-specific payees
- offer-level capacity
- service-class enum
- generic constraint language
- collateral, bonds, quotas, or client allowlists
- FilecoinPay source changes unless implementation proves they are unavoidable
