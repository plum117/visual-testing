#!/usr/bin/env bash
# Runs the iOS mobile web e2e tests on a new simulator in the macOS runner.
# The baselines are not in git: the setup run saves them, the compare run compares with them.
set -euo pipefail
timing() { echo "TIMING $(date -u +%H:%M:%S) $*"; }

# A new simulator of the newest iOS runtime of the selected Xcode
RUNTIME=$(xcrun simctl list runtimes --json | jq -r '[.runtimes[] | select(.platform == "iOS" and .isAvailable)] | sort_by(.version | split(".") | map(tonumber)) | last | .identifier')
IOS_PLATFORM_VERSION=$(xcrun simctl list runtimes --json | jq -r --arg id "$RUNTIME" '.runtimes[] | select(.identifier == $id) | .version')
IOS_DEVICE_NAME="CI ${SIMULATOR_DEVICE_TYPE}"
UDID=$(xcrun simctl create "$IOS_DEVICE_NAME" "$SIMULATOR_DEVICE_TYPE" "$RUNTIME")
export IOS_DEVICE_NAME IOS_PLATFORM_VERSION
echo "Simulator: $IOS_DEVICE_NAME, iOS $IOS_PLATFORM_VERSION ($UDID)"
# The boot continues while WebDriverAgent is downloaded
xcrun simctl boot "$UDID"
mkdir -p logs

# Use the prebuilt WebDriverAgent of the installed XCUITest driver: Appium installs and starts it on the simulator,
# without an xcodebuild build (minutes on the runner) and without xcodebuild in each session.
# When the download fails, build WebDriverAgent as before.
WDA_DIR="${RUNNER_TEMP:-/tmp}/wda-sim"
rm -rf "$WDA_DIR"
if [ "${VARIANT:-}" != control ] && appium driver run xcuitest download-wda -- --kind=sim --platform=iOS --outdir="$WDA_DIR" > logs/download-wda.log 2>&1 \
    && [ -d "$WDA_DIR/WebDriverAgentRunner-Runner.app" ]; then
    export IOS_PREBUILT_WDA="$WDA_DIR/WebDriverAgentRunner-Runner.app"
    echo "Prebuilt WebDriverAgent: $IOS_PREBUILT_WDA"
else
    tail -20 logs/download-wda.log || true
    echo "::warning::The prebuilt WebDriverAgent could not be downloaded, so it is built"
fi

timing "boot wait start"
xcrun simctl bootstatus "$UDID" -b > /dev/null
timing "boot wait end"

if [ -z "${IOS_PREBUILT_WDA:-}" ]; then
    # Build WebDriverAgent before the first session: inside a session, Appium waits only 60 s for it, and the build
    # alone takes longer on the runner. The session then reuses this build.
    echo "Building WebDriverAgent (output in logs/build-wda.log)"
    appium driver run xcuitest build-wda --name "$IOS_DEVICE_NAME" --sdk "$IOS_PLATFORM_VERSION" > logs/build-wda.log 2>&1 \
        || { tail -50 logs/build-wda.log; exit 1; }
fi

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

# Warm-up: Safari shows a first-start tip, and iOS shows a first-boot notification that can be in the screenshots.
# Its result and files are not kept.
timing "warm-up start ($VARIANT)"
echo "::group::Warm up the simulator"
case "${VARIANT:-}" in
    openurl-*)
        xcrun simctl openurl "$UDID" "https://guinea-pig.webdriver.io/image-compare.html"
        sleep 60
        xcrun simctl io "$UDID" screenshot logs/after-openurl.png || true
        ;;
    *)
        BASELINE_SETUP=true pnpm test.local.sims.web --mochaOpts.grep "full page screenshot successful" || true
        rm -rf tests/localBaseline .tmp
        ;;
esac
echo "::endgroup::"
timing "warm-up end"

timing "setup start"
echo "::group::Save the baselines"
BASELINE_SETUP=true pnpm test.local.sims.web
echo "::endgroup::"

timing "compare start"
echo "::group::Compare with the baselines"
pnpm test.local.sims.web
echo "::endgroup::"
timing "end"
