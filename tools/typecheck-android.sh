#!/usr/bin/env bash
#
# Type-checks the whole app module — including the Compose UI — without Android
# Studio, Gradle or the Android SDK installed.
#
# It downloads android.jar and the library artifacts into a cache directory, then
# runs kotlinc against them with the Compose and kotlinx.serialization compiler
# plugins that ship with the Kotlin distribution.
#
# What this DOES catch: every Kotlin type and API-signature error, wrong
# SensorManager / CameraX / Room / Retrofit / Compose usage, and whether
# @Serializable classes generate their serializers.
#
# What it does NOT catch: resource linking (AndroidManifest, themes, strings),
# Room's KSP code generation, R8, and anything about runtime behaviour on a real
# device. Those still need `./gradlew assembleDebug`.
#
# Requirements:
#   KOTLIN_HOME  an unpacked kotlin-compiler release (the dir holding lib/)
#   curl, unzip
#
# Usage:
#   KOTLIN_HOME=~/kotlinc tools/typecheck-android.sh
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${KOTLIN_HOME:?set KOTLIN_HOME to an unpacked kotlin-compiler release}"

cache="${TYPECHECK_CACHE:-$here/build/typecheck-deps}"
libs="$cache/libs"
out="$here/build/typecheck-classes"
mkdir -p "$libs"

native() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

GOOGLE=https://dl.google.com/dl/android/maven2
CENTRAL=https://repo1.maven.org/maven2

# Fetches a plain jar.
jar() {
    local name="$2"
    [ -s "$libs/$name.jar" ] && return 0
    curl -fsSL -o "$libs/$name.jar" "$1" || { echo "failed: $name" >&2; return 1; }
}

# Fetches an aar and extracts its classes.jar.
aar() {
    local name="$2"
    [ -s "$libs/$name.jar" ] && return 0
    curl -fsSL -o "$libs/tmp.aar" "$1" || { echo "failed: $name" >&2; return 1; }
    unzip -p "$libs/tmp.aar" classes.jar > "$libs/$name.jar"
    rm -f "$libs/tmp.aar"
}

# --- android.jar -----------------------------------------------------------
if [ ! -s "$cache/android.jar" ]; then
    echo "fetching android.jar (API 35)"
    curl -fsSL -o "$cache/platform.zip" \
        https://dl.google.com/android/repository/platform-35_r02.zip
    unzip -o -q -j "$cache/platform.zip" "*/android.jar" -d "$cache"
    rm -f "$cache/platform.zip"
fi

# --- libraries -------------------------------------------------------------
#
# Room and Compose are pinned to the last versions published in the classic
# (non-KMP) artifact layout, which is all a flat classpath can consume. The API
# surface this module uses is identical to the versions in libs.versions.toml.
#
echo "fetching library artifacts into $libs"

C=1.7.6           # androidx.compose.{runtime,ui,foundation,animation}
M3=1.3.1          # androidx.compose.material3
ROOM=2.6.1        # classic layout; the app builds against 2.7.0
LC=2.8.7          # androidx.lifecycle
CAM=1.4.1         # androidx.camera
GMS_LOC=21.3.0

jar "$CENTRAL/org/jetbrains/kotlinx/kotlinx-coroutines-core-jvm/1.10.1/kotlinx-coroutines-core-jvm-1.10.1.jar" coroutines-core
jar "$CENTRAL/org/jetbrains/kotlinx/kotlinx-coroutines-android/1.10.1/kotlinx-coroutines-android-1.10.1.jar" coroutines-android
jar "$CENTRAL/org/jetbrains/kotlinx/kotlinx-serialization-core-jvm/1.8.0/kotlinx-serialization-core-jvm-1.8.0.jar" serialization-core
jar "$CENTRAL/org/jetbrains/kotlinx/kotlinx-serialization-json-jvm/1.8.0/kotlinx-serialization-json-jvm-1.8.0.jar" serialization-json
jar "$CENTRAL/com/squareup/retrofit2/retrofit/2.11.0/retrofit-2.11.0.jar" retrofit
jar "$CENTRAL/com/jakewharton/retrofit/retrofit2-kotlinx-serialization-converter/1.0.0/retrofit2-kotlinx-serialization-converter-1.0.0.jar" retrofit-serialization
jar "$CENTRAL/com/squareup/okhttp3/okhttp/4.12.0/okhttp-4.12.0.jar" okhttp
jar "$CENTRAL/com/squareup/okhttp3/logging-interceptor/4.12.0/logging-interceptor-4.12.0.jar" okhttp-logging
jar "$CENTRAL/com/squareup/okio/okio-jvm/3.6.0/okio-jvm-3.6.0.jar" okio
jar "$CENTRAL/com/google/guava/guava/33.3.1-android/guava-33.3.1-android.jar" guava

jar "$GOOGLE/androidx/annotation/annotation-jvm/1.9.1/annotation-jvm-1.9.1.jar" annotation
jar "$GOOGLE/androidx/lifecycle/lifecycle-common-jvm/$LC/lifecycle-common-jvm-$LC.jar" lc-common
jar "$GOOGLE/androidx/room/room-common/$ROOM/room-common-$ROOM.jar" room-common

aar "$GOOGLE/androidx/core/core/1.15.0/core-1.15.0.aar" androidx-core
aar "$GOOGLE/androidx/savedstate/savedstate/1.2.1/savedstate-1.2.1.aar" savedstate
aar "$GOOGLE/androidx/room/room-runtime/$ROOM/room-runtime-$ROOM.aar" room-runtime
aar "$GOOGLE/androidx/room/room-ktx/$ROOM/room-ktx-$ROOM.aar" room-ktx
aar "$GOOGLE/androidx/sqlite/sqlite/2.4.0/sqlite-2.4.0.aar" sqlite

for a in runtime:runtime runtime:runtime-saveable ui:ui ui:ui-graphics ui:ui-unit \
         ui:ui-text ui:ui-geometry ui:ui-util foundation:foundation \
         foundation:foundation-layout animation:animation animation:animation-core; do
    group=${a%%:*}; artifact=${a#*:}
    aar "$GOOGLE/androidx/compose/$group/$artifact-android/$C/$artifact-android-$C.aar" "cmp-$artifact"
done
aar "$GOOGLE/androidx/compose/material3/material3-android/$M3/material3-android-$M3.aar" cmp-material3

aar "$GOOGLE/androidx/activity/activity/1.9.3/activity-1.9.3.aar" activity
aar "$GOOGLE/androidx/activity/activity-compose/1.9.3/activity-compose-1.9.3.aar" activity-compose
aar "$GOOGLE/androidx/navigation/navigation-common/2.8.4/navigation-common-2.8.4.aar" nav-common
aar "$GOOGLE/androidx/navigation/navigation-runtime/2.8.4/navigation-runtime-2.8.4.aar" nav-runtime
aar "$GOOGLE/androidx/navigation/navigation-compose/2.8.4/navigation-compose-2.8.4.aar" nav-compose
aar "$GOOGLE/androidx/lifecycle/lifecycle-runtime-android/$LC/lifecycle-runtime-android-$LC.aar" lc-runtime
aar "$GOOGLE/androidx/lifecycle/lifecycle-runtime-compose-android/$LC/lifecycle-runtime-compose-android-$LC.aar" lc-runtime-compose
aar "$GOOGLE/androidx/lifecycle/lifecycle-viewmodel-android/$LC/lifecycle-viewmodel-android-$LC.aar" lc-vm
aar "$GOOGLE/androidx/lifecycle/lifecycle-viewmodel-compose-android/$LC/lifecycle-viewmodel-compose-android-$LC.aar" lc-vm-compose
aar "$GOOGLE/androidx/lifecycle/lifecycle-viewmodel-savedstate/$LC/lifecycle-viewmodel-savedstate-$LC.aar" lc-vm-savedstate

for c in camera-core camera-view camera-lifecycle camera-camera2; do
    aar "$GOOGLE/androidx/camera/$c/$CAM/$c-$CAM.aar" "$c"
done
aar "$GOOGLE/com/google/android/gms/play-services-location/$GMS_LOC/play-services-location-$GMS_LOC.aar" gms-location
aar "$GOOGLE/com/google/android/gms/play-services-base/18.5.0/play-services-base-18.5.0.aar" gms-base
aar "$GOOGLE/com/google/android/gms/play-services-basement/18.4.0/play-services-basement-18.4.0.aar" gms-basement
aar "$GOOGLE/com/google/android/gms/play-services-tasks/18.2.0/play-services-tasks-18.2.0.aar" gms-tasks

# --- BuildConfig stub ------------------------------------------------------
# AGP generates this from the `buildConfigField` entries in build.gradle.kts.
mkdir -p "$cache/stub"
cat > "$cache/stub/BuildConfig.kt" <<'STUB'
package com.fieldar.plotfinder

object BuildConfig {
    const val DEBUG = true
    const val PLOT_API_BASE_URL = "http://10.0.2.2:4000/"
}
STUB

# --- compile ---------------------------------------------------------------
sep=':'
case "${OSTYPE:-}" in msys* | cygwin* | win32) sep=';' ;; esac

cp="$(native "$cache/android.jar")"
for j in "$libs"/*.jar; do cp="${cp}${sep}$(native "$j")"; done

mapfile -t sources < <(find "$here/app/src/main/kotlin" -name '*.kt' | sort)
echo "type-checking ${#sources[@]} files"

rm -rf "$out"
java -cp "$(native "$KOTLIN_HOME/lib/kotlin-compiler.jar")" \
    org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
    -nowarn -jvm-target 17 -cp "$cp" -d "$(native "$out")" \
    -Xplugin="$(native "$KOTLIN_HOME/lib/compose-compiler-plugin.jar")" \
    -Xplugin="$(native "$KOTLIN_HOME/lib/kotlinx-serialization-compiler-plugin.jar")" \
    "${sources[@]}" "$(native "$cache/stub/BuildConfig.kt")"

echo "OK — $(find "$out" -name '*.class' | wc -l) classes"
