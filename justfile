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

devnet_deploy:
	forge clean && forge build
	forge script script/Deploy.s.sol --gas-estimate-multiplier 100000 --disable-block-gas-limit -vvvv --broadcast --rpc-url $RPC_TEST --private-key $PRIVATE_KEY_TEST

# CI equivalent check
check: fmt-check lint test check-coverage build check-abis
    @echo "All checks passed."

pre-push: fmt-check lint test
    @echo "Ready to push."

fix: fmt lint test
    @echo "Fixed and validated."

# Verify contracts on Blockscout (Calibnet)
verify-calibnet:
    @bash script/verify-blockscout.sh Calibnet

# Deploy demo contracts (takes 15+ min on Calibration)
demo-deploy:
    @bash script/demo/demo-deploy.sh

# Run the demo (requires demo-deploy first)
demo:
    @bash script/demo/demo.sh
