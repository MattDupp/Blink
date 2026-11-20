# BlinkMonitor - every task of the project, one command each.   Run `make` to list them.

DATA        ?= $(CURDIR)/data
INSTALL_DIR ?= $(HOME)/Applications
MODEL       := models/EyeNet.mlmodelc

# With only Apple's Command Line Tools (no Xcode), the compiler has to be told where the
# testing macros live. With Xcode this is automatic and the flags stay empty.
CLT_TESTING := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
ifeq ($(shell xcode-select -p 2>/dev/null | grep -c 'Xcode'),0)
ifneq ($(wildcard $(CLT_TESTING)),)
SWIFT_TEST_FLAGS := -Xswiftc -plugin-path -Xswiftc $(CLT_TESTING)
endif
endif

.DEFAULT_GOAL := help
.PHONY: help build test lint format recorder train evaluate monitor monitor-app snapshots icon clean

help:  ## List the tasks
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-12s %s\n", $$1, $$2}'

# --- Checks -----------------------------------------------------------------------------

build:  ## Compile everything
	swift build -c release

test:  ## Run the Swift and Python tests
	swift test $(SWIFT_TEST_FLAGS)
	cd training && uv run pytest -q

lint:  ## Check the Python code's style
	cd training && uv run ruff check . ../scripts && uv run ruff format --check . ../scripts

format:  ## Reformat the Python code
	cd training && uv run ruff check --fix . ../scripts && uv run ruff format . ../scripts

# --- The four steps, in order -----------------------------------------------------------

recorder: App/AppIcon.icns  ## 1. Record labelled pictures of your eyes (opens the recorder)
	scripts/bundle.sh BlinkRecorder
	mkdir -p -m 700 "$(DATA)" "$(DATA)/raw"
	open -n build/BlinkRecorder.app --args "--out=$(DATA)/raw"

train:  ## 2. Train the model on your recordings and convert it to Core ML
	cd training && uv run python train.py && uv run python convert.py

evaluate:  ## 3. Measure blink counting on your captures (models that never saw them)
	cd training && uv run python evaluate.py

monitor: monitor-app  ## 4. Install the menu-bar app in ~/Applications and start it
	@# Stop the copy that is running, if any, and wait for it to be gone.
	@# (The extra second lets macOS notice it has quit: opening the app too early fails with error -600.)
	@if pkill -x BlinkMonitor 2>/dev/null; then while pgrep -x BlinkMonitor >/dev/null; do sleep 0.2; done; sleep 1; fi
	mkdir -p "$(INSTALL_DIR)"
	mkdir -p -m 700 "$(DATA)" "$(DATA)/live"
	rm -rf "$(INSTALL_DIR)/BlinkMonitor.app"
	cp -R build/BlinkMonitor.app "$(INSTALL_DIR)/BlinkMonitor.app"
	open "$(INSTALL_DIR)/BlinkMonitor.app" --args "--capture-dir=$(DATA)/live"
	@echo "Blink Monitor is running: look for the eye in the menu bar."

monitor-app: $(MODEL) App/AppIcon.icns
	scripts/bundle.sh BlinkMonitor $(MODEL)

$(MODEL):
	@echo "No trained model yet ($(MODEL)). Record your eyes (make recorder), then: make train"
	@exit 1

# --- Extras -----------------------------------------------------------------------------

snapshots: monitor-app  ## Render every screen to docs/img with made-up data
	build/BlinkMonitor.app/Contents/MacOS/BlinkMonitor "--snapshots=$(CURDIR)/docs/img"

icon: App/AppIcon.icns  ## Draw the app icon (App/AppIcon.icns)

# The icon is drawn by code, so it is built like everything else instead of being stored.
App/AppIcon.icns: scripts/make-icon.swift
	swift scripts/make-icon.swift App/AppIcon.iconset
	iconutil -c icns App/AppIcon.iconset -o App/AppIcon.icns

clean:  ## Remove build products (never your data or model)
	rm -rf .build build
