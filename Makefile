SHELL := /bin/bash

# Dependency order: each package builds after the ones it uses.
PACKAGES := CurveMath XMPPCore XippiStore OMEMO XippiCalls XippiSession
PKG ?=
FILTER ?=
CONFIGURATION ?= Debug
# Extra xcodebuild arguments, e.g. CODE_SIGNING_ALLOWED=NO on CI runners without a team.
XCODEBUILD_FLAGS ?= -allowProvisioningUpdates -allowProvisioningDeviceRegistration

XCODEBUILD := xcodebuild -project Xippi.xcodeproj -scheme Xippi -configuration $(CONFIGURATION) -destination 'platform=macOS' $(XCODEBUILD_FLAGS)

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
build: ## Build the app (CONFIGURATION=Debug or Release)
	$(XCODEBUILD) build

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

.PHONY: build-tests
build-tests: ## Build the app and its UI tests without running them
	$(XCODEBUILD) build-for-testing

.PHONY: test-app
test-app: ## App unit tests, hosted by the app on an empty database in memory: results in test-results/
	rm -rf test-results/XippiTests.xcresult
	mkdir -p test-results
	$(XCODEBUILD) test -only-testing:XippiTests -resultBundlePath test-results/XippiTests.xcresult

.PHONY: test-ui
test-ui: ## UI tests
	$(XCODEBUILD) test -only-testing:XippiUITests

.PHONY: test-perf
test-perf: ## UI performance tests in the Performance configuration (needs UI automation)
	xcodebuild -project Xippi.xcodeproj -scheme "Xippi Performance" -destination 'platform=macOS' -allowProvisioningUpdates test

.PHONY: lint
lint: ## swift format in strict mode, no fixed toolbar ids, and the App Store text
	swift format lint --strict -r Packages App AppTests AppUITests scripts/screenshots
	python3 scripts/store_text.py fastlane/metadata scripts/screenshots/scenes.json
	@# A fixed id is for a toolbar the user customises: SwiftUI moving items between the
	@# toolbar's sections can add one before removing it, and AppKit stops the app.
	@if grep -rn 'ToolbarItem(id:' App --include='*.swift'; then \
		echo "ToolbarItem(id:) found: give toolbar items no id"; exit 1; \
	fi
	@# #selector(X.perform(_:)) resolves to NSObject's performSelector:, which reads the
	@# sender as a selector: the action never runs.
	@if grep -rn -E '@objc.*func perform\(' App --include='*.swift'; then \
		echo "@objc func perform( found: name the action something else"; exit 1; \
	fi

.PHONY: test-scripts
test-scripts: ## Tests of the release, App Store text and screenshot scripts
	python3 -m unittest discover -s scripts/tests

.PHONY: screenshots
screenshots: ## App Store screenshots into fastlane/screenshots/en-US (2 min; the app opens and takes the keyboard 6 times: hands off)
	$(MAKE) build CONFIGURATION=Debug
	python3 scripts/screenshots/shoot.py

.PHONY: release
release: ## Build and upload the release a v* tag names, and submit a plain one for review (CI)
	bundle exec fastlane tag

.PHONY: release-notes
release-notes: ## The release notes TAG=vX.Y.Z would get (needs OPENAI_API_KEY)
	python3 scripts/release.py notes $(TAG)

.PHONY: cover
cover: ## Package tests with coverage and results: coverage/ and test-results/
	FILTER='$(FILTER)' scripts/cover.sh $(or $(PKG),$(PACKAGES))

.PHONY: test-summary
test-summary: ## Markdown summary of the last cover run's test results
	@python3 scripts/test-summary.py test-results $(or $(PKG),$(PACKAGES))

.PHONY: clean
clean: ## Remove build and test output
	rm -rf Packages/*/.build Packages/*/.swiftpm coverage test-results DerivedData
	$(XCODEBUILD) -quiet clean
