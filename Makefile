SHELL := /bin/bash

# Dependency order: each package builds after the ones it uses.
PACKAGES := CurveMath XMPPCore XippiStore OMEMO XippiCalls XippiSession
PKG ?=
FILTER ?=

XCODEBUILD := xcodebuild -project Xippi.xcodeproj -scheme Xippi -configuration Debug -destination 'platform=macOS'

.DEFAULT_GOAL := help

.PHONY: help
help: ## List the targets
	@grep -hE '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-18s %s\n", $$1, $$2}'

CERTS := dev/certs/test-ca.pem dev/certs/test-ca.key dev/certs/server.pem dev/certs/server.key

$(CERTS) &:
	dev/make-certs.sh

.PHONY: up
up: $(CERTS) ## Start the test servers and wait until they answer
	docker compose up -d --wait

.PHONY: down
down: ## Stop the test servers and drop their data
	docker compose down -v

.PHONY: logs
logs: ## Follow the test servers' logs
	docker compose logs -f

.PHONY: certs
certs: ## New test CA and server certificate in dev/certs (restart the servers after)
	dev/make-certs.sh

.PHONY: build
build: ## Build the app (Debug)
	$(XCODEBUILD) -allowProvisioningUpdates build

.PHONY: test
test: ## Package tests: PKG=<Package> for one package, FILTER=<Suite> to narrow
	@set -e; for p in $(or $(PKG),$(PACKAGES)); do \
		echo "==> $$p"; \
		swift test --package-path "Packages/$$p" $(if $(FILTER),--filter '$(FILTER)'); \
	done

.PHONY: test-integration
test-integration: ## Integration tests against the test servers (make up first)
	XIPPI_INTEGRATION=1 swift test --package-path Packages/XMPPCore --filter '$(or $(FILTER),IntegrationTests|NegotiationRecordingTests)'
	XIPPI_INTEGRATION=1 swift test --package-path Packages/XippiSession --filter '$(or $(FILTER),XMPPIntegrationTests)'

.PHONY: test-integration-disruptive
test-integration-disruptive: ## Integration tests that restart the test servers (nothing else may use them meanwhile)
	XIPPI_INTEGRATION=1 XIPPI_INTEGRATION_DISRUPTIVE=1 swift test --package-path Packages/XMPPCore --filter '$(or $(FILTER),ServerRestartIntegrationTests)'
	XIPPI_INTEGRATION=1 XIPPI_INTEGRATION_DISRUPTIVE=1 swift test --package-path Packages/XippiSession --filter '$(or $(FILTER),XMPPIntegrationTests.DisruptiveIntegrationTests)'

.PHONY: test-ui
test-ui: ## UI tests
	$(XCODEBUILD) -allowProvisioningUpdates test -only-testing:XippiUITests

.PHONY: test-perf
test-perf: ## UI performance tests in the Performance configuration (needs UI automation)
	xcodebuild -project Xippi.xcodeproj -scheme "Xippi Performance" -destination 'platform=macOS' -allowProvisioningUpdates test

.PHONY: lint
lint: ## swift format in strict mode
	swift format lint --strict -r Packages App AppUITests

.PHONY: cover
cover: ## Package tests with code coverage, writes coverage/<Package>.json
	@set -e; mkdir -p coverage; for p in $(or $(PKG),$(PACKAGES)); do \
		echo "==> $$p"; \
		swift test --package-path "Packages/$$p" --enable-code-coverage $(if $(FILTER),--filter '$(FILTER)'); \
		cp "$$(swift test --package-path "Packages/$$p" --show-codecov-path)" "coverage/$$p.json"; \
	done

.PHONY: clean
clean: ## Remove build and test output
	rm -rf Packages/*/.build Packages/*/.swiftpm coverage DerivedData
	$(XCODEBUILD) -quiet clean
