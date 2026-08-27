#!/usr/bin/env bash
#
# Runs the pure-Kotlin unit tests in `core/` on a plain JVM, without Gradle and
# without the Android SDK.
#
# `core.geo` and `core.heading` deliberately import nothing from Android, so the
# maths that decides where the overlay lands can be verified anywhere - including
# on a machine that cannot build the app. `./gradlew test` runs the same files.
#
# Requirements:
#   KOTLIN_HOME  an unpacked kotlin-compiler release (the dir holding lib/)
#   JUNIT_CP     classpath with junit 4 and hamcrest-core, separated by the
#                platform's path separator (';' on Windows, ':' elsewhere)
#
# Example:
#   KOTLIN_HOME=~/kotlinc \
#   JUNIT_CP="$HOME/jars/junit.jar:$HOME/jars/hamcrest.jar" \
#   tools/run-core-tests.sh
#
# The compiler is launched as a jar rather than through kotlinc/kotlinc.bat: the
# Windows wrapper goes through cmd, which eats the ';' in a classpath.
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${KOTLIN_HOME:?set KOTLIN_HOME to an unpacked kotlin-compiler release}"
: "${JUNIT_CP:?set JUNIT_CP to a classpath containing junit and hamcrest}"

sep=':'
case "${OSTYPE:-}" in msys* | cygwin* | win32) sep=';' ;; esac

# Under Git Bash the JVM needs native paths, not the shell's /d/... form.
native() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

compiler="$KOTLIN_HOME/lib/kotlin-compiler.jar"
stdlib="$KOTLIN_HOME/lib/kotlin-stdlib.jar"
[ -f "$compiler" ] || { echo "no kotlin-compiler.jar under $KOTLIN_HOME/lib" >&2; exit 1; }

out="${OUT_DIR:-$here/build/core-tests}"
rm -rf "$out"
mkdir -p "$out"

main_src="$here/app/src/main/kotlin/com/fieldar/plotfinder/core"
test_src="$here/app/src/test/kotlin/com/fieldar/plotfinder/core"

mapfile -t sources < <(find "$main_src" "$test_src" -name '*.kt' | sort)
echo "compiling ${#sources[@]} files"
java -cp "$(native "$compiler")" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -nowarn -cp "$JUNIT_CP" -d "$(native "$out")" "${sources[@]}"

# Every file named *Test.kt holds one test class named after the file.
classes=()
while IFS= read -r file; do
    rel="${file#"$here/app/src/test/kotlin/"}"
    classes+=("$(echo "${rel%.kt}" | tr '/' '.')")
done < <(find "$test_src" -name '*Test.kt' | sort)

echo "running ${#classes[@]} test classes"
java -cp "$(native "$out")${sep}${JUNIT_CP}${sep}$(native "$stdlib")" \
    org.junit.runner.JUnitCore "${classes[@]}"
