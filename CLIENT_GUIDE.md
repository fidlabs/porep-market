# Client Guide (Tech-savvy) — Using Peer-to-Pool Allocator (PoRep Market)

This guide is for **technical clients** who want to programmatically use the PoRep Market system to place verified storage with Storage Providers (SPs), enforce SLI requirements, and pay via FilecoinPay rails.

It focuses on the **actual on-chain flows** in this repo. For deployment/operator details, see [`DEVELOPER.md`](DEVELOPER.md).

## What you will do (high-level)

For each deal, you will:

1. **Propose** a deal on `PoRepMarket` (requirements + commercial terms + manifest).
2. Ensure the SP is **Accepted** (auto-approve or SP manually accepts).
3. **Create** a per-deal `Validator` via `ValidatorFactory` (this becomes the FilecoinPay validator).
4. **Deposit** into FilecoinPay and approve the validator as operator.
5. **Create** the FilecoinPay rail via `Validator.createRail(token)` (payer = you, payee = SP payee).
6. **Allocate DataCap** (DDO allocations and/or claim extensions) by calling `Client.transfer(...)`.
7. Mark deal complete (either in the final `Client.transfer(..., dealCompleted=true)` call, or by your application logic).
8. Let the system settle periodically; payouts occur only when SLIs are met and verified size matches.

## Contracts you need addresses for

From the deployment artifact (`deployments/<network>/latest.json`) you need:

- `PoRepMarket` (proxy)
- `ValidatorFactory` (proxy)
- `Client` (proxy)
- `SPRegistry` (proxy)
- `SLIOracle` + `SLIScorer` (proxies) (mostly for monitoring)
- External:
  - `FILECOIN_PAY` (FilecoinPay contract address)
  - `META_ALLOCATOR` (MetaAllocator contract address)

## Deal model

### Requirements: `SLITypes.SLIThresholds`

Fields:

- `retrievabilityBps` (0–10,000)
- `bandwidthMbps`
- `latencyMs`
- `indexingPct` (0–100)

Semantics:

- **0 means “don’t evaluate this dimension”.**
- The scorer returns an integer percent score. `Validator` currently treats **100** as “pass” for settlement.

### Terms: `SLITypes.DealTerms`

- `dealSizeBytes`: estimated verified size you intend to allocate/extend
- `pricePerSectorPerMonth`: monthly price per 32GiB sector (token smallest units)
- `durationDays`: must be:
  - > 0
  - ≤ 1278
  - divisible by 30

On-chain guardrails in `PoRepMarket`:

- `manifestLocation` must be non-empty and ≤ 2048 bytes
- `retrievabilityBps ≤ 10_000`, `indexingPct ≤ 100`
- `pricePerSectorPerMonth` must be ≥ `EPOCHS_IN_MONTH` (protocol sanity check)

## Step-by-step: single deal flow

### 1) Propose the deal

Call:

- `PoRepMarket.proposeDeal(requirements, terms, manifestLocation)`

What happens:

- PoRepMarket asks `SPRegistry.getProviderForDeal(...)` to select a provider and reserve pending capacity.
- Deal is created in either:
  - `Proposed` (SP must accept), or
  - `Accepted` (auto-approve based on SP price)

What to watch:

- `DealProposalCreated(dealId, client, provider, requirements, manifestLocation, totalDealSize, proposedAtBlock)`
- If auto-accepted: `DealAccepted(dealId, owner, provider)`

### 2) Ensure the deal is Accepted

If not auto-accepted, the SP must call:

- `PoRepMarket.acceptDeal(dealId)`

You can poll:

- `PoRepMarket.getDealProposal(dealId)` and check `state == Accepted`

### 3) Create the per-deal Validator

Call:

- `ValidatorFactory.create(dealId)` **from the same EOA** that proposed the deal.

What happens:

- Factory deploys a beacon proxy validator and initializes it.
- Validator initialization calls `PoRepMarket.updateValidator(dealId)` so the deal stores its validator address.

What to watch:

- `ValidatorFactory.ProxyCreated(proxy, dealId)`
- `PoRepMarket.ValidatorUpdated(dealId, validator)`

### 4) Deposit into FilecoinPay and approve operator

You must:

- deposit the ERC20 token you’ll pay with into FilecoinPay, and
- approve the deal’s validator as an operator with sufficient:
  - **rate allowance**
  - **lockup allowance**
  - **max lockup period** (must be ≥ 1 month; enforced by `Validator.createRail`)

This is FilecoinPay-specific; most deployments wrap it in a single “deposit + permit + approve operator” transaction.

### 5) Create the payment rail

Call:

- `Validator.createRail(token)`

What happens:

- Validator checks operator approval exists in FilecoinPay.
- Payee is fetched from `SPRegistry.getPayee(providerId)`.
- Validator creates the rail in FilecoinPay.
- Validator calls `PoRepMarket.updateRailId(dealId, railId)`.
- Validator sets initial lockup period to **1 month**.

What to watch:

- `PoRepMarket.RailIdUpdated(dealId, railId)`

### 6) Perform DataCap allocations / claim extensions

Call:

- `Client.transfer(params, dealId, dealCompleted)`

This is the core “verified storage” action. The client contract:

- registers the deal (reads proposal from PoRepMarket, validates:
  - `proposal.railId != 0`
  - caller is `proposal.client`
  - proposal state is `Accepted`
)
- parses `params.operator_data` as CBOR describing:
  - **allocations**: requests for new allocations, and
  - **claim extensions**: requests to extend existing claims
- asks `MetaAllocator.addVerifiedClient(...)` for enough allowance
- calls `DataCapAPI.transfer(params)`
- decodes allocation IDs from the DataCap transfer return (when allocations are included)
- tracks allocation/claim IDs and `sizeOfAllocations` for later verification

#### `operator_data` format (important)

`Client` expects `operator_data` to be a CBOR fixed array of length 2:

1. array of allocation requests; each request must be a fixed array of length 6:
   - provider (uint64 actor id)
   - data (bytes) — CID
   - size (uint64)
   - termMin (int64)
   - termMax (int64)
   - expiration (int64)
2. array of claim extension requests; each request must be a fixed array of length 3:
   - provider (uint64 actor id)
   - claimId (uint64)
   - newExpiration (int64) (currently read but not used by verification logic)

Validation rules:

- allocation/claim provider must match the deal’s provider
- malformed CBOR shapes revert (see errors like `InvalidOperatorData`, `InvalidAllocationRequest`, `InvalidClaimExtensionRequest`)

#### Completing the deal

If you set `dealCompleted=true` on a transfer call, then:

- `Client` calls `PoRepMarket.completeDeal(dealId, deal.sizeOfAllocations)`
- `PoRepMarket` commits capacity in `SPRegistry` and moves deal to `Completed`

What to watch:

- `PoRepMarket.DealCompleted(dealId, client, actualSizeBytes, provider)`

Practical pattern:

- Call `Client.transfer(..., dealCompleted=false)` multiple times while you are still allocating/extending.
- Call `Client.transfer(..., dealCompleted=true)` on the final batch once you consider the verified allocation set “final”.

### 7) Settlement and ongoing verification

Settlement is gated by the deal’s validator during FilecoinPay settlement. Validation checks:

- SLI score equals 100 via `SLIScorer.calculateScore(provider, requirements)`
  - requires a non-expired `SLIOracle` attestation (fresh within ~1 month)
- `Client.isDataSizeMatching(dealId)` returns true:
  - the contract queries VerifReg claims for tracked IDs
  - it removes expired or terminated claims from its internal tracking
  - it compares active size to the stored expected size

If either check fails, payout for that interval is withheld.

## Monitoring and debugging (client side)

### Events worth indexing

From `PoRepMarket`:

- `DealProposalCreated`
- `DealAccepted`
- `ValidatorUpdated`
- `RailIdUpdated`
- `DealCompleted`
- `DealTerminated`
- `DealRejected`
- `ManifestLocationUpdated`

From `SLIOracle`:

- `SLIAttestationUpdate(provider, lastUpdate, slis)`

From `Validator`:

- `RailPaymentModified`
- `DealEndEpochUpdated`
- `RailDisabled` / `RailTerminated`

### Common failure modes and what to check

- **`NoProviderFoundForDeal` on propose**
  - your requirements/terms don’t match any registered SP (capabilities, duration limits, pricing expectations, or capacity).
- **Deal stuck in `Proposed`**
  - SP didn’t accept and auto-approve didn’t trigger (price mismatch or SP has no auto-approve price).
- **`Validator.createRail` reverts `OperatorNotApproved`**
  - you didn’t approve the validator operator in FilecoinPay, or allowances are 0.
- **`Client.transfer` reverts `InvalidRailId`**
  - you attempted allocations before the rail was created and written to `PoRepMarket`.
- **Settlement withheld**
  - oracle attestation missing/expired, SLI score < 100, or `isDataSizeMatching` fails due to expired/terminated claims.

## Related docs

- Developer and operator guide: [`DEVELOPER.md`](DEVELOPER.md)
- Protocol overview: [`README.md`](README.md)

