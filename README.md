# DEMO V1

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast)
- [just](https://github.com/casey/just#installation) task runner
- A funded wallet on Filecoin Calibration testnet

## Installation

```bash
git clone <repo-url>
cd porep-market

# Initialize all git submodules (forge-std, openzeppelin, filecoin-solidity)
git submodule update --init --recursive

# Verify the build compiles
forge build
```

If you already cloned but see errors about missing files (e.g. `filecoin-solidity/...`), run:

```bash
git submodule update --init --recursive
```

## Setup

```bash
cp .env.example .env
```

Edit `.env` and fill in:

```
RPC_URL=https://api.calibration.node.glif.io/rpc/v1
PRIVATE_KEY=<your-private-key>
```

Or export directly:

```bash
export RPC_URL=https://api.calibration.node.glif.io/rpc/v1
export PRIVATE_KEY=<your-private-key>
```

## Deploy

```bash
just demo-deploy
```

Deploys all contracts (SPRegistry, SLIOracle, SLIScorer, PoRepMarket, DemoHelper) to Calibration testnet and verifies them on Blockscout. Takes 15+ minutes due to FEVM null rounds.

## Run

```bash
just demo
```

Runs the full demo flow:
1. Register two SPs with different capabilities and SLI attestations
2. Score comparison showing which SP meets quality thresholds
3. Propose a deal (SP matched by SLI requirements)
4. Reject deal (unhappy path, capacity released)
5. Propose deal with auto-approve (price meets SP floor)
6. Complete deal (capacity committed)

## Deployed Contracts (Calibration)

- [SPRegistry](https://filecoin-testnet.blockscout.com/address/0xDC6E84c0880DC0fECF2B266640A66820Dd04A36f)
- [SLIOracle](https://filecoin-testnet.blockscout.com/address/0x8e0470a38BeA28a2d7b53130fdA4FAc890d496b7)
- [SLIScorer](https://filecoin-testnet.blockscout.com/address/0x4EAFcCc382943ED6548D038Ba51be8eA2ca43530)
- [PoRepMarket](https://filecoin-testnet.blockscout.com/address/0xb3D9Fa24621acC87165486d546F58Cd26F4B1D85)
- [DemoHelper](https://filecoin-testnet.blockscout.com/address/0x8Ad97095116b9D340Aa2214D93C7888d795a2699)

## Troubleshooting

**"Source file not found" errors (filecoin-solidity, openzeppelin, forge-std)**

Git submodules are not initialized. Run:
```bash
git submodule update --init --recursive
```

**"too many pending messages" or transaction timeouts**

FEVM Calibration has null rounds. The deploy scripts use `--slow` to avoid mempool congestion. Wait and retry.

**"RPC_URL is not set" / "PRIVATE_KEY is not set"**

Export the environment variables or use `.env` file (the justfile loads `.env` automatically).
