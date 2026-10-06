#!/usr/bin/env bash
#
# Runs the UI driver's capture tour with the screen recorder going: a whole dig with real touches,
# and everything needed to look at it afterwards. See ios/BonedustUITests/README.md.
#
#   scripts/ui-capture.sh [output-dir]
#
# The output directory (default: a fresh one under $TMPDIR) gets markers.txt, the screenshots
# (01-fresh.png and on) and dig.mp4. What to dig is chosen in the environment: BONEDUST_UI_SITE,
# BONEDUST_UI_TOOL, BONEDUST_UI_CAREFUL, BONEDUST_UI_FAST and BONEDUST_UI_ROWSTEP. A simulator has
# to be booted already, because the recorder needs one to record.

set -euo pipefail

cd "$(dirname "$0")/.."

OUT=${1:-$(mktemp -d "${TMPDIR:-/tmp}/bonedust-ui-capture.XXXXXX")}
SIM=${SIM:-platform=iOS Simulator,name=iPhone 16} # the Makefile's default

if ! xcrun simctl list devices booted | grep -q Booted; then
  echo "No simulator is booted. Boot the one in \$SIM first, e.g. xcrun simctl boot 'iPhone 16'." >&2
  exit 1
fi
mkdir -p "$OUT"

xcrun simctl io booted recordVideo --codec h264 --force "$OUT/dig.mp4" 2> "$OUT/recorder.log" &
RECORDER=$!
# SIGINT is how the recorder is told to finish the file; killing it any other way truncates it.
trap 'kill -INT "$RECORDER" 2>/dev/null || true; wait "$RECORDER" 2>/dev/null || true' EXIT
sleep 1.5 # the recorder takes a moment to start

# xcodebuild hands TEST_RUNNER_<name> to the test process as <name>.
export TEST_RUNNER_BONEDUST_UI_CAPTURE_DIR="$OUT"
for name in $(compgen -v BONEDUST_UI_); do
  export "TEST_RUNNER_$name=${!name}"
done

# -collect-test-diagnostics never: a failed run otherwise waits ten minutes for the simulator to
# hand over diagnostics it never does.
xcodebuild test -project ios/Bonedust.xcodeproj -scheme BonedustUI \
  -destination "$SIM" CODE_SIGNING_ALLOWED=NO -collect-test-diagnostics never \
  -only-testing:BonedustUITests/DigDriverUITests/testCaptureTour > "$OUT/xcodebuild.log" 2>&1 \
  || { echo "xcodebuild failed; see $OUT/xcodebuild.log" >&2; exit 1; }

echo "Captured to $OUT:"
ls "$OUT"
