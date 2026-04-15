# Peer-to-Pool Allocator (PoRep Market) — Developer Documentation

This repository (`porep-market`) contains the **on-chain core** of the Peer-to-Pool Allocator, implemented as **FEVM / Solidity** smart contracts and deployed/operated alongside several **off-chain services** (in the other workspace folders).

The goal of the system is to:

- Match **Clients** (data owners) to **Storage Providers** (SPs) using a registry of capabilities and pricing
- Enforce **quality-of-service** using SLI (Service Level Indicator) attestations
- Execute **performance-gated payments** via FilecoinPay rails
- Allocate **DataCap** (DDO allocations / claim extensions) for verified storage through a MetaAllocator

If you’re new, start with the existing high-level overview in `README.md`, then use this document for **end-to-end developer setup and operations**.

## Repository map

- **Core contracts**
  - `src/PoRepMarket.sol`: deal state machine and lifecycle
  - `src/SPRegistry.sol`: provider registry, matching, capacity accounting
  - `src/ValidatorFactory.sol`: per-deal `Validator` deployment via beacon proxies
  - `src/Validator.sol`: FilecoinPay validator/operator logic and settlement gating
  - `src/Client.sol`: DataCap transfer + allocation tracking; completion callback into `PoRepMarket`
  - `src/SLIOracle.sol`: stores off-chain SLI attestations on-chain
  - `src/SLIScorer.sol`: scores a provider vs a deal’s SLI requirements using the oracle attestation
- **Types & interfaces**
  - `src/types/SLITypes.sol`, `src/types/PoRepTypes.sol`
  - `src/interfaces/*`
- **Deployment**
  - `script/Deploy.s.sol`: deploys all upgradeable proxies and wires circular deps
  - `script/Upgrade.s.sol`: upgrades one UUPS proxy (and records artifact)
  - `deployments/*`: JSON artifacts per network + `latest.json`
- **Generated ABIs**
  - `abis/*.json` (checked in; see `just gen-abis` and `just check-abis`)
- **CI and quality gates**
  - `justfile`: standard entrypoint for fmt/lint/test/coverage/deploy
  - `ci/check-full-coverage.sh`: enforces 100% line/function coverage (branches summarized)

## What the other folders do (off-chain services)

In this workspace, the other repos are “operators” around the on-chain core:

- **`filecoin-oracle-service`**: pushes SLI attestations on-chain into `SLIOracle` and tracks terminations (claims) for `Client`’s `claimsTerminatedEarly`.
  - Schedules cron jobs; exposes a small HTTP server for triggering/health.
  - Uses on-chain multicalls to write multiple `setSLI()` updates efficiently.
- **`provider-sample-url-finder`** (Random Piece Availability / URL Finder): discovers working HTTP retrieval endpoints for SPs and samples piece CIDs; can be used to compute retrievability and feed upstream metrics systems.
  - Runs background discovery/schedulers and exposes HTTP endpoints (Axum).
  - Integrates with BMS for bandwidth measurements and persists results.
- **`bandwidth-measurement-system` (BMS)**: distributed bandwidth measurement (scheduler + workers + RabbitMQ + Postgres). Used to produce bandwidth metrics for SP endpoints.

This document explains how these pieces connect to the on-chain flows, and how to run them locally.

## Concepts and roles

- **Client (EOA)**: proposes deals, funds FilecoinPay rails, initiates DataCap transfer/allocation.
- **Storage Provider (SP)**: registers capabilities/capacity, accepts deals, seals data, withdraws earned payments.
- **Organization**: an address used to group providers for reporting (`getDealsForOrganizationByState`) and for registry association.
- **PoRepMarket**: deal lifecycle coordinator (propose/accept/complete/reject/terminate).
- **SPRegistry**: provider discovery/matching + capacity reservation/commit/release.
- **ValidatorFactory / Validator**: one `Validator` per deal; `Validator` gates FilecoinPay settlement.
- **Client (contract)**: DataCap transfer helper and allocation/claim tracking; calls `PoRepMarket.completeDeal()` when done.
- **SLIOracle / SLIScorer**: oracle storage + scoring (attestation freshness window is 1 month).
- **MetaAllocator**: external contract that grants DataCap allowance; `Client` requests allowance each transfer.
- **FilecoinPay**: external payment rail contract used for streaming/settled payments.
- **PoRep service bot**: privileged operator that triggers periodic settlement operations (e.g., updates rail rate, sets end epoch, terminates rails).
- **Termination oracle**: privileged role that marks claims terminated early in `Client`.

## End-to-end on-chain flow (developer view)

### 1) Provider onboarding

1. Deploy contracts (or use existing deployed addresses).
2. Register providers in `SPRegistry` with:
   - **organization**
   - **capabilities** (`SLITypes.SLIThresholds`)
   - **availableBytes**
   - optional **auto-approve price** (`pricePerSectorPerMonth`)
   - optional **deal duration limits**
3. Providers (or admins/operators) can subsequently update:
   - `setCapabilities`, `updateAvailableSpace`, `setPrice`, `setPayee`, `pauseProvider`, etc.

Matching behavior:

- `PoRepMarket.proposeDeal()` calls `SPRegistry.getProviderForDeal()`.
- `SPRegistry` picks the **eligible provider with lowest pending bytes**, then **reserves pending capacity** immediately.
- If deal price meets provider auto-approve price, deal is auto-accepted; otherwise SP must call `acceptDeal()`.

### 2) Client proposes and SP accepts a deal

1. Client calls `PoRepMarket.proposeDeal(requirements, terms, manifestLocation)`.
2. If not auto-approved, SP calls `PoRepMarket.acceptDeal(dealId)`.

Deal constraints enforced by `PoRepMarket`:

- `manifestLocation` must be non-empty and ≤ 2048 bytes
- `retrievabilityBps ≤ 10_000`, `indexingPct ≤ 100`
- `terms.durationDays` must be:
  - > 0
  - ≤ 1278 days
  - divisible by 30
- `terms.pricePerSectorPerMonth` must be ≥ `EPOCHS_IN_MONTH` (a protocol sanity guard)

### 3) Create per-deal Validator and FilecoinPay rail

1. Client calls `ValidatorFactory.create(dealId)` to deploy a beacon proxy `Validator` for the deal.
2. During `Validator.initialize(...)`, the validator:
   - records deal context
   - calls `PoRepMarket.updateValidator(dealId)` (so PoRepMarket stores `validator` address)
3. Client deposits funds into FilecoinPay and approves the validator as an operator (FilecoinPay-specific flow).
4. Client calls `Validator.createRail(token)` to create a rail:
   - checks operator approval + allowances
   - fetches SP payee from `SPRegistry`
   - creates rail in FilecoinPay
   - calls `PoRepMarket.updateRailId(dealId, railId)`
   - sets initial lockup to 1 month

### 4) DataCap allocation (DDO) and deal completion

1. Client transfers data off-chain to the SP.
2. Client calls `Client.transfer(params, dealId, dealCompleted)`:
   - verifies the caller is the deal client
   - parses VerifReg operator data for allocations and/or claim extensions
   - asks `MetaAllocator.addVerifiedClient(...)` for enough allowance to cover requested size
   - executes `DataCapAPI.transfer(params)` (FRC-46 Datacap transfer)
   - tracks `allocationIds` / `claimIds` on the deal
   - increments `sizeOfAllocations`
3. If `dealCompleted=true`, the `Client` contract calls:
   - `PoRepMarket.completeDeal(dealId, deal.sizeOfAllocations)`
   - which commits provider capacity in `SPRegistry` and marks deal `Completed`

### 5) Periodic settlement (payments gated by SLIs + data size)

When FilecoinPay requests payment validation for a settlement window, `Validator.validatePayment(...)`:

- Ensures enough epochs have passed since last settlement (default 1 month; admin-adjustable via `setMinEpochsBetweenSettlements`)
- Reads deal requirements from `PoRepMarket`
- Computes score via `SLIScorer.calculateScore(providerId, requirements)`
  - requires a non-expired attestation in `SLIOracle` (fresh within 1 month)
- Calls `Client.isDataSizeMatching(dealId)`:
  - queries VerifReg claims to compute active size
  - drops expired/terminated claims (also uses `claimsTerminatedEarly` marking)
- If score is not perfect (100) **or** size mismatch: settlement is not approved for the interval
- Otherwise: approves settlement, and caps the final settlement at deal end epoch if needed

### 6) Deal termination and capacity release

Rails can be terminated by the PoRep service bot or admin (`terminateRail` / `disableFutureRailPayments`).

When FilecoinPay notifies the validator via `railTerminated(...)`, the validator calls:

- `PoRepMarket.terminateDeal(dealId, terminator, endEpoch)` which:
  - releases committed capacity in `SPRegistry`
  - removes deal from “ready for payment”
  - marks deal as `Terminated`

## Local development (contracts)

### Prerequisites

- Foundry (`forge`, `cast`)
- `just`
- `solhint`
- `jq`
- For coverage reports: `lcov` + `genhtml`

### Clone with submodules

This repo uses git submodules for `forge-std`, OpenZeppelin, `filecoin-solidity`, and `filecoin-pay`.

```bash
git submodule update --init --recursive
```

### Standard workflows

Use `just` as the primary entrypoint:

```bash
just --list
just fmt
just lint
just test
just check      # CI-equivalent: fmt-check, lint, tests, coverage, ABI checks
```

ABI generation and verification:

- `just gen-abis`: rebuild and regenerate `abis/*.json`
- `just check-abis`: ensures checked-in ABIs match build outputs

## Deploying the contracts (devnet / calibnet / mainnet)

### Required environment variables

See `.env.example`. At minimum for deployment you’ll need:

- `RPC_URL`
- `PRIVATE_KEY`
- `FILECOIN_PAY`
- `TERMINATION_ORACLE`
- `ORACLE` (address granted `ORACLE_ROLE` in `SLIOracle`)
- `META_ALLOCATOR`
- `POREP_SERVICE` (address granted `POREP_SERVICE_ROLE` in each `Validator` at initialization)
- optionally `OPERATOR_ADDR` (granted `SPRegistry.OPERATOR_ROLE` during deployment)

### Deploy

```bash
cp .env.example .env

# devnet example (uses RPC_TEST / PRIVATE_KEY_TEST from .env)
just devnet_deploy

# calibnet example
just calibnet_deploy
```

The deployment script:

- deploys upgradeable proxies for `PoRepMarket`, `SPRegistry`, `ValidatorFactory`, `Client`, `SLIOracle`, `SLIScorer`
- deploys `Validator` implementation + beacon (inside `ValidatorFactory.initialize`)
- wires circular dependencies:
  - `PoRepMarket.setClientSmartContract(Client)`
  - `ValidatorFactory.initialize2(..., poRepMarket, spRegistry)`
  - `SPRegistry.initialize2(poRepMarket)`
- writes a deployment artifact JSON under `deployments/<network>/` and updates `latest.json`

### Upgrade (UUPS proxies)

To upgrade one proxy implementation:

1. Set:
   - `UPGRADE_CONTRACT_NAME` (e.g. `Client`, `PoRepMarket`, `SPRegistry`, `SLIOracle`, `SLIScorer`, `ValidatorFactory`)
   - `UPGRADE_CALLDATA` (optional; defaults to empty)
2. Run:

```bash
just upgrade
```

`script/Upgrade.s.sol` prevents no-op upgrades by comparing a code hash of the deployed artifact vs the new build.

## Running the off-chain services (local dev)

These services are in sibling repos in this workspace. The exact integration points are:

- `filecoin-oracle-service` updates **`SLIOracle.setSLI()`** and marks terminations for **`Client.claimsTerminatedEarly()`**
- `provider-sample-url-finder` discovers **retrieval endpoints** and can run **BMS bandwidth tests** for endpoints
- `bandwidth-measurement-system` provides the bandwidth testing infrastructure (scheduler + workers)

### `filecoin-oracle-service` (SLI + termination tracking)

Key env vars (from its `.env.example`):

- `ORACLE_CONTRACT_ADDRESS`: deployed `SLIOracle` proxy address
- `SLA_ALLOCATOR_CONTRACT_ADDRESS`: (naming in that repo) contract address used to list providers; in this system, provider listing typically comes from `SPRegistry`
- `CLIENT_CONTRACT_ADDRESS`: deployed `Client` proxy address (for termination marking flows)
- `RPC_URL`, `CHAIN_ID`, `WALLET_PRIVATE_KEY`
- `CDP_SERVICE_URL`: upstream metrics provider
- `TRIGGER_SLI_JOB_INTERVAL_CRON`, `TRIGGER_CLAIMS_TRACKING_JOB_INTERVAL_CRON`
- `JOB_TRIGGER_AUTH_TOKEN`, `APP_PORT`

Typical workflow:

```bash
# in filecoin-oracle-service
npm ci
npm run build
npm run start
```

This service schedules cron tasks that:

- fetch SLI metrics off-chain
- multicall `SLIOracle.setSLI(provider, slis)` for all providers

### `provider-sample-url-finder` (Random Piece Availability / URL Finder)

What it does:

- discovers SP HTTP retrieval endpoints via `cid.contact` (peer ID lookup)
- samples piece CIDs from DMOB DB (random sampling)
- checks retrievability (HEAD requests), stores a working URL + retrievability %
- schedules bandwidth tests via BMS and stores results

Key runtime dependencies:

- Postgres (for its own state)
- DMOB Postgres (read-only deal/piece source)
- Optional BMS URL for bandwidth testing

Run:

```bash
# in provider-sample-url-finder/url_finder
cargo run --bin url_finder
```

### `bandwidth-measurement-system` (BMS)

Run locally with Docker:

```bash
# in bandwidth-measurement-system
cp .env.example .env

# create shared storage symlink (see BMS README)
ln -s "$PWD" /tmp/bms

docker compose up -d rabbitmq
docker compose up -d
```

Workers can be started manually (or scaled by the scheduler in local mode).

## Operational notes and failure modes

### SLI freshness window

`SLIScorer` rejects attestations older than 1 month (in epochs). If the oracle service is down, settlements can fail with:

- “no attestation” / “attestation expired”

### Settlement cadence

`Validator` enforces a minimum interval between settlements (default: 1 month). If you’re testing with shorter windows, use:

- `Validator.setMinEpochsBetweenSettlements(minEpochs)` (admin-only)

### Data size mismatch

If `Client.isDataSizeMatching(dealId)` returns false, settlements fail. Common causes:

- claims expired
- claims terminated early (should be marked via `claimsTerminatedEarly`)
- allocations/claims were never recorded (client never called `Client.transfer` for the deal)

### Provider capacity accounting

`SPRegistry` reserves capacity in two phases:

- **pendingBytes**: reserved at matchmaking/proposal time
- **committedBytes**: committed at `PoRepMarket.completeDeal()`

If deals are rejected, PoRepMarket releases pending capacity.
If deals terminate, PoRepMarket releases committed capacity.

### Auto-approve deals

If an SP sets `pricePerSectorPerMonth`, `SPRegistry.getProviderForDeal()` may auto-accept if the deal price meets/exceeds it. If price is 0, deals will require explicit `acceptDeal`.

## Useful reference links (in-repo)

- `README.md`: overview + architecture diagram
- `justfile`: canonical commands
- `script/Deploy.s.sol`: deployment wiring
- `src/PoRepMarket.sol`: deal API and state transitions
- `src/SPRegistry.sol`: provider matching and capacity rules
- `src/Validator.sol`: payment gating logic

