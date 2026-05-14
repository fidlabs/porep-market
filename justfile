# Filecoin Pay Retrieval Operator task runner
# Run `just` to see all available commands
set dotenv-load

fmt:
    forge fmt

fmt-check:
    forge fmt --check

lint:
    solhint 'src/**/*.sol' 'test/**/*.sol' 'script/**/*.sol' --max-warnings 0

test:
    forge test -vvv

build:
    forge build --build-info --sizes

clean:
    forge clean

gen-abis:
    forge build
    for f in $(find src -name '*.sol' ! -path "*/interfaces/*" ! -path "*/abstracts/*" ! -path "*/types/*" ! -path "*/libs/*"); do \
        name="$(basename "${f%.sol}")"; \
        jq .abi "out/$(basename "$f")/$name.json" > "abis/$name.json"; \
    done

check-abis:
    ./ci/check-abis.sh

coverage:
    ./coverage.sh

audit-calibnet:
    ./script/verify-blockscout.sh audit 314159

audit-mainnet:
    ./script/verify-blockscout.sh audit 314

verify-calibnet:
    ./script/verify-blockscout.sh verify 314159

verify-mainnet:
    CONFIRM_MAINNET=yes ./script/verify-blockscout.sh verify 314

verify-one chain address contract:
    ./script/verify-blockscout.sh verify-one {{chain}} {{address}} {{contract}}

deploy flags='':
    forge script script/Deploy.s.sol:Deploy --gas-estimate-multiplier 100000 --disable-block-gas-limit -vvvv --broadcast --rpc-url $RPC_URL --private-key $PRIVATE_KEY {{flags}}

upgrade flags='':
    forge script script/Upgrade.s.sol:Upgrade --gas-estimate-multiplier 100000 --disable-block-gas-limit -vvvv --broadcast --rpc-url $RPC_URL --private-key $PRIVATE_KEY {{flags}}

devnet_deploy: clean build
    RPC_URL=$RPC_TEST \
    PRIVATE_KEY=$PRIVATE_KEY_TEST \
    FILECOIN_PAY=$FILECOIN_PAY_TEST \
    TOKEN=$TOKEN_TEST \
    just deploy

calibnet_deploy: clean build
    RPC_URL=$RPC_CALIBNET \
    PRIVATE_KEY=$PRIVATE_KEY_CALIBNET \
    FILECOIN_PAY=$FILECOIN_PAY_CALIBNET \
    TOKEN=$TOKEN_CALIBNET \
    just deploy --slow

devnet_upgrade: clean build
	RPC_URL=$RPC_TEST PRIVATE_KEY=$PRIVATE_KEY_TEST just upgrade

calibnet_upgrade: clean build
	RPC_URL=$RPC_CALIBNET PRIVATE_KEY=$PRIVATE_KEY_CALIBNET just upgrade --slow

mainnet_deploy: clean build
    RPC_URL=$RPC_MAINNET \
    PRIVATE_KEY=$PRIVATE_KEY_MAINNET \
    FILECOIN_PAY=$FILECOIN_PAY_MAINNET \
    TOKEN=$TOKEN_MAINNET \
    just deploy --slow

# Mainnet deploy dry-run — preview addresses + gas estimates, no broadcast and no deployment artifacts.
mainnet_deploy_dry: clean build
    RPC_URL=$RPC_MAINNET \
    PRIVATE_KEY=$PRIVATE_KEY_MAINNET \
    FILECOIN_PAY=$FILECOIN_PAY_MAINNET \
    TOKEN=$TOKEN_MAINNET \
    forge script script/Deploy.s.sol:Deploy \
        --gas-estimate-multiplier 100000 \
        --disable-block-gas-limit \
        -vvvv \
        --rpc-url $RPC_MAINNET

# Mainnet upgrade (OperatorFactory UUPS or Operator beacon; requires deployments/mainnet/retrieval-operator-latest.json).
mainnet_upgrade: clean build
    RPC_URL=$RPC_MAINNET PRIVATE_KEY=$PRIVATE_KEY_MAINNET just upgrade --slow

# CI equivalent check
check: fmt-check lint test build check-abis
    @echo "All checks passed."

pre-push: fmt-check lint test check-abis
    @echo "Ready to push."

fix: fmt lint test
    @echo "Fixed and validated."
