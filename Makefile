# Slated — build, bundle, sign and run the menu-bar app. Needs only the Xcode Command Line Tools.

APP_NAME      := Slated
BUNDLE_ID     ?= io.github.shobhit-aida.slated
VERSION       ?= 0.1.0
BUILD_NUMBER  ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
CONFIG        ?= debug
DEV_CERT      := Slated Dev
# Sign with the local "Slated Dev" certificate when it exists (see `make dev-cert`), else ad-hoc.
SIGN_IDENTITY ?= $(shell security find-identity -p codesigning 2>/dev/null | grep -q '"$(DEV_CERT)"' && echo "$(DEV_CERT)" || echo "-")
APP           := build/$(APP_NAME).app

JSC           := /System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc

.PHONY: all build app run stop install uninstall test smoke test-install test-scripts snapshots check check-swift-testing fmt lint icon dev-cert reset-permissions logs log-summary syslog clean fixtures check-fixtures fuzz linux-test linux-test-all

all: app

build:
	swift build -c $(CONFIG) --product $(APP_NAME)

app: build
	scripts/bundle.sh "$(CONFIG)" "$(APP)" "$(BUNDLE_ID)" "$(VERSION)" "$(BUILD_NUMBER)" "$(SIGN_IDENTITY)"

# Debug build installed to ~/Applications and relaunched (same place as `make install`, so there is
# only ever one Slated.app and the Accessibility permission carries over).
run:
	./install.sh --debug

stop:
	-@pkill -x $(APP_NAME) 2>/dev/null; true

# Release build installed to ~/Applications and relaunched. Run it as often as you like.
install:
	./install.sh

uninstall:
	./install.sh --uninstall

# Unit, contract and integration tests (Tests/SlatedTests).
test:
	swift run SlatedTests $(FILTER)

# End-to-end: the real app binary against temporary homes and fixture configs (Tests/Smoke).
smoke:
	Tests/Smoke/run.sh

# Installs into a throwaway folder, launches, reinstalls, uninstalls (Tests/Installer). Launches the
# app briefly, so it isn't part of `check`.
test-install:
	Tests/Installer/run.sh

# The installer's helper scripts against stand-ins (scripts/restore-caps-lock.py and a fake hidutil).
test-scripts:
	/usr/bin/python3 -I Tests/Installer/test_restore_caps_lock.py

# Renders every settings pane, onboarding step and the menu bar panel (light and dark) to
# build/ui-snapshots, with contact sheets. Takes about two minutes.
snapshots:
	swift run SlatedUISnapshots build/ui-snapshots

# Golden test vectors for the Linux (GNOME) engine: SlatedCore's results on curated inputs, written to
# fixtures/ by Sources/SlatedFixtures. Regenerate after changing SlatedCore, review the diff, commit it.
fixtures:
	swift run SlatedFixtures fixtures

# Fails when fixtures/ is stale (or the generator isn't deterministic).
check-fixtures:
	scripts/check-fixtures.sh

# Differential fuzzing: ~120,000 seeded random inputs through SlatedCore and the JavaScript port,
# compared like the golden vectors (Sources/SlatedFixtures/Fuzz.swift). Not part of `check`; run it
# after changing either engine. `make fuzz SEED=7` tries other inputs. Needs Node.
fuzz:
	@dir="$$(mktemp -d "$${TMPDIR:-/tmp}/slated-fuzz.XXXXXX")"; \
	swift build --product SlatedFixtures >/dev/null && \
	SLATED_FUZZ=$(or $(SEED),1) "$$(swift build --show-bin-path)/SlatedFixtures" "$$dir" >/dev/null && \
	node linux/tests/run.mjs --fixtures "$$dir"; status=$$?; rm -rf "$$dir"; exit $$status

# The JavaScript engine (linux/gnome-extension/lib/core) against every golden vector, plus its own
# tests: on Node when installed, else macOS's JavaScriptCore. `make linux-test FILTER=frames`.
linux-test:
	@if command -v node >/dev/null 2>&1; then node linux/tests/run.mjs $(FILTER); \
	elif [ -x "$(JSC)" ]; then "$(JSC)" -m linux/tests/run.mjs -- $(FILTER); \
	else echo "linux-test needs Node or JavaScriptCore (jsc)" >&2; exit 1; fi

# The same on every runtime available here (Node, GJS, JavaScriptCore), checking that failures fail.
linux-test-all:
	linux/tests/run-all.sh $(FILTER)

# Everything automated. Run before every commit.
check: test smoke test-scripts check-fixtures linux-test release-build

# The installer builds with -O; the optimizer has crashed on code debug builds accept.
release-build:
	swift build -c release --product $(APP_NAME)

# Reports whether Swift Testing is usable yet (it needs Xcode).
check-swift-testing:
	scripts/check-swift-testing.sh

icon:
	swift scripts/make-icon.swift Resources/AppIcon.icns

fmt:
	swift format --in-place --recursive Sources Tests Package.swift

lint:
	swift format lint --recursive Sources Tests

# One-time: create a self-signed code-signing certificate so macOS keeps Slated's permissions
# across rebuilds.
dev-cert:
	scripts/create-dev-cert.sh "$(DEV_CERT)"

# Forget Slated's Accessibility permission (macOS will ask again on next launch).
reset-permissions:
	tccutil reset Accessibility $(BUNDLE_ID)

# Slated's event log (~/Library/Logs/Slated/slated.log), live. See scripts/logs.py --help for filters.
logs:
	scripts/logs.py --follow

log-summary:
	scripts/logs.py --summary

# The same events in the unified log (as Console.app shows them).
syslog:
	log stream --level debug --style compact --predicate 'subsystem == "$(BUNDLE_ID)"'

clean:
	rm -rf .build build

# --- Linux: the GNOME Shell extension (see docs/LINUX.md) ---------------------------------------------
.PHONY: linux-pack linux-install linux-uninstall linux-test-prefs linux-test-prefs-gjs linux-test-gtk linux-test-installer linux-test-extension

# The extension zip in build/linux, stamped with build-info.json (works without GNOME too).
linux-pack:
	linux/install.sh --pack-only

# Pack, install and enable for the current user; then log out and back in (or linux/install.sh --nested).
linux-install:
	linux/install.sh

linux-uninstall:
	linux/install.sh --uninstall

# The preferences: unit tests, and the UI on mock GTK/libadwaita built from GNOME 46's introspection data.
linux-test-prefs:
	node linux/tests/prefs/run.mjs
	node linux/tests/prefs/ui.mjs

# The same unit tests under GJS, GNOME's JavaScript engine.
linux-test-prefs-gjs:
	gjs -m linux/tests/prefs/run.mjs

# The preferences window on the real GTK and libadwaita (needs gjs, gir1.2-adw-1, xvfb, dbus).
linux-test-gtk:
	linux/tests/prefs/run-gtk.sh

# linux/install.sh against stand-ins, and scripts/logs.py's log locations.
linux-test-installer:
	linux/tests/installer/run.sh
	linux/tests/logs/run.sh

# The extension's runtime (lib/platform) against a simulated GNOME Shell, plus a syntax check of every file.
linux-test-extension:
	linux/tests/extension/run.sh
