# GetClaims Gas Check

Short runbook for repeating the V1 `GetClaims` gas check.

## What It Tests

`getclaims-gas-check.sh` pulls real Filecoin mainnet claims with
`Filecoin.StateGetClaims`, filters them to `32 GiB`, then calls the deployed
`DealInspector.getClaimsForProvider(provider, claimIds)` with explicit gas.

Default target:

```text
provider: 2639429
piece size: 34359738368 bytes
claim counts: 1498 1550 1600 1650 1686 1687
gas limits: 20B and 30B
inspector: 0x89C9552Ba6C01c4a7792054f233fd12e6747EC02
```

## Run

```bash
./getclaims-gas-check.sh
```

Output is written to:

```text
getclaims-gas-check-run.csv
```

## Try Another Case

```bash
PROVIDER=2846602 COUNTS="1498 1686 2000" ./getclaims-gas-check.sh
```

Useful overrides:

```text
RPC_URL=...
PROVIDER=...
COUNTS="1498 1600"
GAS_LIMITS="20000000000 30000000000"
OUT=my-run.csv
```

## Current Finding

The strengthened mainnet check proved:

```text
1498 unique 32 GiB claims: OK with 20B gas
1686 unique 32 GiB claims: OK with 30B gas
1687 unique 32 GiB claims: out of gas through DealInspector
```

Use `1498 claims / 46.8125 TiB` as the tested V1 floor. Do not use the older
`2700`-claim extrapolation as the client-facing max.

Detailed report:

```text
getclaims-gas-limit-results.md
```
