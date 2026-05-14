# Filecoin Pay Retrieval Operator

Small Filecoin Pay operator for paid retrievals.

The contract creates a Filecoin Pay rail for a payer/payee pair, locks a fixed USDFC payment amount, and lets an admin either pay the retrieval or cancel it. It does not implement market logic, SLAs, provider registries, or streaming payments.

## Contract Flow

1. Payer deposits funds into Filecoin Pay.
2. Payer approves this operator for the payment token with fixed lockup allowance.
3. Admin calls `createRail(payer, payee, fixedLockupAmount)`.
4. Admin calls `modifyRailPayment(railId)` to pay the fixed amount and finalize the rail, or `terminateRail(railId)` to cancel and release the lockup.

The operator uses zero payment rate and zero lockup period. Only fixed lockup allowance is required.

## Development

```sh
forge test -vvv
forge build --build-info --sizes
forge fmt
```

Or use the task runner:

```sh
just test
just build
just fmt
```

## Deploy

Set these variables for the target network:

```sh
PRIVATE_KEY=<deployer_private_key>
RPC_URL=<network_rpc_url>
FILECOIN_PAY=<filecoin_pay_contract>
TOKEN=<payment_token_contract>
```

Then run:

```sh
just deploy
```

Network helpers map the network-specific variables from `.env`:

```sh
just calibnet_deploy
just mainnet_deploy_dry
just mainnet_deploy
```

Broadcast deployments write `deployments/<network>/retrieval-operator-latest.json` and a block-numbered copy. Dry runs do not write deployment artifacts. The manifest contains:

```json
{
  "OperatorFactory": {
    "proxy": "0x...",
    "impl": "0x..."
  },
  "Operator": {
    "beacon": "0x...",
    "impl": "0x..."
  },
  "FilecoinPay": "0x...",
  "Token": "0x..."
}
```

## Upgrade

Upgrade the operator implementation behind the factory beacon:

```sh
UPGRADE_CONTRACT_NAME=Operator just upgrade
```

Upgrade the factory UUPS proxy:

```sh
UPGRADE_CONTRACT_NAME=OperatorFactory UPGRADE_CALLDATA=0x just upgrade
```

When upgrading an older factory proxy that does not yet have Filecoin Pay configuration, pass initializer calldata:

```sh
UPGRADE_CONTRACT_NAME=OperatorFactory \
UPGRADE_CALLDATA=$(cast calldata "setFilecoinPayConfig(address,address)" "$FILECOIN_PAY" "$TOKEN") \
just upgrade
```

Mainnet upgrades use the same names:

```sh
UPGRADE_CONTRACT_NAME=Operator just mainnet_upgrade
UPGRADE_CONTRACT_NAME=OperatorFactory UPGRADE_CALLDATA=0x just mainnet_upgrade
```

## Verify

Blockscout verification reads `deployments/<network>/retrieval-operator-latest.json`.

```sh
just verify-calibnet
just audit-calibnet
just verify-mainnet
just audit-mainnet
```
