# Bonedust
#
# The Xcode project is generated, never hand-edited. `ios/project.yml` is the
# source of truth, so a target or build-setting change is a reviewable one-line
# diff instead of a 400-line pbxproj conflict.

SIM ?= platform=iOS Simulator,name=iPhone 17
CORE := ios/BonedustCore

.PHONY: all project test test-core test-app bench simulate constants golden content app \
	server-test server-golden server-load server-setup render team-id device sheet shapes clean

all: test

project:
	cd ios && xcodegen generate

# Simulation and economy suites. No simulator, about 30 seconds.
test-core:
	cd $(CORE) && swift test

# App-layer tests. Needs a simulator.
test-app: project
	xcodebuild test -project ios/Bonedust.xcodeproj -scheme Bonedust \
		-destination '$(SIM)' CODE_SIGNING_ALLOWED=NO

test: test-core server-golden

app: project
	xcodebuild build -project ios/Bonedust.xcodeproj -scheme Bonedust \
		-destination '$(SIM)' CODE_SIGNING_ALLOWED=NO

# Worst realistic frame for the simulation: a fast air-blower swipe. §9 wants
# 60 fps on an iPhone 12, and this is the half of that budget we control.
bench:
	cd $(CORE) && swift build -c release && ./.build/release/bonedust-tool bench

# §9's balance target: win rate per installment tier for a scripted average player.
RUNS ?= 10000
simulate:
	cd $(CORE) && swift build -c release && \
		./.build/release/bonedust-tool simulate --runs $(RUNS)

# §6's cross-language fixture. Swift emits it; the Ruby port must reproduce it.
golden:
	cd $(CORE) && swift run bonedust-tool golden ../../shared/golden/derivations.json

# The Ruby port's own suite, including the golden comparison.
server-test:
	cd server && bundle exec rspec

# The cross-language check on its own, without bundler or a database.
server-golden:
	ruby server/verify_golden.rb

# §9: 500 concurrent payments with no lost increments. Needs a running server:
#   cd server && ATTEST_MODE=permissive bin/rails server -p 3111
server-load:
	cd server && LEDGER_URL=$${LEDGER_URL:-http://localhost:3111} ruby script/load_test.rb 500

server-setup:
	cd server && bundle install && bin/rails db:prepare && bin/rails db:seed

# Renders slabs to PNG, headlessly. The source of App Store screenshots (§9) and the only
# way to actually look at the rendering without a device.
RENDER_OUT ?= build/render
RENDER_SCALE ?= 4
render:
	cd $(CORE) && swift build -c release
	mkdir -p $(RENDER_OUT)
	$(CORE)/.build/release/bonedust-tool render $(RENDER_OUT) $(RENDER_SCALE)
	for f in $(RENDER_OUT)/*.ppm; do \
		sips -s format png "$$f" --out "$${f%.ppm}.png" >/dev/null; \
	done
	rm -f $(RENDER_OUT)/*.ppm
	@echo "wrote $$(ls $(RENDER_OUT)/*.png | wc -l | tr -d ' ') frames to $(RENDER_OUT)"

# Builds, installs and launches on the first physically attached iPhone.
#
# The device is looked up rather than hardcoded, because a UDID in a build file is a
# thing that goes stale silently on a machine that sees more than one phone.
#
# -allowProvisioningUpdates is what registers a new bundle id and a new device with the
# team. Without it, a bundle id that App Store Connect has never seen fails to sign with
# a message about a missing profile, which reads like a certificate problem and is not.
DEVICE_BUILD ?= build/device
device: project
	@line=$$(xcrun devicectl list devices 2>/dev/null \
		| awk '$$NF == "physical" && /iPhone|iPad/'); \
	if [ -z "$$line" ]; then echo "no iPhone paired"; exit 1; fi; \
	udid=$$(echo "$$line" | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1); \
	state=$$(echo "$$line" | grep -oE 'available \(paired\)|unavailable|connected' | head -1); \
	if [ "$$state" = "unavailable" ]; then \
		echo "iPhone is $$state -- unlock it and check the cable, then run make device again"; \
		exit 1; \
	fi; \
	echo "device $$udid ($$state)"; \
	xcodebuild build -project ios/Bonedust.xcodeproj -scheme Bonedust \
		-destination "id=$$udid" -derivedDataPath $(DEVICE_BUILD) \
		-allowProvisioningUpdates | tail -3; \
	app=$(DEVICE_BUILD)/Build/Products/Debug-iphoneos/Bonedust.app; \
	xcrun devicectl device install app --device "$$udid" "$$app" | tail -2; \
	xcrun devicectl device process launch --device "$$udid" \
		$$(plutil -extract CFBundleIdentifier raw "$$app/Info.plist") | tail -1

content:
	cd $(CORE) && swift run bonedust-tool content-check

# Regenerates shared/constants.json for the Rails service. Swift is the source of
# truth; a stale file fails SharedConstantsTests.
constants:
	cd $(CORE) && swift run bonedust-tool dump-constants ../../shared/constants.json

# Build products and the generated project only. Everything dropped here comes
# back from `make project` and `make test-core`.
clean:
	git clean -xdf -- $(CORE)/.build ios/Bonedust.xcodeproj

# The Team ID the installed signing certificates actually carry, read from each
# certificate's OU. The parenthetical in a development cert's common name is the
# *user* id and is not it -- getting those two confused is how
# BonedustAppAttestAppID ends up wrong, which takes attestation down entirely.
# Publishing under an organization means a different team from a personal one.
team-id:
	@tmp=$$(mktemp -d); \
	security find-certificate -a -p -c "Apple Dis" > $$tmp/all.pem 2>/dev/null; \
	security find-certificate -a -p -c "Apple Dev" >> $$tmp/all.pem 2>/dev/null; \
	awk 'BEGIN{n=0} /BEGIN CERT/{n++} {print > (d "/c" n ".pem")}' d=$$tmp $$tmp/all.pem; \
	for f in $$tmp/c*.pem; do \
		openssl x509 -in $$f -noout -subject 2>/dev/null \
			| sed -n 's/.*CN = \([^,]*\).*OU = \([A-Z0-9]*\), O = \([^,]*\).*/\2  \3  (\1)/p'; \
	done | sort -u; \
	rm -rf $$tmp
	@echo
	@echo "First column is the Team ID -- use it in BonedustAppAttestAppID and"
	@echo "DEVELOPMENT_TEAM. Third column is the organization that owns it."

# Every species tiled into one image, so the catalogue can be judged at a glance.
# Looking at them is the only test for whether a shape reads as an animal; a sanity
# test can say a fossil is a playable size, not that it looks like a wrench.
SHEET_OUT ?= build/sheet
sheet:
	cd $(CORE) && swift build -c release
	mkdir -p $(dir $(SHEET_OUT))
	$(CORE)/.build/release/bonedust-tool sheet $(SHEET_OUT).ppm 9
	sips -s format png $(SHEET_OUT).ppm --out $(SHEET_OUT).png >/dev/null
	rm -f $(SHEET_OUT).ppm
	@echo "wrote $(SHEET_OUT).png"

# One PNG per species, centred and alone.
SHAPES_OUT ?= build/shapes
shapes:
	cd $(CORE) && swift build -c release
	$(CORE)/.build/release/bonedust-tool shapes $(SHAPES_OUT) 5
	for f in $(SHAPES_OUT)/*.ppm; do \
		sips -s format png "$$f" --out "$${f%.ppm}.png" >/dev/null; \
	done
	rm -f $(SHAPES_OUT)/*.ppm
	@echo "wrote $$(ls $(SHAPES_OUT)/*.png | wc -l | tr -d ' ') shapes"
