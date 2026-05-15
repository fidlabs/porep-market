# PoRep Market V2 Starting Spec

Status: draft for PR review.

This folder is the repo review surface for the V2 starting shape. The goal is to
make the contract split commentable without turning the spec into a full
implementation plan.

## Files

| File | Purpose |
| --- | --- |
| `porep-v2-overview.md` | short client/SP view |
| `porep-v2-shared-types.sol` | request, selection, and SLI vocabulary |
| `porep-v2-spregistry-storage.sol` | living provider, offer, token, and capacity storage |
| `porep-v2-market-storage.sol` | frozen deal snapshot and lifecycle storage |
| `porep-v2-validator-storage.sol` | per-deal rail identity and settlement guard storage |
| `porep-v2-architecture-diagrams.md` | offer freeze and lifecycle/payment diagrams |
| `porep-v2-propositions.md` | proposed shape and review points |

## Starting Point

V2 starts from:

- provider-owned offers
- SP-defined offer names for client/UI discovery
- multiple payment tokens per offer
- provider-level shared capacity
- frozen deal snapshots
- token-bound FilecoinPay rails
- auto-match and direct offer selection over the same storage model

## Contract Split

`SPRegistry` owns living provider configuration. Providers can change offers,
payment rows, and availability for future proposals.

`PoRepMarket` owns deals. A deal freezes the selected offer terms, payment token,
payee, duration, capacity, and SLI terms. Later offer/provider edits do not
change existing deals.

`Validator` owns rail identity and settlement guard state. It should read frozen
deal/payment data from `PoRepMarket`, not keep a second copy unless gas forces a
write-once cache later.

## External Interface Shape

The external API should stay small.

- command functions show how deals/offers move
- read functions return composed views (`DealView`, `OfferView`, `ProviderView`)
- storage mappings stay inside storage sketches
- full event/error/pagination design is not part of this starting pass

## Payment Rule

Commercial price stays monthly:

```text
monthlyTotal = pricePer32GiBPerMonth * billed32GiBUnits
```

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

## Duration Rule

`durationDays` is the request unit. The market stores `durationEpochs` as the
frozen paid service duration.

Service starts on completion. Payment ends at:

```text
serviceEndEpoch = serviceStartEpoch + durationEpochs
```

`termMax` is Filecoin claimability slack. It is not paid service duration.

Current tooling will use 40 days of `termMax` slack. This can create extra
sector time the SP may need to maintain, so it should be documented for
providers. The alternative path is manual sector preparation with SnapDeals where
that fits the provider workflow.

## Rules

- matching never compares prices across tokens
- active offer payment requires a nonzero price
- offer name is a capped service/offer label for clients and UI (`MAX_OFFER_NAME_BYTES = 64`)
- provider capacity is shared across offers and payment tokens
- proposal creation reserves pending capacity
- reject/expire releases pending capacity
- complete freezes committed capacity, billed 32GiB units, service start, and rail ceiling
- payment and validation read frozen deal state, not living offer state
- strict SLI slashing/checking is deferred from the first pilot deals
- events are the offer/deal history source

## Deferred / Out Of Starting Scope

- native FIL
- token fallback lists
- cross-token price comparison
- token-specific payees
- immutable offer versions
- offer-level capacity
- service-class enum
- generic constraints
- collateral or proposal bonds
- full implementation-level events, errors, pagination, or test matrix
