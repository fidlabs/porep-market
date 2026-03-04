# DEMO V1

## Setup

```bash
export RPC_URL=https://api.calibration.node.glif.io/rpc/v1
export PRIVATE_KEY=<your-private-key>
```

## Deploy

```bash
just demo-deploy
```

Deploys all contracts to Calibration testnet and verifies them on Blockscout.
Takes 15+ minutes due to FEVM null rounds.

## Run

```bash
just demo
```

## Deployed Contracts (Calibration)

- [SPRegistry](https://filecoin-testnet.blockscout.com/address/0xDC6E84c0880DC0fECF2B266640A66820Dd04A36f)
- [SLIOracle](https://filecoin-testnet.blockscout.com/address/0x8e0470a38BeA28a2d7b53130fdA4FAc890d496b7)
- [SLIScorer](https://filecoin-testnet.blockscout.com/address/0x4EAFcCc382943ED6548D038Ba51be8eA2ca43530)
- [PoRepMarket](https://filecoin-testnet.blockscout.com/address/0xb3D9Fa24621acC87165486d546F58Cd26F4B1D85)
- [DemoHelper](https://filecoin-testnet.blockscout.com/address/0x8Ad97095116b9D340Aa2214D93C7888d795a2699)
