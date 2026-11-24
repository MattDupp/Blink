# BlinkMonitor - every task of the project, one command each.   Run `make` to list them.

DATA        ?= $(CURDIR)/data
MODELS      ?= $(CURDIR)/models
INSTALL_DIR ?= $(HOME)/Applications
MODEL       := $(MODELS)/EyeNet.mlmodelc

# The Python tools and the tests that need real recordings find them through these
# (training/paths.py): `make evaluate DATA=<folder>` judges recordings kept elsewhere.
export BLINK_DATA   := $(DATA)
export BLINK_MODELS := $(MODELS)

# How the apps are signed. "-" is an ad hoc signature: no certificate, good for the Mac
# that built it. With an Apple Developer ID, name the certificate, and the keychain
# profile that holds the notarization password (docs/DEVELOPMENT.md, "Signing"):
#   make dmg SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=blink-notary
SIGN_IDENTITY  ?= -
NOTARY_PROFILE ?=
export SIGN_IDENTITY NOTARY_PROFILE

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

# Where the app is when it was dragged out of the disk image (make dmg), as opposed to
# installed by `make monitor`. It has another file name there: "Blink Monitor", as people
# read it in Finder.
DRAGGED := "/Applications/Blink Monitor.app" "$(HOME)/Applications/Blink Monitor.app"

# Recipes run in bash, and a failing command fails its recipe even when its output is filtered.
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

.DEFAULT_GOAL := help
.PHONY: help doctor demo demo-tour build test lint format recorder train improve evaluate compare replay monitor monitor-app one-copy uninstall dmg snapshots icon clean

help:  ## List the tasks
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-12s %s\n", $$1, $$2}'

doctor:  ## Check that this Mac has what the project needs
	@scripts/doctor.sh

# --- Try it first --------------------------------------------------------------------------

demo: App/AppIcon.icns  ## Try the whole app in a minute: made-up blinks, no camera, nothing recorded
	@scripts/doctor.sh mac swift
	DEMO=1 scripts/bundle.sh BlinkMonitor
	@pkill -x -f "$(CURDIR)/build/BlinkMonitorDemo.app/Contents/MacOS/BlinkMonitor" 2>/dev/null; true
	open build/BlinkMonitorDemo.app
	@echo "The demo is running: look for the eye marked 'demo' in the menu bar. Quit it from its panel."
	@echo "To use it on your own eyes:  make monitor"

# For filming: the demo opens its main screens one after the other, in a fixed order
# (Tour.swift). Start the screen recording first. PACE is the seconds of one beat.
# (Set for this target only: as a variable of the whole file it also reached `make replay`,
# whose PACE=1 means something else, and every replay ran at the camera's pace.)
demo-tour: PACE ?= 4
demo-tour: App/AppIcon.icns  ## The demo walks through its own screens, to be filmed (PACE=4 seconds a beat)
	@scripts/doctor.sh mac swift
	DEMO=1 scripts/bundle.sh BlinkMonitor
	@pkill -x -f "$(CURDIR)/build/BlinkMonitorDemo.app/Contents/MacOS/BlinkMonitor" 2>/dev/null; true
	open build/BlinkMonitorDemo.app --args --tour --tour-pace=$(PACE)
	@echo "The tour starts in three seconds and takes 19 beats of $(PACE) seconds. Afterwards, quit the demo from its panel."

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

# --- The Python route: the lab ------------------------------------------------------------
#
# To USE the app, `make monitor` (further down) is all it takes: it sets itself up the
# first time, recording your eyes and training your model itself. The steps here are the
# same training in Python, where it can be taken apart and measured.

recorder:  ## Lab 1. Record sessions into data/raw (opens the app's setup, saving there)
	mkdir -p -m 700 "$(DATA)" "$(DATA)/raw"
	@$(MAKE) --no-print-directory monitor OPEN_ARGS='"--sessions-dir=$(DATA)/raw" --open=setup'
	@echo "The setup window records into $(DATA)/raw. Two sessions or more, in different light, then:  make train"

train:  ## Lab 2. Train the model in Python on data/, and convert it to Core ML
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

# A long job on the graphics processor: run it alone, never beside another training
# (docs/LESSONS.md, number 8). COMPARE_SEEDS=7,8,9 is the default; each seed more adds
# three trainings a side.
compare:  ## Measure the app's own trainer against the Python route: same pictures, same splits
	@scripts/doctor.sh mac swift uv
	swift build -c release --product BlinkTrain $(QUIET)
	cd training && uv run python compare.py jobs
	.build/release/BlinkTrain training/out/compare/jobs.json training/out/compare/swift.json
	cd training && uv run python compare.py python && uv run python compare.py score

# make monitor WHOLE_FRAMES=1: until the app is next started, the captures of its Live View
# window also keep the whole camera picture of every frame, in data/replay. That is a film
# of your face, on your disk only: it is what `make replay` needs, and nothing else does.
ifdef WHOLE_FRAMES
WHOLE_FRAMES_ARGS := "--whole-frames-dir=$(DATA)/replay"
endif

# OPEN_ARGS: more launch options (`make recorder` passes its own).
monitor: one-copy monitor-app  ## Install the menu-bar app in ~/Applications and start it (it sets itself up the first time)
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
	open "$(INSTALL_DIR)/BlinkMonitor.app" --args "--capture-dir=$(DATA)/live" $(WHOLE_FRAMES_ARGS) $(OPEN_ARGS)
	@echo "Blink is running: look for the eye in the menu bar, at the top right of the screen."
	@echo "macOS asks for the camera the first time, and again after each rebuild."
	@# Which model it uses: the one trained in the app when there is one, else the one built in.
	@if [ -f "$(HOME)/Library/Application Support/BlinkMonitor/model/eyenet.weights" ] && [ -d "$(MODEL)" ]; then \
		echo "Note: a model trained in the app is in use, not $(MODEL). Settings > Your Model deletes it."; fi
	@# (No comma in this sentence: inside make's "if" function a comma starts the "else"
	@# part, which make then ran as a command whenever WHOLE_FRAMES was not set.)
	@$(if $(WHOLE_FRAMES),echo "WHOLE FRAMES: the captures of the Live View window also keep the whole camera picture in $(DATA)/replay.")

# PACE=1: hand the frames over at the camera's pace, and report what each stage costs.
replay: $(MODEL)  ## Judge the eye finding: run the captures that kept whole frames through it again, and count
	@scripts/doctor.sh mac swift
	swift build -c release --product BlinkReplay $(QUIET)
	.build/release/BlinkReplay "$(DATA)/replay" "--model=$(MODEL)" $(if $(PACE),--pace) $(REPLAY_ARGS)

# The Python route's model is built into the app when there is one. Without it the app
# still works: it trains its own.
monitor-app: App/AppIcon.icns
	@scripts/doctor.sh mac swift
	scripts/bundle.sh BlinkMonitor $(wildcard $(MODEL))

# ONE INSTALLED COPY AT A TIME. A copy dragged out of the disk image and the copy this
# Makefile installs are the same app to macOS (one identifier). With both, Notification
# Centre can lose the icon, Start at Login may open either, and only one of them runs.
# Checked before anything is built or stopped, and nothing is removed without being asked.
one-copy:
	@for app in $(DRAGGED); do \
		[ -e "$$app" ] || continue; \
		echo "Blink is already installed from the disk image: $$app"; \
		echo "macOS should know one copy only. Quit that one and move it to the Trash,"; \
		echo "then run 'make monitor' again. (Or: make uninstall, which removes every copy.)"; \
		exit 1; \
	done

uninstall:  ## Remove the installed app, wherever it is (your history and recordings are kept)
	@pkill -x BlinkMonitor 2>/dev/null; true
	@# Both kinds of copy: the one `make monitor` installs, and one dragged out of the disk image.
	@for app in "$(INSTALL_DIR)/BlinkMonitor.app" $(DRAGGED); do \
		[ -e "$$app" ] || continue; \
		$(LSREGISTER) -u "$$app" >/dev/null 2>&1; \
		if [ -w "$$(dirname "$$app")" ] && rm -rf "$$app"; then \
			echo "Removed $$app"; \
		else \
			echo "Not removed: $$app   (drag it to the Trash in Finder: it asks for an administrator)"; \
		fi; \
	done
	@echo "Still on this Mac, and yours to delete:"
	@echo "  your history, and the recordings and model the app made:  ~/Library/Application Support/BlinkMonitor"
	@echo "  the Python route's recordings:  $(DATA)   and its model: $(MODELS)"
	@echo "If you switched on Start at Login, remove it in System Settings > General > Login Items."

$(MODEL):
	@echo "No model from the Python route yet ($(MODEL)). Record your eyes (make recorder), then: make train"
	@exit 1

# --- The installer ----------------------------------------------------------------------

# One file for people who only want to try the app: they open it and drag the app into
# Applications. It never holds a model (scripts/dmg.sh explains, and checks).
dmg: App/AppIcon.icns  ## Build the installer: a disk image to open and drag from (build/)
	@scripts/doctor.sh mac swift uv
	@scripts/dmg.sh

# --- Extras -----------------------------------------------------------------------------

snapshots: App/AppIcon.icns  ## Render every screen of the app with made-up data (build/screens)
	@# English numbers and a 24-hour clock in the pictures, whatever this Mac is set to: the
	@# README once showed "1 912".
	scripts/bundle.sh BlinkMonitor
	build/BlinkMonitor.app/Contents/MacOS/BlinkMonitor "--snapshots=$(CURDIR)/build/screens" -AppleLocale en_GB -AppleLanguages "(en)" >/dev/null
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
