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

.PHONY: all build app run stop install test smoke check check-swift-testing fmt lint icon dev-cert reset-permissions logs clean

all: app

build:
	swift build -c $(CONFIG) --product $(APP_NAME)

app: build
	scripts/bundle.sh "$(CONFIG)" "$(APP)" "$(BUNDLE_ID)" "$(VERSION)" "$(BUILD_NUMBER)" "$(SIGN_IDENTITY)"

run: app stop
	open "$(APP)"

stop:
	-@pkill -x $(APP_NAME) 2>/dev/null; true

# Release build installed to ~/Applications (a stable place for daily use and launch at login).
install:
	$(MAKE) app CONFIG=release APP="$(HOME)/Applications/$(APP_NAME).app"
	@echo "Installed ~/Applications/$(APP_NAME).app — open it from there."

# Unit, contract and integration tests (Tests/SlatedTests).
test:
	swift run SlatedTests $(FILTER)

# End-to-end: the real app binary against temporary homes and fixture configs (Tests/Smoke).
smoke:
	Tests/Smoke/run.sh

# Everything automated. Run before every commit.
check: test smoke

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

logs:
	log stream --level debug --style compact --predicate 'subsystem == "$(BUNDLE_ID)"'

clean:
	rm -rf .build build
