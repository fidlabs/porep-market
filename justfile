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
    just typecheck-deployment
    just test-deployment-ts

typecheck-deployment:
    npx tsc --noEmit

test-deployment-ts:
    node --test script/*.test.ts

deploy network *args:
    node script/deployment.ts deploy {{ network }} {{ args }}

finalize-deploy network:
    node script/deployment.ts finalize-deploy {{ network }}

deploy-missing network:
    node script/deployment.ts deploy-missing {{ network }}

upgrade network target *targets:
    node script/deployment.ts upgrade {{ network }} {{ target }} {{ targets }}

finalize-upgrade network:
    node script/deployment.ts finalize-upgrade {{ network }}

verify network:
    node script/deployment.ts verify-sources {{ network }}

check-live network:
    node script/deployment.ts check-live {{ network }}

# CI equivalent check
check: fmt-check lint test deployment-tests check-coverage build check-abis
    @echo "All checks passed."

pre-push: fmt-check lint test deployment-tests check-coverage check-abis
    @echo "Ready to push."

fix: fmt lint test
    @echo "Fixed and validated."
