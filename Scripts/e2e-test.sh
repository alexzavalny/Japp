#!/bin/bash
# End-to-end tests against the installed JApp Runtime (run Scripts/install.sh first).
#
# Windows appear briefly while this runs. All app data and workspaces go to a
# temporary JAPP_SUPPORT_DIR, so your real apps' data is never touched.
#
#   Scripts/e2e-test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${JAPP_APP:-/Applications/JApp Runtime.app}"
[ -d "$APP" ] || APP="$HOME/Applications/JApp Runtime.app"
JAPP="$APP/Contents/Helpers/japp"
WORK="$(cd "$(mktemp -d -t japp-e2e)" && pwd -P)"   # /private/var/…: the path processes report
export JAPP_SUPPORT_DIR="$WORK/support"
export JAPP_RUNTIME="$APP"
PY="/usr/bin/python3 -I"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected: $3 | got: $2"; fi; }
json() { $PY -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {}, {'d': d}))" "$1" "$2"; }
wait_for() { for _ in $(seq 1 60); do [ -f "$1" ] && return 0; sleep 0.5; done; return 1; }

[ -x "$JAPP" ] || { echo "JApp Runtime is not installed (looked in $APP). Run Scripts/install.sh."; exit 1; }
if pgrep -x JAppRuntime >/dev/null; then
    echo "Quit running JApp apps first: Launch Services would route test requests to them."
    exit 1
fi
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
cleanup() {
    # Never leave the runtime in automation mode.
    defaults delete dev.japp.runtime JAppAutomationDir 2>/dev/null
    # Test app bundles must not linger in Launch Services next to the real ones.
    for bundle in "$JAPP_SUPPORT_DIR"/AppBundles/*/*.app; do
        [ -d "$bundle" ] && "$LSREGISTER" -u "$bundle" >/dev/null 2>&1
    done
}
trap cleanup EXIT
echo "Runtime: $APP"
echo "Work:    $WORK"

echo "==> Helpers"
for tool in post-notification check-launch-services perform-service; do
    swiftc -O "$ROOT/Tests/E2E/$tool.swift" -o "$WORK/$tool" 2>/dev/null || { echo "could not compile $tool"; exit 1; }
done

echo "==> Packaging"
"$JAPP" pack "$ROOT/Examples/Calculator" --output "$WORK/Calculator.japp" >/dev/null && pass "japp pack" || fail "japp pack"
"$JAPP" validate "$WORK/Calculator.japp" >/dev/null && pass "japp validate" || fail "japp validate"
unzip -tq "$WORK/Calculator.japp" >/dev/null && pass "the .japp is a standard ZIP (unzip -t)" || fail "unzip -t"

echo "==> macOS integration"
"$WORK/check-launch-services" "$WORK/Calculator.japp" > "$WORK/ls.txt"
check "file type is dev.japp.app" "$(sed -n 's/^type=//p' "$WORK/ls.txt")" "dev.japp.app"
check "default app is JApp Runtime" "$(basename "$(sed -n 's/^app=//p' "$WORK/ls.txt")")" "JApp Runtime.app"

mkdir -p "$WORK/ls-report"
cp "$WORK/Calculator.japp" "$WORK/Opened.japp"
open --env "JAPP_SUPPORT_DIR=$JAPP_SUPPORT_DIR" -a "$APP" "$WORK/Opened.japp" --args -JAppAutomationDir "$WORK/ls-report" -JAppAutomationQuit YES
# `open <file>` is what a Finder double-click does; --args only matters when a new process starts.
if wait_for "$WORK/ls-report/report.json"; then
    check "opening the file shows the app's window title" "$(json "$WORK/ls-report/report.json" "d['windowTitle']")" "Calculator"
    check "window has the manifest size" "$(json "$WORK/ls-report/report.json" "(d['contentSize']['width'], d['contentSize']['height'])")" "(400, 550)"
else
    fail "app opened through Launch Services" "no report (is another JApp Runtime process running?)"
fi
sleep 1
xattr -p com.apple.ResourceFork "$WORK/Opened.japp" >/dev/null 2>&1 && pass "Finder icon applied on launch" || fail "Finder icon applied on launch"

echo "==> App bundles (the app's own name in the menu bar, Dock and ⌘-Tab)"
bundle_open() {  # bundle_open <file> <report dir>: what a Finder double-click does, through the app bundle
    mkdir -p "$2"
    open --env "JAPP_SUPPORT_DIR=$JAPP_SUPPORT_DIR" -a "$APP" "$1" --args -JAppAutomationDir "$2" \
        -JAppAutomationQuit YES -JAppAutomationAppBundles YES -JAppSetFinderIcons NO
    wait_for "$2/report.json"
}
cp "$WORK/Calculator.japp" "$WORK/Bundled.japp"
BUNDLE="$JAPP_SUPPORT_DIR/AppBundles/com.example.calculator/Calculator.app"
if bundle_open "$WORK/Bundled.japp" "$WORK/bundle1"; then
    B="$WORK/bundle1/report.json"
    check "the app runs in its own app bundle" "$(json "$B" "(d['identity']['appBundle'], d['identity']['bundlePath'])")" "(True, '$BUNDLE')"
    check "process identity is the app's" "$(json "$B" "(d['identity']['localizedName'], d['identity']['bundleName'], d['identity']['executable'])")" "('Calculator', 'Calculator', 'Calculator')"
    check "bundle id is namespaced" "$(json "$B" "d['identity']['bundleIdentifier']")" "dev.japp.app.com.example.calculator"
    check "app menu names the app only" "$(json "$B" "d['native']['menuBar'][0]['title'], [i for i in d['native']['menuBar'][0]['items'] if 'JApp' in i or 'Command-Line' in i or 'Calculator' in i]")" "('Calculator', ['About Calculator', 'Hide Calculator', 'Quit Calculator'])"
    check "no runtime commands in the File menu" "$(json "$B" "[i for m in d['native']['menuBar'] if m['title'] == 'File' for i in m['items'] if i in ('Open…', 'Edit Source…')]")" "['Edit Source…']"
    check "the app still works" "$(json "$B" "(d['ok'], d['windowTitle'])")" "(True, 'Calculator')"
else
    fail "the app runs in its own app bundle" "no report"
fi
sleep 1
pgrep -x JAppRuntime >/dev/null && fail "JApp Runtime quits after handing the app over" || pass "JApp Runtime quits after handing the app over"
codesign --verify --strict "$BUNDLE" 2>/dev/null && pass "app bundle is signed (ad hoc)" || fail "app bundle is signed (ad hoc)"
check "app bundle declares no document types, URL schemes or services" \
    "$(plutil -convert json -o - "$BUNDLE/Contents/Info.plist" | $PY -c "import json,sys; d=json.load(sys.stdin); print([k for k in ('CFBundleDocumentTypes','CFBundleURLTypes','NSServices','UTExportedTypeDeclarations') if k in d])")" "[]"
check "app bundle has the app's icon" "$(/usr/bin/file -b "$BUNDLE/Contents/Resources/AppIcon.icns" | cut -d' ' -f1-4)" "Mac OS X icon,"
"$JAPP" bundles | grep -q "runs:   .*/$(basename "$WORK")/Bundled.japp" && pass "japp bundles lists it with its file" || fail "japp bundles lists it with its file"

# Opened on its own (Dock, Spotlight): the bundle runs the file it last ran.
mkdir -p "$WORK/bundle2"
open -n --env "JAPP_SUPPORT_DIR=$JAPP_SUPPORT_DIR" "$BUNDLE" --args -JAppAutomationDir "$WORK/bundle2" -JAppAutomationQuit YES -JAppSetFinderIcons NO
if wait_for "$WORK/bundle2/report.json"; then
    check "launching the bundle itself opens its app" "$(json "$WORK/bundle2/report.json" "(d['ok'], d['identity']['bundleIdentifier'])")" "(True, 'dev.japp.app.com.example.calculator')"
else
    fail "launching the bundle itself opens its app" "no report"
fi

# A renamed app gets a renamed bundle (same folder, so a Dock item keeps working).
SOURCE="$("$JAPP" edit "$WORK/Bundled.japp" --no-window | sed -n 's/^Source folder: //p')"
INODE="$(stat -f %i "$BUNDLE")"
sed -i '' 's/"name": "Calculator"/"name": "Calculator Plus"/' "$SOURCE/manifest.json"
"$JAPP" save "$WORK/Bundled.japp" --close >/dev/null 2>&1
sleep 1
if bundle_open "$WORK/Bundled.japp" "$WORK/bundle3"; then
    check "renamed app: renamed bundle and process" "$(json "$WORK/bundle3/report.json" "(d['identity']['localizedName'], d['identity']['bundlePath'].split('/')[-1])")" "('Calculator Plus', 'Calculator Plus.app')"
    check "renamed in place" "$(stat -f %i "$JAPP_SUPPORT_DIR/AppBundles/com.example.calculator/Calculator Plus.app" 2>/dev/null) $([ -e "$BUNDLE" ] && echo old-left)" "$INODE "
else
    fail "renamed app: renamed bundle and process" "no report"
fi
sleep 1
"$JAPP" bundles remove com.example.calculator >/dev/null 2>&1 && [ ! -e "$JAPP_SUPPORT_DIR/AppBundles/com.example.calculator" ] \
    && pass "japp bundles remove" || fail "japp bundles remove"

echo "==> Running Calculator"
"$JAPP" snapshot "$WORK/Calculator.japp" --output "$WORK/calculator.png" --script "$ROOT/Tests/E2E/calculator.test.js" > "$WORK/run1.json" 2>/dev/null
R="$WORK/run1.json"
check "operator precedence (12 + 7 × 3)" "$(json "$R" "d['scriptResult']['precedence']")" "['12 + 7 × 3 =', '33']"
check "decimals (0.1 + 0.2)" "$(json "$R" "d['scriptResult']['decimals']")" "0.3"
check "division by zero" "$(json "$R" "d['scriptResult']['divideByZero']")" "Cannot divide by zero"
check "recovers after an error" "$(json "$R" "d['scriptResult']['recoversFromError']")" "5"
check "backspace" "$(json "$R" "d['scriptResult']['backspace']")" "12"
check "subtraction" "$(json "$R" "d['scriptResult']['subtraction']")" "5"
check "thousands grouping" "$(json "$R" "d['scriptResult']['grouping']")" "3,000,000"
check "second operator replaces the first" "$(json "$R" "d['scriptResult']['operatorReplaced']")" "5"
check "on-screen buttons" "$(json "$R" "d['scriptResult']['buttons']")" "1.5"
check "japp.storage round trip" "$(json "$R" "d['scriptResult']['storageRoundTrip']")" "{'list': [1, 'two', None], 'n': 1.5, 'ok': True}"
check "japp.storage default value" "$(json "$R" "d['scriptResult']['storageDefault']")" "fallback"
check "undeclared permission is denied" "$(json "$R" "d['scriptResult']['undeclaredPermission']")" "PERMISSION_DENIED"
check "remote fetch blocked without network permission" "$(json "$R" "d['scriptResult']['remoteFetch']")" "blocked"
check "same-origin fetch of bundled files" "$(json "$R" "d['scriptResult']['localFetch']")" "com.example.calculator"
check "missing files return 404" "$(json "$R" "d['scriptResult']['missingFile']")" "404"
check "japp.window.setTitle" "$(json "$R" "d['windowTitle']")" "Calculator (tested)"
check "window.japp is frozen" "$(json "$R" "d['scriptResult']['frozen']")" "True"
check "no console errors" "$(json "$R" "[c for c in d['console'] if c['level'] == 'error']")" "[]"

"$JAPP" snapshot "$WORK/Calculator.japp" --output "$WORK/calculator2.png" --eval 'return (await japp.storage.get("history", [])).length' > "$WORK/run2.json" 2>/dev/null
check "history persisted across launches" "$(json "$WORK/run2.json" "d['scriptResult']")" "$(json "$R" "d['scriptResult']['historyLength']")"

echo "==> Edit Source (terminal workflow)"
SOURCE="$("$JAPP" edit "$WORK/Calculator.japp" --no-window | sed -n 's/^Source folder: //p')"
[ -f "$SOURCE/style.css" ] && pass "japp edit unpacks the source" || fail "japp edit unpacks the source" "$SOURCE"
sed -i '' 's/--key-operator: #ff9f0a;/--key-operator: #30d158;/' "$SOURCE/style.css"
"$JAPP" save "$WORK/Calculator.japp" > "$WORK/save.txt" 2>&1 && pass "japp save" || fail "japp save" "$(cat "$WORK/save.txt")"
grep -q "modified: style.css" "$WORK/save.txt" && pass "save reports the changed file" || fail "save reports the changed file"
unzip -p "$WORK/Calculator.japp" style.css | grep -q "#30d158" && pass "change is inside the .japp" || fail "change is inside the .japp"
"$JAPP" snapshot "$WORK/Calculator.japp" --output "$WORK/edited.png" \
    --eval 'return getComputedStyle(document.querySelector("[data-operator]")).backgroundColor' > "$WORK/run3.json" 2>/dev/null
check "relaunched app shows the change" "$(json "$WORK/run3.json" "d['scriptResult']")" "rgb(48, 209, 88)"
echo '{ "broken": ' > "$SOURCE/manifest.json"
"$JAPP" save "$WORK/Calculator.japp" >/dev/null 2>&1 && fail "invalid source is refused" || pass "invalid source is refused"
"$JAPP" validate "$WORK/Calculator.japp" >/dev/null && pass "archive untouched by a failed save" || fail "archive untouched by a failed save"
rm -rf "$(dirname "$SOURCE")"

echo "==> Edit Source (runtime window)"
mkdir -p "$WORK/edit-report"
open -n --env "JAPP_SUPPORT_DIR=$JAPP_SUPPORT_DIR" -a "$APP" --args --edit "$WORK/Calculator.japp" \
    -JAppAutomationDir "$WORK/edit-report"
if wait_for "$WORK/edit-report/edit-report.json"; then
    SOURCE="$(json "$WORK/edit-report/edit-report.json" "d['sourceFolder']")"
    pass "Edit Source window opened the workspace"
    sed -i '' 's/--key-operator: #30d158;/--key-operator: #0a84ff;/' "$SOURCE/style.css"
    sleep 2
    check "window lists the unsaved change" "$(json "$WORK/edit-report/edit-report.json" "d['changes']")" "['modified: style.css']"
    "$WORK/post-notification" dev.japp.runtime.automation.editor saveAndRun
    if wait_for "$WORK/edit-report/report.json"; then
        pass "Save & Run launched the app"
        sleep 0.5
        "$JAPP" snapshot "$WORK/Calculator.japp" --output "$WORK/edited2.png" \
            --eval 'return getComputedStyle(document.querySelector("[data-operator]")).backgroundColor' > "$WORK/run4.json" 2>/dev/null
        check "saved change is in the app" "$(json "$WORK/run4.json" "d['scriptResult']")" "rgb(10, 132, 255)"
    else
        fail "Save & Run launched the app"
    fi
    "$WORK/post-notification" dev.japp.runtime.automation.editor close
    sleep 1
    [ -d "$SOURCE" ] && fail "closing removes the workspace" || pass "closing removes the workspace"
    pkill -f "JAppAutomationDir $WORK/edit-report" 2>/dev/null
else
    fail "Edit Source window opened the workspace"
fi

echo "==> Finder Services"
mkdir -p "$WORK/service-report"
if pgrep -x JAppRuntime >/dev/null; then
    echo "  (skipped: a JApp Runtime process is already running and would receive the request)"
else
    defaults write dev.japp.runtime JAppAutomationDir "$WORK/service-report"
    "$WORK/perform-service" "Edit JApp Source" "$WORK/Opened.japp" && pass "“Edit JApp Source” service accepted" || fail "“Edit JApp Source” service accepted"
    wait_for "$WORK/service-report/edit-report.json" && pass "service opened Edit Source" || fail "service opened Edit Source"
    defaults delete dev.japp.runtime JAppAutomationDir 2>/dev/null
    "$WORK/post-notification" dev.japp.runtime.automation.editor close
    sleep 1
    pkill -x JAppRuntime 2>/dev/null
    # The service ran outside the test's support dir; remove the workspace it created.
    if [ -f "$WORK/service-report/edit-report.json" ]; then
        rm -rf "$(dirname "$(json "$WORK/service-report/edit-report.json" "d['sourceFolder']")")"
    fi
fi

echo "==> Native HTTP (japp.http.fetch)"
mkdir -p "$WORK/www" "$WORK/Http"
echo '{"hello":"world"}' > "$WORK/www/data.json"
PORT=$((20000 + RANDOM % 20000))
(cd "$WORK/www" && exec /usr/bin/python3 -I -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SERVER=$!
sleep 1
echo '{"manifestVersion":1,"id":"dev.japp.e2e.http","name":"HTTP","version":"1","permissions":["network"]}' > "$WORK/Http/manifest.json"
echo '<!doctype html><title>HTTP</title>' > "$WORK/Http/index.html"
"$JAPP" snapshot "$WORK/Http" --output "$WORK/http.png" --eval "
  const out = {};
  const response = await japp.http.fetch('http://127.0.0.1:$PORT/data.json');
  out.native = response.status + ' ' + (await response.json()).hello;
  try { await fetch('http://127.0.0.1:$PORT/data.json'); out.browser = 'allowed'; } catch (e) { out.browser = 'blocked'; }
  try { await japp.http.fetch('file:///etc/hosts'); out.file = 'allowed'; } catch (e) { out.file = e.code; }
  return out;" > "$WORK/http.json" 2>/dev/null
kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null
check "japp.http.fetch reads an API without CORS headers" "$(json "$WORK/http.json" "d['scriptResult']['native']")" "200 world"
check "fetch() to the same API is blocked by CORS" "$(json "$WORK/http.json" "d['scriptResult']['browser']")" "blocked"
check "japp.http.fetch refuses file: URLs" "$(json "$WORK/http.json" "d['scriptResult']['file']")" "BAD_ARGUMENTS"
sed -i '' 's/"network"//' "$WORK/Http/manifest.json"
"$JAPP" snapshot "$WORK/Http" --output "$WORK/http2.png" --eval "try { await japp.http.fetch('http://127.0.0.1:1/'); return 'allowed'; } catch (e) { return e.code; }" > "$WORK/http2.json" 2>/dev/null
check "japp.http.fetch needs the network permission" "$(json "$WORK/http2.json" "d['scriptResult']")" "PERMISSION_DENIED"

echo "==> Native feel"
# Real right-clicks and hit tests at fixed points of Tests/E2E/NativeFeel (page coordinates).
"$JAPP" pack "$ROOT/Tests/E2E/NativeFeel" --output "$WORK/NativeFeel.japp" >/dev/null 2>&1
native_run() {  # native_run <target> <report dir> [extra runtime arguments]
    local target="$1" dir="$2"; shift 2
    mkdir -p "$dir"
    "$APP/Contents/MacOS/JAppRuntime" --host "$target" -JAppAutomationDir "$dir" -JAppAutomationQuit YES \
        -JAppSingleProcess YES -JAppSetFinderIcons NO "$@" >/dev/null 2>&1 &
    local pid=$!
    wait_for "$dir/report.json"; sleep 0.5
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}
native_run "$WORK/NativeFeel.japp" "$WORK/native" -JAppAutomationScript "$ROOT/Tests/E2E/native.test.js" \
    -JAppAutomationMenuChoice Second \
    -JAppAutomationProbePoints "250,26;340,26;400,350" \
    -JAppAutomationContextMenus "300,100;300,142;300,100,alt;240,190,alt"
N="$WORK/native/report.json"
if [ -f "$N" ]; then
    check "labels are not selectable" "$(json "$N" "d['scriptResult']['labelSelect']")" "none"
    check "text fields stay selectable" "$(json "$N" "d['scriptResult']['fieldSelect']")" "text"
    check "data-selectable opts text in" "$(json "$N" "d['scriptResult']['selectableSelect']")" "text"
    check "arrow cursor over text" "$(json "$N" "d['scriptResult']['labelCursor']")" "default"
    check "images do not drag" "$(json "$N" "d['scriptResult']['imageDrag']")" "none"
    check "the page does not rubber-band" "$(json "$N" "d['scriptResult']['overscroll']")" "none"
    check "window state reaches CSS" "$(json "$N" "d['scriptResult']['windowState'] in ('active', 'inactive')")" "True"
    check "title bar metrics reach CSS (hiddenInset)" "$(json "$N" "(d['scriptResult']['titlebarHeight'] >= 40, d['scriptResult']['titlebarInset'] >= 60)")" "(True, True)"
    check "page extends under a hidden title bar" "$(json "$N" "(d['native']['fullSizeContent'], d['native']['titleVisible'])")" "(True, False)"
    check "window material behind a transparent page" "$(json "$N" "(d['native']['contentView'], d['native']['drawsBackground'])")" "('NSVisualEffectView', False)"
    check "no browser commands in the menu bar" "$(json "$N" "[i for m in d['native']['menuBar'] for i in m['items'] if i in ('Reload App', 'Zoom In', 'Zoom Out', 'Actual Size')]")" "[]"
    check "View menu holds only Full Screen" "$(json "$N" "[m['items'] for m in d['native']['menuBar'] if m['title'] == 'View']")" "[['Enter Full Screen']]"
    check "drag region moves the window" "$(json "$N" "d['native']['probes'][0]['drag']")" "True"
    check "buttons in a drag region stay clickable" "$(json "$N" "d['native']['probes'][1]['drag']")" "False"
    check "content is not a drag region" "$(json "$N" "d['native']['probes'][2]['drag']")" "False"
    check "no context menu on labels (DOM)" "$(json "$N" "(d['scriptResult']['labelMenuPrevented'], d['scriptResult']['buttonMenuPrevented'])")" "(True, True)"
    check "text fields keep their context menu (DOM)" "$(json "$N" "d['scriptResult']['fieldMenuPrevented']")" "False"
    check "right-click on a label shows nothing" "$(json "$N" "d['contextMenus'][0]['shown']")" "False"
    check "right-click in a text field: edit menu, no browser items" \
        "$(json "$N" "('Copy' in [i['title'] for i in d['contextMenus'][1]['items']], [i['title'] for i in d['contextMenus'][1]['items'] if i['title'] in ('Reload', 'Inspect Element', 'Back', 'Forward')])")" "(True, [])"
    check "⌥-right-click offers Inspect Element only" "$(json "$N" "[i['title'] for i in d['contextMenus'][2]['items']]")" "['Inspect Element']"
    check "links have no Open/Download/Copy Link items" "$(json "$N" "[i['title'] for i in d['contextMenus'][3]['items'] if 'Link' in i['title']]")" "[]"
    check "japp.menu.popup returns the chosen id" "$(json "$N" "d['scriptResult']['menu']")" "second"
    check "japp.menu.popup shows a native menu with symbols" "$(json "$N" "(d['menus'][0]['items'], d['menus'][0]['symbols'])")" "(['First', '-', 'Second'], 1)"
    check "japp.menu.popup validates items" "$(json "$N" "d['scriptResult']['badMenu']")" "BAD_ARGUMENTS"
else
    fail "native-feel app ran" "no report"
fi
native_run "$ROOT/Tests/E2E/NativeFeel" "$WORK/native-dev" -JAppAutomationContextMenus "300,100"
D="$WORK/native-dev/report.json"
check "a folder runs in developer mode" "$(json "$D" "d['native']['developer']")" "True"
check "developer mode adds the Develop menu" "$(json "$D" "[m['items'][0] for m in d['native']['menuBar'] if m['title'] == 'Develop']")" "['Reload App']"
check "developer mode: Inspect Element without ⌥" "$(json "$D" "[i['title'] for i in d['contextMenus'][0]['items']]")" "['Inspect Element']"

echo "==> Hostile and broken apps"
$PY -c "
import zipfile, sys
z = zipfile.ZipFile(sys.argv[1], 'w')
z.writestr('manifest.json', '{\"manifestVersion\":1,\"id\":\"a.b\",\"name\":\"S\",\"version\":\"1\"}')
z.writestr('index.html', 'x')
z.writestr('../../evil.txt', 'pwned')
z.close()" "$WORK/Slip.japp"
"$JAPP" validate "$WORK/Slip.japp" >/dev/null 2>&1 && fail "ZIP Slip archive rejected" || pass "ZIP Slip archive rejected"
"$JAPP" unpack "$WORK/Slip.japp" "$WORK/slip" >/dev/null 2>&1; [ -e "$WORK/evil.txt" ] || [ -e "$WORK/slip" ] && fail "nothing extracted from ZIP Slip archive" || pass "nothing extracted from ZIP Slip archive"
mkdir -p "$WORK/Broken" && echo '{"manifestVersion":1,"id":"nodots","name":"B","version":"1"}' > "$WORK/Broken/manifest.json" && echo x > "$WORK/Broken/index.html"
"$JAPP" snapshot "$WORK/Broken" --output "$WORK/broken.png" > "$WORK/broken.json" 2>/dev/null
check "broken manifest reported, not run" "$(json "$WORK/broken.json" "d['ok']")" "False"
cp "$WORK/Calculator.japp" "$WORK/Downloaded.japp"
xattr -w com.apple.quarantine "0081;00000000;Safari;" "$WORK/Downloaded.japp"
"$JAPP" snapshot "$WORK/Downloaded.japp" --output "$WORK/quarantine.png" > "$WORK/quarantine.json" 2>/dev/null
check "downloaded (quarantined) app needs confirmation" "$(json "$WORK/quarantine.json" "'quarantined' in d.get('error', '')")" "True"

echo
echo "$PASS passed, $FAIL failed. Artifacts: $WORK"
[ "$FAIL" -eq 0 ]
