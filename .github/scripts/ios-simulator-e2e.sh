#!/usr/bin/env bash
# Runs the iOS mobile web e2e tests on a new simulator in the macOS runner.
# The baselines are not in git: the setup run saves them, the compare run compares with them.
#
# DEBUG (fork only): booted-device cache experiment. SIM_MODE:
#   control       the current flow
#   seed-boot     first boot only, then save the device folder to $SIM_CACHE_DIR
#   seed-warm     first boot + WebDriverAgent + warm-up session, then save the device folder
#   cached-boot   restore the device folder from $SIM_CACHE_DIR, keep the warm-up session
#   cached-warm   restore the device folder from $SIM_CACHE_DIR, no warm-up session
set -euo pipefail
timing() { echo "TIMING $(date -u +%H:%M:%S) $*"; }
SIM_MODE="${SIM_MODE:-control}"
SIM_CACHE_DIR="${SIM_CACHE_DIR:-${RUNNER_TEMP:-/tmp}/sim-cache}"
DEVICES_DIR="$HOME/Library/Developer/CoreSimulator/Devices"
timing "start ($SIM_MODE)"

# A new simulator of the newest iOS runtime of the selected Xcode
RUNTIME=$(xcrun simctl list runtimes --json | jq -r '[.runtimes[] | select(.platform == "iOS" and .isAvailable)] | sort_by(.version | split(".") | map(tonumber)) | last | .identifier')
IOS_PLATFORM_VERSION=$(xcrun simctl list runtimes --json | jq -r --arg id "$RUNTIME" '.runtimes[] | select(.identifier == $id) | .version')
IOS_DEVICE_NAME="CI ${SIMULATOR_DEVICE_TYPE}"
export IOS_DEVICE_NAME IOS_PLATFORM_VERSION

if [[ "$SIM_MODE" == cached-* ]]; then
    UDID=$(cat "$SIM_CACHE_DIR/udid")
    [[ "$(cat "$SIM_CACHE_DIR/runtime")" == "$RUNTIME" ]] || { echo "Cached runtime $(cat "$SIM_CACHE_DIR/runtime") != $RUNTIME"; exit 1; }
    timing "restore start ($(du -sh "$SIM_CACHE_DIR/device.tar" | cut -f1))"
    tar -xf "$SIM_CACHE_DIR/device.tar" -C "$DEVICES_DIR"
    timing "restore extracted"
    # CoreSimulator reads the device folders when its service starts
    killall -9 com.apple.CoreSimulator.CoreSimulatorService 2> /dev/null || true
    for _ in $(seq 1 30); do
        xcrun simctl list devices --json | jq -e --arg u "$UDID" '[.devices[][] | select(.udid == $u)] | length == 1' > /dev/null && break
        sleep 1
    done
    xcrun simctl list devices --json | jq -e --arg u "$UDID" '[.devices[][] | select(.udid == $u)] | length == 1' > /dev/null \
        || { echo "The restored simulator $UDID is not known to CoreSimulator"; xcrun simctl list devices; exit 1; }
    timing "restore registered"
else
    UDID=$(xcrun simctl create "$IOS_DEVICE_NAME" "$SIMULATOR_DEVICE_TYPE" "$RUNTIME")
fi
echo "Simulator: $IOS_DEVICE_NAME, iOS $IOS_PLATFORM_VERSION ($UDID)"
timing "boot start"
xcrun simctl bootstatus "$UDID" -b > /dev/null
timing "boot done"

save_device() {
    timing "save start"
    xcrun simctl shutdown "$UDID"
    mkdir -p "$SIM_CACHE_DIR"
    echo "$UDID" > "$SIM_CACHE_DIR/udid"
    echo "$RUNTIME" > "$SIM_CACHE_DIR/runtime"
    tar -cf "$SIM_CACHE_DIR/device.tar" -C "$DEVICES_DIR" "$UDID"
    timing "save done ($(du -sh "$SIM_CACHE_DIR/device.tar" | cut -f1))"
}

if [[ "$SIM_MODE" == "seed-boot" ]]; then
    save_device
    exit 0
fi

# Build WebDriverAgent before the first session: inside a session, Appium waits only 60 s for it, and the build
# alone takes longer on the runner. The session then reuses this build.
mkdir -p logs
echo "Building WebDriverAgent (output in logs/build-wda.log)"
timing "build-wda start"
appium driver run xcuitest build-wda --name "$IOS_DEVICE_NAME" --sdk "$IOS_PLATFORM_VERSION" > logs/build-wda.log 2>&1 \
    || { tail -50 logs/build-wda.log; exit 1; }
timing "build-wda done"

# Its output goes to a file (uploaded when the job fails), not to the job log
appium --port 4723 --log-timestamp > logs/appium.log 2>&1 &
APPIUM_PID=$!

cleanup() {
    kill "$APPIUM_PID" 2> /dev/null || true
    xcrun simctl shutdown "$UDID" 2> /dev/null || true
}
trap cleanup EXIT

for _ in $(seq 1 60); do
    curl -sf http://127.0.0.1:4723/status > /dev/null && break
    sleep 1
done
curl -sf http://127.0.0.1:4723/status > /dev/null || { echo "Appium did not start"; cat logs/appium.log; exit 1; }

# Warm-up: the first session builds WebDriverAgent, Safari shows a first-start tip, and iOS shows a first-boot
# notification that can be in the screenshots. Its result and files are not kept.
if [[ "$SIM_MODE" != "cached-warm" ]]; then
    timing "warm-up start"
    echo "::group::Warm up the simulator"
    BASELINE_SETUP=true pnpm test.local.sims.web --mochaOpts.grep "full page screenshot successful" || true
    rm -rf tests/localBaseline .tmp
    echo "::endgroup::"
fi

if [[ "$SIM_MODE" == "seed-warm" ]]; then
    kill "$APPIUM_PID" 2> /dev/null || true
    save_device
    exit 0
fi

timing "setup start"
echo "::group::Save the baselines"
BASELINE_SETUP=true pnpm test.local.sims.web
echo "::endgroup::"

timing "compare start"
echo "::group::Compare with the baselines"
pnpm test.local.sims.web
echo "::endgroup::"
timing "end"
