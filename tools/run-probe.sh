#!/bin/zsh
#
# Builds Cue and runs the M0 probe, printing its report.
#
# The probe is launched with `open -n -W`, not by executing the binary directly,
# and the distinction matters. macOS attributes an Automation request to the
# *responsible process* for the process that sends it. A binary started from a
# shell inherits the terminal as responsible, so the request is auto-refused with
# no prompt and no TCC entry for Cue. Going through `open` has launchd start it,
# so Cue is its own responsible process, gets the prompt, and keeps the grant.
#
# Because `open` gives the app no usable stdout, the probe writes its report to
# ~/Library/Logs/Cue/m0-probe-report.txt, which this script prints at the end.
#
# Usage: tools/run-probe.sh [--listen <seconds>] [--samples <n>]
#        tools/run-probe.sh --grant      # one-time: raise the prompt and wait
#        tools/run-probe.sh --bench [--samples <n>]   # compare fetchState variants

set -e
cd "${0:a:h}/.."

REPORT="$HOME/Library/Logs/Cue/m0-probe-report.txt"

echo "Building…"
xcodebuild -project Cue.xcodeproj -scheme Cue -configuration Debug build \
  > /tmp/cue-build.log 2>&1 || { tail -30 /tmp/cue-build.log; exit 1; }

APP="$(xcodebuild -project Cue.xcodeproj -scheme Cue -configuration Debug \
        -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2}')/Cue.app"
echo "App: $APP"

rm -f "$REPORT"

MUSIC_BEFORE=$(pgrep -x Music | wc -l | tr -d ' ')
echo "Music processes before: $MUSIC_BEFORE"
echo

# -n forces a fresh instance, -W waits for it to exit.
# --grant is its own mode; everything else runs the probe sequence.
if [[ " $* " == *" --grant "* || " $* " == *" --bench "* ]]; then
  open -n -W -a "$APP" --args "$@"
else
  open -n -W -a "$APP" --args --probe "$@"
fi

MUSIC_AFTER=$(pgrep -x Music | wc -l | tr -d ' ')

if [[ -f "$REPORT" ]]; then
  cat "$REPORT"
else
  echo "No report at $REPORT — the app may have failed to launch."
  exit 1
fi

echo
echo "Music processes after: $MUSIC_AFTER"
if [[ "$MUSIC_BEFORE" == "0" && "$MUSIC_AFTER" != "0" ]]; then
  echo "WARNING: Music was launched during this run."
fi
