#!/bin/zsh
# Renders the README images in Docs/images with JApp itself.
#
# Every figure is a page of this folder. It runs headlessly in JApp Runtime (the
# automation hooks behind `japp snapshot`) at the window size given below, and
# the page's snapshot is saved at 2× — in a light and a dark version, or once
# for pictures on a desktop background.
#
#   Docs/images/src/make.sh               retake the app screenshots, render everything
#   Docs/images/src/make.sh loop hero     render only these figures (screenshots reused)
#
# Needs JApp Runtime in /Applications and the examples built (Scripts/build.sh).
# The Chess Results screenshot needs network access (Easy Chess Results API).
# Screenshots run the real apps with their stored data: what an app shows (Chess
# Results' bookmarks) appears in the picture, and Chess Results caches the
# tournaments it found. Nothing else is written.
set -euo pipefail
src=${0:A:h}; images=${src:h}; repo=${images:h:h}
runtime="/Applications/JApp Runtime.app/Contents/MacOS/JAppRuntime"
work=$(mktemp -d -t japp-figures)
trap 'rm -rf "$work"' EXIT

# run <app file or folder> <script.js> <directory>: runs the app once, headlessly.
# Leaves report.json, snapshot.png (the page) and window.png (with title bar).
run() {
  mkdir -p "$3"
  "$runtime" --host "$1" -JAppAutomationDir "$3" -JAppAutomationQuit YES -JAppSingleProcess YES \
    -JAppSetFinderIcons NO -JAppAutomationScript "$2" 2>/dev/null &
  local pid=$! i
  for i in {1..600}; do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
  kill $pid 2>/dev/null || true
  if [[ ! -f "$3/snapshot.png" ]]; then print -u2 "No snapshot of $1"; exit 1; fi
  if grep -q '"scriptError"' "$3/report.json"; then print -u2 "Script failed for $1:"; cat "$3/report.json" >&2; exit 1; fi
}

# shoot <name> <app> [script.js]: a screenshot of the app's whole window, into shots/.
shoot() {
  local script=${3:-$work/empty.js}
  run "$2" "$script" "$work/shot-$1"
  cp "$work/shot-$1/window.png" "$src/shots/$1.png"
  print "shots/$1.png"
}

# figure <page> <width> <height> [wallpaper <variant>]: renders <page>.html.
figure() {
  local page=$1 width=$2 height=$3 mode=${4:-themes} variant=${5:-}
  local site=$work/site themes=(light dark) theme out
  [[ $mode == wallpaper ]] && themes=(light)
  rm -rf "$site"; mkdir -p "$site"
  cp -R "$src/assets" "$src/shots" "$src/figures.css" "$src/figures.js" "$src/$page.html" "$site/"
  cat > "$site/manifest.json" <<JSON
{ "manifestVersion": 1, "id": "dev.japp.readme-figures", "name": "README Figures", "version": "1.0.0",
  "entry": "$page.html", "window": { "width": $width, "height": $height, "resizable": false } }
JSON
  for theme in $themes; do
    cat > "$work/figure.js" <<JS
document.documentElement.dataset.theme = "$theme";
document.documentElement.dataset.variant = "$variant";
await document.fonts.ready;
await Promise.all([...document.images].map(image => image.decode().catch(() => {})));
await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
JS
    run "$site" "$work/figure.js" "$work/figure-$page-$variant-$theme"
    if [[ $mode == wallpaper ]]; then
      # Photos of a desktop: JPEG is a quarter of the size of PNG for the gradient.
      out=$images/${variant:-$page}.jpg
      sips -s format jpeg -s formatOptions 88 "$work/figure-$page-$variant-$theme/snapshot.png" --out "$out" >/dev/null
    else
      out=$images/$page-$theme.png
      cp "$work/figure-$page-$variant-$theme/snapshot.png" "$out"
    fi
    print "${out#$repo/}"
  done
}

mkdir -p "$src/shots"; : > "$work/empty.js"
if (( $# == 0 )); then
  shoot calculator "$repo/build/Calculator.japp" "$src/scripts/calculator.js"
  shoot calculator-green "$repo/build/Calculator.japp" "$src/scripts/calculator-green.js"
  shoot paint "$repo/build/Paint.japp" "$src/scripts/paint.js"
  shoot chess "$repo/build/ChessResults.japp" "$src/scripts/chess.js"
  /usr/local/bin/japp new "Hello World" --dir "$work" >/dev/null
  shoot hello "$work/Hello World"
  /usr/local/bin/japp storage "$work/Hello World" --clear >/dev/null 2>&1 || true
fi

typeset -a only=("$@")
for spec in \
  "hero 1000 470" \
  "loop 1000 550" \
  "desktop 1000 620 wallpaper desktop" \
  "app 640 440 wallpaper app-calculator" \
  "app 640 440 wallpaper app-chess" \
  "app 640 440 wallpaper app-paint" \
  "app 640 440 wallpaper app-hello" \
  "anatomy 1000 560" \
  "new-app 1000 470" \
  "bridge 1000 540" \
  "architecture 1000 510" \
  "security 1000 450"; do
  set -- ${=spec}
  if (( ${#only} )) && ! (( ${only[(Ie)$1]} || ${only[(Ie)${5:-}]} )); then continue; fi
  figure "$@"
done
