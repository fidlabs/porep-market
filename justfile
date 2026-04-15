# PoRep Market task runner
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
    for f in $(find src -name '*.sol' ! -path "*/interfaces/*" ! -path "*/types/*" ! -path "*/libs/*"); do \
        name="$(basename "${f%.sol}")"; \
        jq .abi "out/$(basename "$f")/$name.json" > "abis/$name.json"; \
    done

check-abis:
    ./ci/check-abis.sh

coverage:
    ./coverage.sh

check-coverage:
    ./ci/check-full-coverage.sh

deploy flags='':
    forge script script/Deploy.s.sol:Deploy --gas-estimate-multiplier 100000 --disable-block-gas-limit -vvvv --broadcast --rpc-url $RPC_URL --private-key $PRIVATE_KEY {{flags}}

upgrade flags='':
    forge script script/Upgrade.s.sol:Upgrade --gas-estimate-multiplier 100000 --disable-block-gas-limit -vvvv --broadcast --rpc-url $RPC_URL --private-key $PRIVATE_KEY {{flags}}

devnet_deploy: clean build
	RPC_URL=$RPC_TEST PRIVATE_KEY=$PRIVATE_KEY_TEST just deploy 

calibnet_deploy: clean build
    RPC_URL=$RPC_CALIBNET \
    PRIVATE_KEY=$PRIVATE_KEY_CALIBNET \
    FILECOIN_PAY=$FILECOIN_PAY_CALIBNET \
    TERMINATION_ORACLE=$TERMINATION_ORACLE_CALIBNET \
    ORACLE=$ORACLE_CALIBNET \
    POREP_SERVICE=$POREP_SERVICE_CALIBNET \
    META_ALLOCATOR=$META_ALLOCATOR_CALIBNET \
    OPERATOR_ADDR=${OPERATOR_ADDR_CALIBNET:-} \
    just deploy --slow

devnet_upgrade: clean build
	RPC_URL=$RPC_TEST PRIVATE_KEY=$PRIVATE_KEY_TEST just upgrade

calibnet_upgrade: clean build
	RPC_URL=$RPC_CALIBNET PRIVATE_KEY=$PRIVATE_KEY_CALIBNET just upgrade --slow

# Full mainnet (production) deploy with 5-gate safety check (requires CONFIRM_MAINNET=yes).
mainnet_deploy: clean build
    ./script/preflight-mainnet.sh deploy
    RPC_URL=$RPC_MAINNET \
    PRIVATE_KEY=$PRIVATE_KEY_MAINNET \
    FILECOIN_PAY=$FILECOIN_PAY_MAINNET \
    TERMINATION_ORACLE=$TERMINATION_ORACLE_MAINNET \
    ORACLE=$ORACLE_MAINNET \
    POREP_SERVICE=$POREP_SERVICE_MAINNET \
    META_ALLOCATOR=$META_ALLOCATOR_MAINNET \
    OPERATOR_ADDR=${OPERATOR_ADDR_MAINNET:-} \
    just deploy --slow

# Mainnet deploy dry-run — preview addresses + gas estimates, no broadcast.
mainnet_deploy_dry: clean build
    ./script/preflight-mainnet.sh dry
    RPC_URL=$RPC_MAINNET \
    PRIVATE_KEY=$PRIVATE_KEY_MAINNET \
    FILECOIN_PAY=$FILECOIN_PAY_MAINNET \
    TERMINATION_ORACLE=$TERMINATION_ORACLE_MAINNET \
    ORACLE=$ORACLE_MAINNET \
    POREP_SERVICE=$POREP_SERVICE_MAINNET \
    META_ALLOCATOR=$META_ALLOCATOR_MAINNET \
    OPERATOR_ADDR=${OPERATOR_ADDR_MAINNET:-} \
    forge script script/Deploy.s.sol:Deploy \
        --gas-estimate-multiplier 100000 \
        --disable-block-gas-limit \
        -vvvv \
        --rpc-url $RPC_MAINNET

# Mainnet proxy upgrade (requires existing deployments/mainnet/latest.json).
mainnet_upgrade: clean build
    ./script/preflight-mainnet.sh upgrade
    RPC_URL=$RPC_MAINNET PRIVATE_KEY=$PRIVATE_KEY_MAINNET just upgrade --slow

# Blockscout contract verification
# Verify reads deployments/<net>/latest.json and works from any 
# fresh checkout of the deployment commit (no broadcast/artifacts needed).

verify-calibnet:
    ./script/verify-blockscout.sh verify 314159

verify-mainnet:
    ./script/verify-blockscout.sh verify 314

audit-calibnet:
    ./script/verify-blockscout.sh audit 314159

audit-mainnet:
    ./script/verify-blockscout.sh audit 314

verify-one chain addr name:
    ./script/verify-blockscout.sh verify-one {{chain}} {{addr}} {{name}}

# CI equivalent check
check: fmt-check lint test check-coverage build check-abis
    @echo "All checks passed."

pre-push: fmt-check lint test check-abis
    @echo "Ready to push."

fix: fmt lint test
    @echo "Fixed and validated."
