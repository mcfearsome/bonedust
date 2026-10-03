# Bonedust
#
# The Xcode project is generated, never hand-edited. `ios/project.yml` is the
# source of truth, so a target or build-setting change is a reviewable one-line
# diff instead of a 400-line pbxproj conflict.

SIM ?= platform=iOS Simulator,name=iPhone 16
CORE := ios/BonedustCore

.PHONY: all project test test-core test-app bench constants content app clean

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

test: test-core

app: project
	xcodebuild build -project ios/Bonedust.xcodeproj -scheme Bonedust \
		-destination '$(SIM)' CODE_SIGNING_ALLOWED=NO

# Worst realistic frame for the simulation: a fast air-blower swipe. §9 wants
# 60 fps on an iPhone 12, and this is the half of that budget we control.
bench:
	cd $(CORE) && swift build -c release && ./.build/release/bonedust-tool bench

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
