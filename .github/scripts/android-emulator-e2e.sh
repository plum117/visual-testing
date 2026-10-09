#!/usr/bin/env bash
# DEBUG branch: does a warm-up session make the first (setup) run stable?
set -uo pipefail
mkdir -p logs fpdbg
appium --port 4723 --allow-insecure 'uiautomator2:chromedriver_autodownload' > logs/appium.log 2>&1 &
APPIUM_PID=$!
cleanup() {
    kill "$APPIUM_PID" 2> /dev/null || true
    ( sleep 30; for _ in $(seq 1 12); do pgrep -x crashpad_handler > /dev/null || break; pkill -9 -x crashpad_handler || true; sleep 5; done ) > /dev/null 2>&1 &
}
trap cleanup EXIT
for _ in $(seq 1 60); do curl -sf http://127.0.0.1:4723/status > /dev/null && break; sleep 1; done

if [ "${WARMUP:-false}" = "true" ]; then
    echo "::group::Warm-up"
    pnpm test.local.emus.web --mochaOpts.grep "full page screenshot successful" || true
    rm -rf tests/localBaseline .tmp
    echo "::endgroup::"
fi

echo "::group::Setup run"
DEBUG_FP=fpdbg/setup BASELINE_SETUP=true pnpm test.local.emus.web; SETUP=$?
echo "::endgroup::"
echo "::group::Compare run"
DEBUG_FP=fpdbg/compare pnpm test.local.emus.web; COMPARE=$?
echo "::endgroup::"
mkdir -p fpdbg && cp -r tests/localBaseline fpdbg/baseline 2> /dev/null; cp -r .tmp/diff fpdbg/diff 2> /dev/null
echo "RESULT warmup=${WARMUP:-false} setup=$SETUP compare=$COMPARE" | tee fpdbg/result.txt
exit 0
