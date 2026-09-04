include .env

check-configs: 
	@echo "l1_file: ${l1_file} l2_file ${l2_file}"
	bun lzConfigCheck.cjs ${l1_file} ${l2_file}

# --- harness E3 (2026-09-04): `forge test` exits 0 when a selector matches ZERO tests ("No tests found in project!"),
# so a check whose tests are commented out reports green. require_tests counts the selection via --list --json and
# refuses on 0. (Plain --list output matches `grep -c test` on the path line, so that guard would pass vacuously.)
define require_tests
	@forge test --list --json --mp $(1) 2>/dev/null | python3 -c 'import json,sys; raw=sys.stdin.read().strip(); ok=raw.startswith("{") and raw.endswith("}"); d=json.loads(raw) if ok else {}; n=sum(len(f) for c in d.values() for f in c.values()); print("E3: %d test(s) selected in $(1)%s" % (n, "" if ok else " (no parseable list from forge: compile error?)")); sys.exit(0 if n > 0 else 1)' || { echo "E3: NO TESTS selected in $(1) - refusing to report green"; exit 1; }
endef

checkL1:
	@echo "Setting environment variable LIVE_DEPLOY_READ_FILE_NAME to $(file)"
	$(call require_tests,test/LiveDeploy.t.sol)
	@export LIVE_DEPLOY_READ_FILE_NAME=$(file) && forge test --mp test/LiveDeploy.t.sol --fork-url=${L1_RPC_URL}

checkL2:
	@echo "Setting environment variable LIVE_DEPLOY_READ_FILE_NAME to $(file)"
	$(call require_tests,test/LiveDeploy.t.sol)
	@export LIVE_DEPLOY_READ_FILE_NAME=$(file) && forge test --mp test/LiveDeploy.t.sol --fork-url=${L2_RPC_URL}

deployL1:
	@echo "Setting environment variable LIVE_DEPLOY_READ_FILE_NAME to $(file)"
	cp ./deployment-config/out-template.json ./deployment-config/out.json
	@export LIVE_DEPLOY_READ_FILE_NAME=$(file) && forge script script/deploy/deployAll.s.sol --sig "run(string)" $(file) --fork-url=${L1_RPC_URL}

deployL2:
	@echo "Setting environment variable LIVE_DEPLOY_READ_FILE_NAME to $(file)"
	cp ./deployment-config/out-template.json ./deployment-config/out.json
	@export LIVE_DEPLOY_READ_FILE_NAME=$(file) && forge script script/deploy/deployAll.s.sol --sig "run(string)" $(file) --fork-url=${L2_RPC_URL}

live-deployL1: checkL1   # harness E3: a broadcast runs only after a non-empty, passing fork check
	@echo "Setting environment variable LIVE_DEPLOY_READ_FILE_NAME to $(file)"
	cp ./deployment-config/out-template.json ./deployment-config/out.json
	@export LIVE_DEPLOY_READ_FILE_NAME=$(file) && forge script script/deploy/deployAll.s.sol --sig "run(string)" $(file) --fork-url=${L1_RPC_URL} --private-key=$(PRIVATE_KEY) --broadcast --slow --verify
	mv ./deployment-config/out.json ./deployment-config/outL1.json

live-deployL2: checkL2   # harness E3: a broadcast runs only after a non-empty, passing fork check
	@echo "Setting environment variable LIVE_DEPLOY_READ_FILE_NAME to $(file)"
	cp ./deployment-config/out-template.json ./deployment-config/out.json
	@export LIVE_DEPLOY_READ_FILE_NAME=$(file) && forge script script/deploy/deployAll.s.sol --sig "run(string)" $(file) --fork-url=${L2_RPC_URL} --private-key=$(PRIVATE_KEY) --broadcast --slow --verify
	mv ./deployment-config/out.json ./deployment-config/outL2.json

prettier:
	prettier --write '**/*.{md,yml,yaml,ts,js}'

solhint:
	solhint -w 0 'src/**/*.sol'
    
slither: 
	slither src

prepare:
	husky

deploy-createx-l1: 
	forge script script/DeployCustomCreatex.s.sol --rpc-url ${L1_RPC_URL} --private-key ${PRIVATE_KEY} --slow --no-metadata

deploy-createx-l2:
	forge script script/DeployCustomCreatex.s.sol --rpc-url ${L2_RPC_URL} --private-key ${PRIVATE_KEY} --slow --no-metadata

check-configs: 
	bun lzConfigCheck.cjs

chain1 := $(shell cast chain-id -r $(L1_RPC_URL))
chain2 := $(shell cast chain-id -r $(L2_RPC_URL))
symbol := $(shell cat deployment-config/$(fileL1) | jq -r ".boringVault.boringVaultSymbol")
post-deploy:
	mkdir -p ./nucleus-deployments/$(symbol)
	mv ./deployment-config/outL1.json ./nucleus-deployments/$(symbol)/L1Out.json
	mv ./deployment-config/outL2.json ./nucleus-deployments/$(symbol)/L2Out.json
	cp ./broadcast/deployAll.s.sol/$(chain1)/run-latest.json ./nucleus-deployments/$(symbol)/L1.json
	cp ./broadcast/deployAll.s.sol/$(chain2)/run-latest.json ./nucleus-deployments/$(symbol)/L2.json
	cp ./deployment-config/$(fileL1) ./nucleus-deployments/$(symbol)/L1Config.json
	cp ./deployment-config/$(fileL2) ./nucleus-deployments/$(symbol)/L2Config.json
	cd nucleus-deployments && git checkout -b $(symbol) && git add . && git commit -m "$(symbol) deployment" && git push origin $(symbol) && git checkout main
