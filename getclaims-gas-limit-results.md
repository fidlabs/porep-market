# GetClaims Gas Limit Results

Date: 2026-05-27

Worktree:
`/Users/mmach/git/1_neti/1_filecoin/2_porep_market/.worktrees/throwaway-getclaims-gas-probe`

Replicable checker:
`./getclaims-gas-check.sh`

## Result

Estimate: the `46 TiB` / `1498`-claim V1 deal shape is below the current
Filecoin mainnet EVM gas limit for the real VerifReg `GetClaims` path tested
through the deployed `DealInspector`.

Proof status: strengthened from `UNKNOWN_UNIQUE_CLAIMS` to
`MAINNET_UNIQUE_1498_HELPER_CALL_OK`.

I measured `1498` distinct live mainnet claim IDs for provider `2639429`; all
selected claims are `32 GiB`. The deployed `DealInspector.getClaimsForProvider`
call succeeds with explicit `20B` and `30B` gas on `eth_call`.

This still is not an exact `Validator.validatePayment -> Client.isDataSizeMatching`
measurement. GLIF rejects top-level `eth_call` / `eth_estimateGas` with
`from=<validator contract>` as `SysErrSenderInvalid`, so I could not directly
call the production `Client.isDataSizeMatching(...)` path from the validator
contract address.

Client-facing answer:

- `46 TiB` is exactly `1472 * 32 GiB`.
- `1498 * 32 GiB` is `46.8125 TiB`.
- Real unique `1498`-claim `eth_call` succeeds under explicit `20B` gas.
- Real unique `1600`-claim and `1650`-claim `eth_call`s also succeed under
  explicit `20B` gas.
- With explicit `30B` gas, the deployed helper succeeds through `1686` unique
  32 GiB claims and fails at `1687` claims.
- `1686 * 32 GiB = 52.6875 TiB`.

So the practical estimate is:

```text
1498 claims / 46.8125 TiB: directly tested through deployed DealInspector with
real unique mainnet 32 GiB claims and explicit 20B gas.

Strict reportable tested floor: 1498 claims / 46.8125 TiB.
Helper-tested upper point: 1686 claims / 52.6875 TiB succeeds with 30B gas.
Helper failure point: 1687 claims / 52.71875 TiB fails through DealInspector.
```

Do not use the previous `2700`-claim extrapolation as a client-facing maximum.
The stronger mainnet unique-call evidence says `1498` is a tested floor, while
the deployed helper's full-array return path fails around `1687`.

The production `Client.isDataSizeMatching(...)` path may support more than
`1686` claims because it returns only `bool`; `DealInspector` returns
`(claimIds, claims)` and therefore pays extra ABI return-encoding and memory
cost. I did not prove that extra headroom.

## Network

- RPC: `https://api.node.glif.io/rpc/v1`
- Chain ID: `314`
- Latest block checked: `6052348`
- Observed EVM block gas limit: `30,000,000,000`
- Selected safety threshold: `20,000,000,000`
- Mainnet `Client`: `0x4B099b9eCa7d3872Fa8F9B72b913119B4F08c5ED`
- Mainnet `PoRepMarket`: `0xBD669aBd1188F52e82aF114E17aCE2842DCc0Eb4`
- Existing `DealInspector`: `0x89C9552Ba6C01c4a7792054f233fd12e6747EC02`
- New probe deployment: none

## Measurement Summary

Raw data:
`getclaims-gas-limit-data.csv`

Live mainnet unique-deal points:

| deal | provider | claims | bytes | gas |
|---:|---:|---:|---:|---:|
| 1 | 2639429 | 44 | 1477469798400 | 428295897 |
| 8 | 187709 | 11 | 343598432256 | 124781322 |
| 9 | 1222595 | 17 | 524019564544 | 185735205 |
| 10 | 8240 | 11 | 311386177536 | 121309090 |
| 11 | 187709 | 11 | 311386177536 | 126114477 |
| 12 | 2639429 | 11 | 343598432256 | 137522501 |
| 15 | 2846602 | 11 | 343598432256 | 86945261 |
| 17 | 187709 | 44 | 1477469798400 | 390398695 |
| 18 | 2639429 | 208 | 7112600059904 | 1636600745 |
| 21 | 8240 | 208 | 7112600059904 | 478218475 |
| 22 | 2846602 | 208 | 7112600059904 | 1436260948 |

Repeated-claim stress through real mainnet VerifReg:

| claims | gas |
|---:|---:|
| 1 | 20039590 |
| 10 | 76160510 |
| 50 | 325690833 |
| 100 | 637167637 |
| 250 | 1580005837 |
| 500 | 3146826221 |
| 750 | 4702093708 |
| 1000 | 6277641721 |
| 1250 | 7836178301 |
| 1498 | 9380195327 |

Real unique 32 GiB provider-claim `eth_call` through deployed
`DealInspector.getClaimsForProvider(2639429, ids)`:

| claims | explicit gas | result |
|---:|---:|---|
| 1498 | 20B | OK |
| 1550 | 20B | OK |
| 1600 | 20B | OK |
| 1650 | 20B | OK |
| 1700 | 20B | out of gas |
| 1498 | 30B | OK |
| 1600 | 30B | OK |
| 1680 | 30B | OK |
| 1686 | 30B | OK |
| 1687 | 30B | out of gas |

## Fit

Repeated-claim stress fit:

```text
gas ~= 14,264,020 + 6,256,121 * claim_count
1498 claims ~= 9.386B gas
20B threshold ~= 3194 claims ~= 99.8125 TiB
30B limit ~= 4793 claims ~= 149.78125 TiB
```

Conservative live-deal fit, excluding deal 21 as a low-gas outlier:

```text
gas ~= 55,411,615 + 7,152,514 * claim_count
1498 claims ~= 10.770B gas
20B threshold ~= 2788 claims ~= 87.125 TiB
30B limit ~= 4186 claims ~= 130.8125 TiB
```

Old extrapolated estimate, superseded by the unique-claim `eth_call` pass:

```text
estimated max safe V1 claim count: about 2700
estimated safe V1 deal size at 32 GiB per claim: 84.375 TiB
```

Current client-facing number:

```text
tested safe floor: 1498 claims = 46.8125 TiB
tested helper success point: 1686 claims = 52.6875 TiB
tested helper failure point: 1687 claims = 52.71875 TiB
```

## Dominant Cost

The dominant cost is the VerifReg `GetClaims` call and returned-claim handling.
The deployed `DealInspector` measurements do not split actor-call gas from CBOR
decode gas, because no stage probe was deployed.

The non-dominant costs are:

- storage array read in `Client.isDataSizeMatching`: one stored `uint64` per
  allocation ID
- CBOR request encode: provider plus claim ID array
- local active-size loop: one returned claim size add plus terminated/expired
  checks per claim

Those are linear in claim count but much smaller than the measured
multi-million-gas-per-claim `GetClaims` slope.

## Exact Commands Used

Initialize submodules and compile throwaway probes:

```bash
git submodule update --init --recursive
forge build --build-info --sizes
```

Read current mainnet gas limit:

```bash
cast block-number --rpc-url https://api.node.glif.io/rpc/v1
cast block latest --rpc-url https://api.node.glif.io/rpc/v1
```

Read live deal list:

```bash
cast call \
  --rpc-url https://api.node.glif.io/rpc/v1 \
  0xBD669aBd1188F52e82aF114E17aCE2842DCc0Eb4 \
  "getDeals()((uint256,address,uint64,(uint16,uint16,uint16,uint8),(uint256,uint256,uint32),address,uint8,uint256,uint256,string)[])"
```

Read allocation IDs and count them:

```bash
cast call \
  --rpc-url https://api.node.glif.io/rpc/v1 \
  0x4B099b9eCa7d3872Fa8F9B72b913119B4F08c5ED \
  "getClientAllocationIdsPerDeal(uint256)(uint64[])" \
  <dealId>
```

Estimate deployed `DealInspector.getClaims(dealId)`:

```bash
cast estimate \
  --rpc-url https://api.node.glif.io/rpc/v1 \
  0x89C9552Ba6C01c4a7792054f233fd12e6747EC02 \
  "getClaims(uint256)" \
  <dealId>
```

Estimate repeated-claim stress:

```bash
ids=$(yes 124645105 | head -n 1498 | paste -sd, -)
cast estimate \
  --rpc-url https://api.node.glif.io/rpc/v1 \
  0x89C9552Ba6C01c4a7792054f233fd12e6747EC02 \
  "getClaimsForProvider(uint64,uint64[])" \
  2639429 \
  "[$ids]"
```

Pull real provider claim IDs and run a unique-claim `eth_call` with explicit
gas:

```bash
./getclaims-gas-check.sh
```

The script defaults to the exact latest strengthened run:

```text
RPC_URL=https://api.node.glif.io/rpc/v1
INSPECTOR=0x89C9552Ba6C01c4a7792054f233fd12e6747EC02
PROVIDER=2639429
PIECE_SIZE_BYTES=34359738368
COUNTS="1498 1550 1600 1650 1686 1687"
GAS_LIMITS="20000000000 30000000000"
MAX_CLAIMS=5000
OUT=getclaims-gas-check-run.csv
```

Example for a different provider or case:

```bash
PROVIDER=2846602 COUNTS="1498 1686 2000" GAS_LIMITS="20000000000 30000000000" ./getclaims-gas-check.sh
```

Attempted exact production estimate:

```bash
cast estimate \
  --rpc-url https://api.node.glif.io/rpc/v1 \
  --from <dealValidator> \
  0x4B099b9eCa7d3872Fa8F9B72b913119B4F08c5ED \
  "isDataSizeMatching(uint256)" \
  <dealId>
```

That failed on GLIF with:

```text
SysErrSenderInvalid(1): pre-validation failed: Send not from valid sender
```

So exact `Client.isDataSizeMatching(...)` production gas is not included in the
CSV.

## Local Boost Note

The local Boost checkout has a practical route to generate many unique claims:

```bash
cd /Users/mmach/git/1_neti/1_filecoin/boost
just up
just deploy
PIECE_COUNT=1498 bash scripts/porep-market/scenarios/multiple_pieces_verified.sh
```

That route is useful for claim-count scaling, but not for proving 32 GiB piece
realism as-is. The devnet uses 8 MiB sectors and the scenario generates tiny
random CAR inputs before CommP padding.
