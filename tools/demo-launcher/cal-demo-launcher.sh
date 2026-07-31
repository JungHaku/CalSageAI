#!/bin/bash
#
# Cal Coherence — demo launcher
#
# Double-clicked from the Desktop. Boots a simulator, builds the current source,
# installs, and launches with seeded data so the Progress and History screens
# have something in them.
#
# Launched from Finder, so it inherits almost no environment: PATH is minimal and
# there is no terminal to print to. Hence the absolute paths below and the
# osascript dialogs — a silent failure would just look like a broken icon.

set -uo pipefail

PROJECT="/Users/becka/Desktop/CalAI"
SCHEME="Cal"
BUNDLE_ID="com.breathehealthcenter.cal.dev"
DEVICE="iPhone 17 Pro"
LOG="${TMPDIR:-/tmp}/cal-demo-$(date +%Y%m%d-%H%M%S).log"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"

notify() { /usr/bin/osascript -e "display notification \"$1\" with title \"Cal demo\"" >/dev/null 2>&1; }

fail() {
    /usr/bin/osascript <<APPLESCRIPT >/dev/null 2>&1
    set theLog to "$LOG"
    display dialog "$1" & return & return & "Log: " & theLog ¬
        with title "Cal demo" buttons {"Show log", "OK"} default button "OK" with icon stop
    if button returned of result is "Show log" then
        tell application "Console" to activate
        do shell script "open -a Console " & quoted form of theLog
    end if
APPLESCRIPT
    exit 1
}

{
    echo "=== Cal demo launcher — $(date) ==="
    echo "project: $PROJECT"
} >"$LOG" 2>&1

# --- preflight -------------------------------------------------------------

[ -d "$PROJECT" ] || fail "Can't find the project at $PROJECT."

if ! /usr/bin/xcrun --find xcodebuild >>"$LOG" 2>&1; then
    fail "Xcode command line tools aren't available. Open Xcode once, then try again."
fi

# --- simulator -------------------------------------------------------------

notify "Starting the simulator…"

UDID=$(/usr/bin/xcrun simctl list devices available -j 2>>"$LOG" \
    | /usr/bin/python3 -c "
import json,sys
data = json.load(sys.stdin)['devices']
want = '$DEVICE'
best = None
for runtime, devices in data.items():
    if 'iOS' not in runtime: continue
    for d in devices:
        if not d.get('isAvailable'): continue
        if d['name'] == want: print(d['udid']); sys.exit()
        if best is None and d['name'].startswith('iPhone'): best = d['udid']
print(best or '')
" 2>>"$LOG")

[ -n "$UDID" ] || fail "No iPhone simulator is installed. Add one in Xcode › Settings › Components."

echo "device udid: $UDID" >>"$LOG"
/usr/bin/xcrun simctl boot "$UDID" >>"$LOG" 2>&1   # already-booted returns non-zero; harmless
/usr/bin/open -a Simulator >>"$LOG" 2>&1

# Wait for the device to finish booting before touching it.
#
# `simctl boot` returns as soon as the boot is *requested*, not when it is done.
# Installing into a half-booted device fails with "(ipc/mig) server died", which
# reads like a crash and is really just impatience — it cost a cold-start run
# here. `bootstatus -b` blocks until the device is actually ready.
if ! /usr/bin/xcrun simctl bootstatus "$UDID" -b >>"$LOG" 2>&1; then
    fail "The simulator didn't finish booting."
fi

# --- build -----------------------------------------------------------------

notify "Building… this takes a minute the first time."

cd "$PROJECT" || fail "Couldn't enter $PROJECT."

if ! /usr/bin/xcrun xcodebuild \
        -project Cal.xcodeproj \
        -scheme "$SCHEME" \
        -destination "id=$UDID" \
        -derivedDataPath "$PROJECT/.demo-build" \
        build >>"$LOG" 2>&1; then
    fail "The build failed."
fi

APP=$(/usr/bin/find "$PROJECT/.demo-build/Build/Products" -name "Cal.app" -maxdepth 3 -type d 2>/dev/null | /usr/bin/head -1)
[ -n "$APP" ] || fail "The build succeeded but Cal.app wasn't where expected."

# --- install and launch ----------------------------------------------------

notify "Installing…"
if ! /usr/bin/xcrun simctl install "$UDID" "$APP" >>"$LOG" 2>&1; then
    echo "install failed once; retrying after a pause" >>"$LOG"
    /bin/sleep 3
    /usr/bin/xcrun simctl install "$UDID" "$APP" >>"$LOG" 2>&1 \
        || fail "Couldn't install onto the simulator." 
fi

# Seeded, in-memory, and mock-backed:
#   -CalScenario day30Streak  30 days of history, so Progress and History are
#                             worth looking at instead of empty
#   -CalEntitlement plus      Dr. Mia's ten-question framework, which is the
#                             thing she designed and wants to see
#   -CalUseMockCoach 1        never reaches a real model — no cost, no network
#
# A seeded scenario also makes the store in-memory, so every launch starts from
# the same clean state and nothing she taps persists. That is deliberate for a
# demo; it is not how the shipping app behaves.
/usr/bin/xcrun simctl launch "$UDID" "$BUNDLE_ID" \
    -CalScenario day30Streak \
    -CalEntitlement plus \
    -CalUseMockCoach 1 >>"$LOG" 2>&1 || fail "Installed, but the app wouldn't launch."

/usr/bin/open -a Simulator
notify "Cal is running."
exit 0
