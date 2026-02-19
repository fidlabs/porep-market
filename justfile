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
