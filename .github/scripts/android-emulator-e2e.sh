#!/usr/bin/env bash
# DEBUG branch: sample the Android full page screenshot several times on the CI emulator.
set -uo pipefail
adb devices
mkdir -p logs fpdbg
appium --port 4723 --allow-insecure 'uiautomator2:chromedriver_autodownload' > logs/appium.log 2>&1 &
APPIUM_PID=$!
cleanup() {
    kill "$APPIUM_PID" 2> /dev/null || true
    ( sleep 30; for _ in $(seq 1 12); do pgrep -x crashpad_handler > /dev/null || break; pkill -9 -x crashpad_handler || true; sleep 5; done ) > /dev/null 2>&1 &
}
trap cleanup EXIT
for _ in $(seq 1 60); do curl -sf http://127.0.0.1:4723/status > /dev/null && break; sleep 1; done

# Sample 1: the full suite (first page load in a new Chrome), like the setup run
rm -rf tests/localBaseline
DEBUG_FP=fpdbg/s1 BASELINE_SETUP=true pnpm test.local.emus.web
cp -r tests/localBaseline fpdbg/s1/baseline
# Samples 2-5: the full page test alone, each with new baselines
for n in 2 3 4 5; do
    rm -rf tests/localBaseline
    DEBUG_FP=fpdbg/s$n BASELINE_SETUP=true pnpm test.local.emus.web --mochaOpts.grep "full page screenshot successful"
    cp -r tests/localBaseline fpdbg/s$n/baseline
done
exit 0
