#!/usr/bin/env bash
#
# Renders the simulation demo to PNGs, with no phone and no emulator.
#
# The frames are produced by the shipping code: real plots from the companion
# API put through the app's own DTO -> entity -> domain mapping, a real
# SimulationEngine, a real HeadingFusion, and `buildPlotOverlay`. Only the camera
# preview (a painted horizon) and the drawing calls (Java2D instead of Compose)
# are substituted.
#
# Requirements:
#   KOTLIN_HOME  an unpacked kotlin-compiler release
#   the plot-web API running on :4000, or a plots JSON passed as $1
#
# Usage:
#   KOTLIN_HOME=~/kotlinc tools/render-demo.sh [plots.json]
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${KOTLIN_HOME:?set KOTLIN_HOME to an unpacked kotlin-compiler release}"

cache="${TYPECHECK_CACHE:-$here/build/typecheck-deps}"
out="$here/build/demo"
classes="$here/build/demo-classes"
plots="${1:-$here/build/demo-plots.json}"

native() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# The dependency cache is shared with the type check; build it if it is missing.
if [ ! -s "$cache/android.jar" ]; then
    echo "fetching dependencies via typecheck-android.sh"
    "$here/tools/typecheck-android.sh" >/dev/null
fi

if [ ! -s "$plots" ]; then
    echo "fetching plots from the API"
    mkdir -p "$(dirname "$plots")"
    curl -fsS http://localhost:4000/api/plots -o "$plots"
fi

sep=':'
case "${OSTYPE:-}" in msys* | cygwin* | win32) sep=';' ;; esac

cp="$(native "$cache/android.jar")"
for j in "$cache/libs"/*.jar; do cp="${cp}${sep}$(native "$j")"; done

mapfile -t sources < <(find "$here/app/src/main/kotlin" "$here/tools/demo" -name '*.kt' | sort)
echo "compiling ${#sources[@]} files"

rm -rf "$classes"
java -cp "$(native "$KOTLIN_HOME/lib/kotlin-compiler.jar")" \
    org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -nowarn -jvm-target 17 -cp "$cp" -d "$(native "$classes")" \
    -Xplugin="$(native "$KOTLIN_HOME/lib/compose-compiler-plugin.jar")" \
    -Xplugin="$(native "$KOTLIN_HOME/lib/kotlinx-serialization-compiler-plugin.jar")" \
    "${sources[@]}" "$(native "$cache/stub/BuildConfig.kt")"

rm -rf "$out"
java -cp "$(native "$classes")${sep}${cp}${sep}$(native "$KOTLIN_HOME/lib/kotlin-stdlib.jar")" \
    com.fieldar.plotfinder.demo.OverlayDemoKt "$(native "$plots")" "$(native "$out")"

echo
echo "frames in $out"
