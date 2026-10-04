# Bonedust
#
# The Xcode project is generated, never hand-edited. `ios/project.yml` is the
# source of truth, so a target or build-setting change is a reviewable one-line
# diff instead of a 400-line pbxproj conflict.

SIM ?= platform=iOS Simulator,name=iPhone 17
CORE := ios/BonedustCore

.PHONY: all project test test-core test-app bench simulate constants golden content app \
	server-test server-golden server-load server-setup render clean

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
