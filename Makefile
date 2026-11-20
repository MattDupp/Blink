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

# The known-harmless linker warnings of a Mac without Xcode (see scripts/bundle.sh).
QUIET := 2>&1 | { grep -v "ld: warning: search path" || true; }
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Recipes run in bash, and a failing command fails its recipe even when its output is filtered.
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

.DEFAULT_GOAL := help
.PHONY: help doctor demo build test lint format recorder train improve evaluate replay monitor monitor-app uninstall snapshots icon clean

help:  ## List the tasks
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-12s %s\n", $$1, $$2}'

doctor:  ## Check that this Mac has what the project needs
	@scripts/doctor.sh

# --- Try it first --------------------------------------------------------------------------

demo: App/AppIcon.icns  ## Try the whole app in a minute: made-up blinks, no camera, no model
	@scripts/doctor.sh mac swift
	DEMO=1 scripts/bundle.sh BlinkMonitor
	@pkill -x -f "$(CURDIR)/build/BlinkMonitorDemo.app/Contents/MacOS/BlinkMonitor" 2>/dev/null; true
	open build/BlinkMonitorDemo.app
	@echo "The demo is running: look for the eye marked 'demo' in the menu bar. Quit it from its panel."
	@echo "To use it on your own eyes:  make recorder"

# --- Checks -----------------------------------------------------------------------------

build:  ## Compile everything
	swift build -c release $(QUIET)

test:  ## Run the Swift and Python tests
	swift test $(SWIFT_TEST_FLAGS) $(QUIET)
	cd training && uv run pytest -q

lint:  ## Check the Python code's style
	cd training && uv run ruff check . ../scripts && uv run ruff format --check . ../scripts

format:  ## Reformat the Python code
	cd training && uv run ruff check --fix . ../scripts && uv run ruff format . ../scripts

# --- The four steps, in order -----------------------------------------------------------

recorder: App/AppIcon.icns  ## 1. Record labelled pictures of your eyes (opens the recorder)
	@scripts/doctor.sh mac swift
	scripts/bundle.sh BlinkRecorder
	mkdir -p -m 700 "$(DATA)" "$(DATA)/raw"
	open -n build/BlinkRecorder.app --args "--out=$(DATA)/raw"
	@echo "The recorder is open. Record 5 sessions in different light, then:  make train"

train:  ## 2. Train the model on your recordings and convert it to Core ML
	@scripts/doctor.sh uv
	cd training && uv run python train.py && uv run python convert.py
	@echo "Your model is ready. Next:  make monitor"

improve:  ## Teach the model your real blinks: label the captures you recorded, then train again
	@scripts/doctor.sh uv
	cd training && uv run python label_captures.py && uv run python train.py && uv run python convert.py
	@echo "The model has learned from your captures. Install it with:  make monitor"

evaluate:  ## Measure blink counting on your captures (models that never saw them)
	@scripts/doctor.sh uv
	cd training && uv run python evaluate.py

# make monitor WHOLE_FRAMES=1: until the app is next started, the captures of its Live View
# window also keep the whole camera picture of every frame, in data/replay. That is a film
# of your face, on your disk only: it is what `make replay` needs, and nothing else does.
ifdef WHOLE_FRAMES
WHOLE_FRAMES_ARGS := "--whole-frames-dir=$(DATA)/replay"
endif

monitor: monitor-app  ## 3. Install the menu-bar app in ~/Applications and start it
	@# Stop the copy that is running, if any, and wait for it to be gone.
	@# (The extra second lets macOS notice it has quit: opening the app too early fails with error -600.)
	@if pkill -x BlinkMonitor 2>/dev/null; then while pgrep -x BlinkMonitor >/dev/null; do sleep 0.2; done; sleep 1; fi
	mkdir -p "$(INSTALL_DIR)"
	mkdir -p -m 700 "$(DATA)" "$(DATA)/live" $(if $(WHOLE_FRAMES),"$(DATA)/replay")
	rm -rf "$(INSTALL_DIR)/BlinkMonitor.app"
	cp -R build/BlinkMonitor.app "$(INSTALL_DIR)/BlinkMonitor.app"
	@# Tell macOS which copy is THE app: the installed one, not the one in build/. Two
	@# copies under one identifier is how Notification Centre ends up with no icon to show.
	@$(LSREGISTER) -u "$(CURDIR)/build/BlinkMonitor.app" >/dev/null 2>&1; true
	@$(LSREGISTER) -f "$(INSTALL_DIR)/BlinkMonitor.app" >/dev/null 2>&1; true
	open "$(INSTALL_DIR)/BlinkMonitor.app" --args "--capture-dir=$(DATA)/live" $(WHOLE_FRAMES_ARGS)
	@echo "Blink Monitor is running: look for the eye in the menu bar, at the top right of the screen."
	@echo "macOS asks for the camera the first time, and again after each rebuild."
	@$(if $(WHOLE_FRAMES),echo "WHOLE FRAMES: the captures of the Live View window also keep the whole camera picture, in $(DATA)/replay.")

# PACE=1: hand the frames over at the camera's pace, and report what each stage costs.
replay: $(MODEL)  ## Judge the eye finding: run the captures that kept whole frames through it again, and count
	@scripts/doctor.sh mac swift
	swift build -c release --product BlinkReplay $(QUIET)
	.build/release/BlinkReplay "$(DATA)/replay" "--model=$(MODEL)" $(if $(PACE),--pace) $(REPLAY_ARGS)

monitor-app: $(MODEL) App/AppIcon.icns
	@scripts/doctor.sh mac swift
	scripts/bundle.sh BlinkMonitor $(MODEL)

uninstall:  ## Remove the installed app (your history and recordings are kept)
	@pkill -x BlinkMonitor 2>/dev/null; true
	@$(LSREGISTER) -u "$(INSTALL_DIR)/BlinkMonitor.app" >/dev/null 2>&1; true
	rm -rf "$(INSTALL_DIR)/BlinkMonitor.app"
	@echo "Removed. Still on this Mac, and yours to delete:"
	@echo "  your history:     ~/Library/Application Support/BlinkMonitor"
	@echo "  your recordings:  $(DATA)   and your model: $(CURDIR)/models"
	@echo "If you switched on Start at Login, remove it in System Settings > General > Login Items."

$(MODEL):
	@echo "No trained model yet ($(MODEL)). Record your eyes (make recorder), then: make train"
	@exit 1

# --- Extras -----------------------------------------------------------------------------

snapshots: App/AppIcon.icns  ## Render every screen of both apps with made-up data (build/screens)
	scripts/bundle.sh BlinkMonitor
	scripts/bundle.sh BlinkRecorder
	build/BlinkMonitor.app/Contents/MacOS/BlinkMonitor "--snapshots=$(CURDIR)/build/screens" >/dev/null
	build/BlinkRecorder.app/Contents/MacOS/BlinkRecorder "--snapshots=$(CURDIR)/build/screens" >/dev/null
	@# Every screen and state is rendered, to be looked at. Only the pictures the docs
	@# show are kept in the repository: those are copied to docs/img.
	@for name in $$(grep -ohE 'img/[a-z-]+-(light|dark)\.png' README.md docs/*.md | sort -u); do \
		cp "build/screens/$$(basename $$name)" "docs/img/$$(basename $$name)" && echo "docs/img/$$(basename $$name)"; \
	done
	@echo "Every screen is in build/screens; the ones listed above are the ones the docs show."

icon: App/AppIcon.icns  ## Draw the app icon (App/AppIcon.icns)

# The icon is drawn by code, so it is built like everything else instead of being stored.
App/AppIcon.icns: scripts/make-icon.swift
	swift scripts/make-icon.swift App/AppIcon.iconset
	iconutil -c icns App/AppIcon.iconset -o App/AppIcon.icns

clean:  ## Remove build products (never your data or model)
	rm -rf .build build
