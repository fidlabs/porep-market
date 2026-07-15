# PoRep Market task runner
# Run `just` to see all available commands

set dotenv-load := true

fmt:
    forge fmt

fmt-check:
    forge fmt --check

lint:
    solhint 'src/**/*.sol' 'test/**/*.sol' 'script/**/*.sol' --max-warnings 0

test:
    forge test -vvv

build:
    forge build --build-info --sizes src

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

deployment-tests:
    bash test/scripts/deployment-commands.sh
    bash test/scripts/deployment-finality.sh
    bash test/scripts/deployment-live.sh
    bash test/scripts/deployment-flow.sh

deploy network *args:
    ./script/deployment.sh deploy {{ network }} {{ args }}

finalize-deploy network:
    ./script/deployment.sh finalize-deploy {{ network }}

upgrade network target *targets:
    ./script/deployment.sh upgrade {{ network }} {{ target }} {{ targets }}

finalize-upgrade network:
    ./script/deployment.sh finalize-upgrade {{ network }}

verify network:
    ./script/deployment.sh verify {{ network }}

# CI equivalent check
check: fmt-check lint test deployment-tests check-coverage build check-abis
    @echo "All checks passed."

pre-push: fmt-check lint test deployment-tests check-coverage check-abis
    @echo "Ready to push."

fix: fmt lint test
    @echo "Fixed and validated."
