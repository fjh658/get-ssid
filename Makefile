# -----------------------------------------------------------------------------
# Makefile — universal build + Homebrew packaging for get-ssid (Swift)
# -----------------------------------------------------------------------------

SHELL := /bin/bash

BIN_NAME ?= get-ssid
SRC_FILE := get_ssid.swift
VERSION := $(strip $(shell sed -nE 's/^[[:space:]]*private[[:space:]]+static[[:space:]]+let[[:space:]]+version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$(SRC_FILE)" | head -n1))
ifeq ($(VERSION),)
$(error Failed to parse version from $(SRC_FILE))
endif

BUILD_DIR := .build/macos-universal
MODULE_CACHE_DIR := $(BUILD_DIR)/module-cache
SLICE_X86 := $(BUILD_DIR)/$(BIN_NAME)-x86_64
SLICE_ARM := $(BUILD_DIR)/$(BIN_NAME)-arm64

DIST_DIR := dist
DIST_STAGE_DIR := $(BUILD_DIR)/dist-stage
DIST_TARBALL := $(DIST_DIR)/$(BIN_NAME)-$(VERSION)-macos-universal.tar.gz

FORMULA_TEMPLATE := Formula/get-ssid.rb.tmpl
FORMULA_FILE := Formula/get-ssid.rb

.PHONY: all x86_64 arm64 universal package formula clean help test

all: universal

x86_64: | $(BUILD_DIR)
	@echo "🔨 Building x86_64 slice (min 10.13)…"
	@xcrun swiftc -parse-as-library -O \
		-module-cache-path "$(MODULE_CACHE_DIR)" \
		-target x86_64-apple-macos10.13 \
		-o "$(SLICE_X86)" "$(SRC_FILE)"
	@echo "→ $(SLICE_X86)"

arm64: | $(BUILD_DIR)
	@echo "🔨 Building arm64 slice (min 11.0)…"
	@xcrun swiftc -parse-as-library -O \
		-module-cache-path "$(MODULE_CACHE_DIR)" \
		-target arm64-apple-macos11.0 \
		-o "$(SLICE_ARM)" "$(SRC_FILE)"
	@echo "→ $(SLICE_ARM)"

$(BUILD_DIR):
	@mkdir -p "$(BUILD_DIR)" "$(MODULE_CACHE_DIR)"

./$(BIN_NAME): x86_64 arm64
	@echo "📦 Merging into universal binary ./$(BIN_NAME)…"
	@lipo -create -output "./$(BIN_NAME)" "$(SLICE_X86)" "$(SLICE_ARM)"
	@chmod +x "./$(BIN_NAME)"
	@echo "✅ Done: ./$(BIN_NAME)"

universal: ./$(BIN_NAME)

$(DIST_DIR):
	@mkdir -p "$(DIST_DIR)"

package: $(DIST_TARBALL) formula

$(DIST_TARBALL): ./$(BIN_NAME) | $(DIST_DIR)
	@rm -rf "$(DIST_STAGE_DIR)"
	@mkdir -p "$(DIST_STAGE_DIR)"
	@cp "./$(BIN_NAME)" "$(DIST_STAGE_DIR)/$(BIN_NAME)"
	@tar -C "$(DIST_STAGE_DIR)" -czf "$@" "$(BIN_NAME)"
	@echo "📦 Packaged: $(abspath $(DIST_TARBALL))"
	@shasum -a 256 "$(DIST_TARBALL)"

formula: $(FORMULA_FILE)

$(FORMULA_FILE): $(FORMULA_TEMPLATE) $(DIST_TARBALL)
	@sha="$$(shasum -a 256 "$(DIST_TARBALL)" | awk '{print $$1}')"; \
	sed -e 's|__VERSION__|$(VERSION)|g' -e "s|__SHA256__|$$sha|g" "$(FORMULA_TEMPLATE)" > "$(FORMULA_FILE)"
	@echo "🧪 Updated: $(abspath $(FORMULA_FILE))"

clean:
	@rm -f "./$(BIN_NAME)"
	@rm -f "$(SLICE_X86)" "$(SLICE_ARM)"
	@rm -rf "$(BUILD_DIR)"
	@echo "🧹 Clean complete"

TEST_BIN := /tmp/get-ssid-tests

test:
	@echo "── Unit tests ──"
	@xcrun swiftc -parse-as-library -DTESTING \
		-target arm64-apple-macos11.0 \
		-o "$(TEST_BIN)" "$(SRC_FILE)" tests/get_ssid_tests.swift
	@"$(TEST_BIN)"
	@echo ""
	@echo "── Shell integration tests ──"
	@$(MAKE) --no-print-directory universal
	@bash tests/test_cli.sh "./$(BIN_NAME)"

help:
	@echo "Targets:"
	@echo "  make universal                Build universal binary ./$(BIN_NAME)"
	@echo "  make test                     Run unit tests + integration tests"
	@echo "  make package                  Build dist tarball + refresh Formula/get-ssid.rb"
	@echo "  make formula                  Refresh Formula/get-ssid.rb from template + tarball sha256"
	@echo "  make clean                    Remove build artifacts (keeps dist/)"
