SHELL := /bin/bash

CONTROL_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BIN_DIR := $(CONTROL_DIR)/bin
GO_PATH := $(CONTROL_DIR)/.complytime/gopath
GO_CACHE := $(CONTROL_DIR)/.complytime/go-cache
COMPLYCTL_VERSION := v1.0.0
OPA_PROVIDER_VERSION := v0.2.1
COMPLYPACK_VERSION := v0.0.8

.PHONY: install-tools test scan-fixture clean

install-tools:
	@mkdir -p "$(BIN_DIR)" "$(GO_PATH)" "$(GO_CACHE)"
	@GOBIN="$(BIN_DIR)" GOPATH="$(GO_PATH)" GOCACHE="$(GO_CACHE)" GOTOOLCHAIN=auto \
		go install github.com/complytime/complyctl/cmd/complyctl@$(COMPLYCTL_VERSION)
	@GOBIN="$(BIN_DIR)" GOPATH="$(GO_PATH)" GOCACHE="$(GO_CACHE)" GOTOOLCHAIN=auto \
		go install github.com/complytime/complytime-providers/cmd/opa-provider@$(OPA_PROVIDER_VERSION)
	@GOBIN="$(BIN_DIR)" GOPATH="$(GO_PATH)" GOCACHE="$(GO_CACHE)" GOTOOLCHAIN=auto \
		go install github.com/complytime/complypack/cmd/complypack@$(COMPLYPACK_VERSION)
	@mv "$(BIN_DIR)/opa-provider" "$(BIN_DIR)/complyctl-provider-opa"
	@printf 'Installed pinned complyctl, OPA provider, and CompliPack under %s\n' "$(BIN_DIR)"

test:
	@bash tests/test-evaluation-log.sh
	@bash tests/test-normalizer.sh
	@bash tests/run-fixtures.sh
	@bash tests/test-complytime-fixture.sh

scan-fixture:
	@bash scripts/run-fixture-scans.sh

clean:
	@rm -rf "$(BIN_DIR)" "$(CONTROL_DIR)/.complytime"
	@printf 'Removed local WAF prototype build and scan outputs.\n'
