.DEFAULT_GOAL := help

# Per-repo settings, git-ignored. Make is not a shell: write DEVELOPMENT_TEAM=ABCDE12345
# with no quotes, or the quote characters end up inside the value and signing fails.
-include .env
export

SCHEME := Localfox
PROJECT := Localfox.xcodeproj
CONFIG := Debug
DERIVED := build
HELPER_LABEL := net.kandera.Localfox.helper

help: ## Show available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-18s %s\n", $$1, $$2}'

gen: caddy cloudflared ## Regenerate the Xcode project from project.yml
	xcodegen generate --quiet

build: ## Build the SwiftPM core
	swift build

test: ## Run the core test suite
	swift test

detect: ## Detect services in a project directory: make detect DIR=~/Projects/wishfox
	@swift build 2>/dev/null && ./.build/debug/localfox-run detect $(DIR)

env: ## Print the resolved login shell environment
	@swift build 2>/dev/null && ./.build/debug/localfox-run env

caddy: ## Fetch and verify the pinned Caddy binary into Vendor/
	@Tools/fetch-caddy.sh

cloudflared: ## Fetch and verify the pinned cloudflared binary into Vendor/
	@Tools/fetch-cloudflared.sh

app: gen ## Build the menu bar app
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) build | tail -5

run: app ## Build and launch the menu bar app
	@pkill -x Localfox || true
	@open $(DERIVED)/Build/Products/$(CONFIG)/Localfox.app

# The daemon plist is sealed into the bundle, so launchd keeps serving the old
# one until the service is unregistered. Printing first shows what it actually has.
reinstall-helper: ## Show launchd's view of the helper, then clear the registration
	@launchctl print system/$(HELPER_LABEL) 2>&1 | head -20 || true
	@echo "--- booting out $(HELPER_LABEL) ---"
	@sudo launchctl bootout system/$(HELPER_LABEL) 2>&1 || true
	@echo "--- relaunch Localfox from /Applications to re-register ---"

snapshot: app ## Render the popover, dashboard and preferences to snapshots/
	@mkdir -p snapshots
	@$(DERIVED)/Build/Products/$(CONFIG)/Localfox.app/Contents/MacOS/Localfox --snapshot snapshots/popover.png
	@$(DERIVED)/Build/Products/$(CONFIG)/Localfox.app/Contents/MacOS/Localfox --snapshot snapshots/popover-demo.png --demo
	@$(DERIVED)/Build/Products/$(CONFIG)/Localfox.app/Contents/MacOS/Localfox --snapshot snapshots/popover-demo-light.png --demo --light
	@$(DERIVED)/Build/Products/$(CONFIG)/Localfox.app/Contents/MacOS/Localfox --snapshot snapshots/popover-hover.png --demo --hover
	@$(DERIVED)/Build/Products/$(CONFIG)/Localfox.app/Contents/MacOS/Localfox --snapshot-dashboard snapshots/dashboard.png
	@$(DERIVED)/Build/Products/$(CONFIG)/Localfox.app/Contents/MacOS/Localfox --snapshot-prefs snapshots/preferences.png
	@$(DERIVED)/Build/Products/$(CONFIG)/Localfox.app/Contents/MacOS/Localfox --snapshot snapshots/popover-light.png --light
	@$(DERIVED)/Build/Products/$(CONFIG)/Localfox.app/Contents/MacOS/Localfox --snapshot-dashboard snapshots/dashboard-light.png --light
	@$(DERIVED)/Build/Products/$(CONFIG)/Localfox.app/Contents/MacOS/Localfox --snapshot-prefs snapshots/preferences-light.png --light

archive: ## Build a Release app and DMG into dist/ (DEVELOPMENT_TEAM=... to sign)
	@Tools/archive.sh $(VERSION)

lint: ## Run SwiftLint
	swiftlint lint --quiet

clean: ## Remove build artefacts
	rm -rf .build $(DERIVED) $(PROJECT) snapshots dist

.PHONY: help gen build test detect env caddy cloudflared app run reinstall-helper snapshot archive lint clean
