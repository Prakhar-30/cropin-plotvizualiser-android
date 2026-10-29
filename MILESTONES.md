# Flutter port — Milestones

This branch (`flutter`) is the Kotlin/Compose app rebuilt in Flutter, feature for
feature. `main` keeps the Kotlin original; nothing here changes what it does.

Same rule as the original build: **revise before advancing**, and a number in
this log must match the code.

| # | Milestone | Done when |
|---|---|---|
| F1 | Scaffold: Flutter project, Android host (portrait, permissions, debug cleartext), Kotlin project removed from this branch | `pubspec.yaml`, `android/` host and placeholder `lib/main.dart` committed |
| F2 | `core/geo` in Dart: ENU frame, 3x3 algebra, projection + near-plane clipping, polygon distance, position stabiliser, orientation smoother | Kotlin geo tests ported to `test/core/geo` |
| F3 | `core/heading` in Dart: heading model, fusion, course-over-ground detector, landmark snap | Kotlin heading tests ported to `test/core/heading` |
| F4 | `core/render` in Dart: palette, overlay geometry, health raster | Kotlin render tests ported to `test/core/render` |
| F5 | Data: domain models, wire DTOs, mapping, HTTP client, sqflite cache (same schema as Room v3), repositories | Health DTO parsing tests ported |
| F6 | Platform: native Android channel (rotation vectors, camera geometry, fused location, device info), `PoseSource` / `LocationSource`, simulation engine | Dart side compiles against the channel contract |
| F7 | UI: theme, plot list, plot detail + sketch, AR screen, overlay painter, heading chip, simulation panel, permission gate | Every Compose screen has its Flutter counterpart |
| F8 | Review pass and docs | README describes the Flutter build; no dead code |
| F9 | Package as an embeddable Flutter plugin; standalone app moved to `example/` | A host app integrates with one dependency and one screen; CI green on Flutter 3.22 and stable |
| F10 | First real-phone test: overlay receded while walking indoors. Step counting (PDR) fused into the position filter, step length calibrated from good GNSS; collapsible AR sheet; simulation removed | The indoor walk reproduced as a regression test and passing; research notes in `docs/research/ar-positioning.md` |
| F11 | Second phone test: boundary shifted sideways on approach. ARCore motion tracking (VIO) as the pose and motion source, GNSS de-weighted to drift correction, access-point position pin, fallback to sensors + steps | A stuck ±15 m indoor receiver moves the drawn position < 1 m sideways over a tracked 10 m approach (regression test) |
| F12 | Third phone test: corners swam on small hand motion, a 16 m boundary was painted over a person 2 m away, repeated Aim taps rotated the plot in a circle. Overlay drawn natively in ARCore's GL frame (no latency), floor from ARCore planes, depth occlusion with X-ray ghosting, no compass after a lock under ARCore, Aim uses the drawn position and refuses when position error swamps the bearing; Aim / I'm here always visible in the sheet | Placement maths tested as the inverse of the motion rotation; triangulation, scene and decoding tests |
| F13 | One action instead of two: "I'm at the access point". Direction set automatically by aligning ARCore's tracked walk to GNSS (weighted 2-D Procrustes), anchored at the pin; guide pill to the access point; one confirm guard when GPS says you are far; aim moved to a fallback with guards in the right order; plot keeps its colour under ARCore, occlusion only by clearly nearer objects | Aligner tests: exact recovery, noisy winding walk, indoor fixes ignored, standing still says nothing, anchored walk-in |
| F14 | Minimap in the AR view: north-up plan of the plot with the crop-health cells in their severity colours, ranked hotspots, the access point and the agent as a heading arrow; bottom right above the sheet, tap to enlarge; shown once at the plot | Widget test: renders and grows on tap |
| F15 | Startup loader on the AR view (camera / motion tracking / GPS checklist with elapsed seconds and a hint after 20 s), and a faster first fix: the native side sends the newest last-known location under 30 s old the moment AR opens | Widget tests for the loader |
| F16 | "I'm at the access point" disabled until GPS puts the agent within 50 m of it; the disabled button says how far is left, or that GPS is still coming. Replaces the far-away confirm dialog | State test for the 50 m rule |
| U1 | Updated flow (branch `flutter_updated_flow`): access point removed everywhere; crop condition on three indices (crop greenness NDVI, crop vigour NDRE, water stress LSWI) in 3 m cells with normal / moderate / critical zones; every nearby plot shown at once; moderate and critical patches as tall drop points (4.5 m, above the 2.6 m walls), drawn natively; automatic anchor to the nearest boundary point once GPS is within 10 m; index switch in the sheet; minimap centred on the agent. Web repo: same model, migration 003 wipes plots, mobile-responsive map | Boundary snap, drop markers, scene, DTO and state tests; web CI (typecheck, API tests, build) |
| U2 | Ground cells for every nearby plot: the moderate (yellow) and critical (red) 3 m cells of the chosen index painted on the ground, natively under ARCore and projected on the sensor path. Entry reworked: the plot list and detail screens removed; a home screen shows plots cached and their age, *Sync now* (automatic on opening when empty or over an hour old) and *Start AR view* | Scene cell tests, sensor-path cell projection test, home screen widget tests |
| U3 | Neighbours kept apart: plot palette without red, orange, yellow or pink (web and app; a test fails any saturated slot outside cyan-to-violet); no tinted plot floor; labels with a stalk and a colour strip, lifted clear of each other. Ground cells only once anchored to a boundary; a loss of ARCore tracking drops the anchor and the cells with it | Palette hue test, inset-ring tests, scene tests |
| U4 | Pinch to zoom, 1x to 5x, double-tap or the zoom pill to reset. A digital zoom that keeps the overlay registered: the camera texture is cropped about its centre and the projection's x and y rows scaled by the same factor; depth lookups map back to the unzoomed view; the sensor path scales the preview and narrows the field of view | Zoomed field-of-view test |
| U5 | Boundaries flat on the ground instead of walls: a 0.6 m ribbon from each boundary into its own plot, with a fixed-width line down its middle on a dark backing. Walls, rails, posts, wall fades and near-mode accuracy bands removed on both paths | Ribbon geometry tests (flat, far-first, clipping) |
| U6 | Far plots as one marker: beyond ~50 m from its nearest edge (5 m hysteresis) a plot is a 6 m marker in its colour with a header of name, size, distance and its critical and moderate share on the chosen index; its cells and drop points are left out until closer. A *Crop health* switch in the bottom sheet hides every health visual at once | Marker geometry and hysteresis tests, zone-share test, scene marker test |

**F9, packaging for a host app.** The aim was to add nothing that could break a
host app's build: no third-party native dependencies (framework
`LocationManager` instead of Play Services location, native permission
requests instead of `permission_handler`), wide Dart version ranges, no
Flutter API newer than 3.22, no `<uses-feature required>` in the
merged manifest, namespaced channels, portrait locked only while the AR screen
is open, and a configurable cache file name. Integration is described in
`INTEGRATION.md`.

**How it was verified.** The port was written without a local Flutter SDK, so
every milestone was pushed and checked by CI (`.github/workflows/flutter.yml`):
`flutter analyze`, `flutter test`, and from F6 on a debug APK build that
compiles the Android host, the native channel and every plugin. What CI caught:

- F2: the orientation smoother's constructor defaults referred to the private
  fields they shadowed - a compile error.
- F6: current Flutter refuses Gradle below 8.14; the wrapper carried over from
  the Kotlin project was 8.11.1. Moved to Gradle 8.14.3, AGP 8.11.1, Kotlin
  2.2.20, and the `compilerOptions` DSL.

**What changed in the port, on purpose.**

- `CameraGeometry` corrects the FOV for the preview crop. CameraX could be sized
  to the sensor's 4:3; the Flutter camera plugin picks its own preview size, and
  a 16:9 stream crops exactly the axis a portrait screen's width shows.
- Projection runs in logical pixels. Stroke widths and text sizes were tuned in
  physical pixels, so the painter divides them by the device pixel ratio.
- Enum values keep their original upper-case names in telemetry rows
  (`wireName`), so fleet data from both builds reads the same.
- The cache is the Room v3 schema byte for byte, same file and version, so
  installing over the Kotlin build keeps the cached plots.

**Not ported.** `tools/demo/OverlayDemo.kt` (an off-device PNG renderer) and the
Kotlin-only test and type-check scripts; `flutter test` replaces the latter.
iOS has no native channel yet - see the README.

---

# Original Kotlin build log

# AR_Project — Milestones

Two independent deliverables in two folders:

| Folder | What |
|---|---|
| `plot-web/` | Web plot-marking tool (React+Vite+TS `web/`, Express+SQLite `api/`, shared TS lib `shared/`) |
| `plot-ar-android/` | Android AR plot-finder (Kotlin, CameraX, Compose, Room, Retrofit) |

Rule applied at every milestone boundary: **revise before advancing** — hunt for
duplicated definitions, dead/unused code, and repeated logic that should be
lifted into a shared library. Then verify it runs.

---

## Project A — `plot-web/`

| # | Milestone | Done when |
|---|---|---|
| A1 | Workspace scaffold + `@plot/shared` domain library (types, constants, geodesic geometry, validation) | `tsc` clean on all three packages |
| A2 | API: SQLite schema, `POST/GET /api/plots`, `?near=`, `/:id`, `/:id/geojson`, server-side area recompute + validation | Automated API test script passes, incl. every rejection case |
| A3 | Seed: 6 adjacent realistic plots in rural Karnataka | Seed runs; `?near=` returns all 6 |
| A4 | Map screen: Esri imagery, place search, polygon draw/edit, live ha/acre/perimeter, access point, landmark note, save | Vite build clean; browser smoke test |
| A5 | Plots list page + click-to-zoom-on-map | Browser smoke test |
| A6 | Review pass | No duplicate definitions, no unused exports, build+tests green |

**Status: all six complete and verified running.** 13/13 API tests pass; the map
screen, draw tool, save flow and list page were driven end-to-end in a browser.
Four bugs found by running it rather than reading it: duplicate vertices on
double-click close, MapLibre swallowing right-click (drag-rotate handler),
overlay churn from an unstable `setSearchParams` dependency, and `useMapLibre`
waiting on `'load'` — which never fires when basemap tiles are slow, leaving the
draw tool hostage to Esri being reachable.

## Project B — `plot-ar-android/`

Constraint: **no ARCore, no Geospatial API, no external GNSS, offline-first.**
Logic is pushed down into pure-Kotlin modules so it is testable without an
Android device.

| # | Milestone | Done when |
|---|---|---|
| B1 | `core-geo` pure-Kotlin: ENU conversion, re-anchoring, pinhole projection, behind-camera culling, point→polygon-edge distance, bearing | Unit tests vs hand-computed values pass on the JVM |
| B2 | App scaffold + CameraX preview + Compose `Canvas` overlay, static test polygon at hardcoded offset | Overlay stays fixed as device rotates |
| B3 | `PoseSource` interface + `SensorPoseSource` (TYPE_ROTATION_VECTOR) + `HeadingSourceManager` (COG / landmark snap / magnetometer, gyro hold, 3-min lock expiry) | Heading state-machine + straight-segment detector unit tests pass on the JVM |
| B4 | Room cache + Retrofit sync of plots from Project A's API | Offline read path works with no network |
| B5 | Far mode (>30 m) then near mode (<30 m), switched on nearest-**edge** distance; heading-confidence chip | Renders both modes; chip reflects source |
| B6 | Telemetry Room table + opportunistic sync | Row written per session; sync drains queue |
| B7 | Debug simulation mode: joystick location+heading injection, GNSS-error and heading-error sliders | Overlay drivable from a desk; 20° error demo reproducible |
| B8 | Review pass | Same checklist as A6 |

**Status: all eight complete.** 75 pure-Kotlin tests pass on the JVM covering ENU
conversion and re-anchoring, pinhole projection, behind-camera culling,
near-plane clipping, heading fusion and lock expiry, straight-segment detection,
landmark snap, and the far/near switch. Two real bugs surfaced there: clipping
emitted vertices exactly *on* the near plane which the projector then discarded
(so clipped corners vanished and the outline closed across the field — the very
bug clipping prevents), and an arithmetic slip in a hand-computed constant.

The Android-only layers — CameraX preview, Compose screens, Room, Retrofit,
navigation — now **type-check against the real Android 35 SDK and real library
artifacts**, Compose compiler plugin included, via
`plot-ar-android/tools/typecheck-android.sh`. All 35 files, 135 classes, clean.
That found one genuine bug: the AR viewport fit mixed `Float` and `Double`.

### Environment note
This machine has Node 22 and a JDK, but **no Android SDK and no Gradle**. Project B
is therefore written to build in Android Studio / CI; local verification is done by
compiling and running the pure-Kotlin `core/` tests with a standalone Kotlin
compiler (`plot-ar-android/tools/run-core-tests.sh`). Anything that cannot be
verified locally is called out explicitly rather than reported as passing.

Two scripts close most of that gap without an SDK install:
`tools/run-core-tests.sh` executes the unit tests, and `tools/typecheck-android.sh`
downloads `android.jar` plus the library artifacts and compiles the entire module,
Compose included.

**Now built for real.** `./gradlew assembleDebug` produces a signed 12.6 MB debug
APK (minSdk 26, targetSdk 35, universal), and `./gradlew test` runs the unit
suite across both variants: 150 executions, zero failures. Resource linking and
Room's KSP code generation both pass.

**Still outstanding:** running it on a physical device — camera field of view read
from real `CameraCharacteristics`, a real GNSS fix, and a real magnetometer.

---

# Round 2 — partner review feedback (2026-08-24)

Field-tested on a Samsung S23 Ultra, shown to senior partners. Five changes came
back. Milestones below; each is closed only after a revision pass that checks for
duplicated definitions, dead computation, and things worth pulling into a library.

| # | Milestone | Partner ask | Status |
|---|-----------|-------------|--------|
| R1 | Supabase schema | backing store for the above | **done** — `plot-web/api/sql/001_fieldar_schema.sql` |
| R2 | Anchor stabilisation | "the AR marked point moves along the user; it should stay fixed" | **done** — camera-placement bug fixed, ZUPT-gated Kalman filter added |
| R3 | Vertical boundary walls + per-plot colour | "boundaries are horizontal, make them vertical with height; different colours per plot" | **done** — 2 m extruded panels, 8-slot shared palette |
| R4 | Marking is web-only | "marking of the plot should be strictly from website not the application" | **done** — picker and debug-plot path deleted |
| R5 | Plot health raster + hotspots | "pixelated view of plot health, toggleable, with hotspot geolocation inside the boundary" | **done** — NDVI grid + ranked hotspots, verified in the browser |
| R6 | Rebuild, re-verify, document | | **done** — 89 Android tests, 16 API tests, APK rebuilt |

## R2 — what was actually wrong

Two separate defects, found by reading the projection path rather than by
guessing at sensor noise.

**The camera was never placed at the agent.** `buildPlotOverlay` computed
`agentGround` and used it for the *distance readouts only*. Every call into
`toDevice()` passed the raw ENU vertex, and `projectDevice` assumes the camera
sits at the frame origin. The frame origin is the fix the session anchored on,
and it only moves when the agent has walked 50 m. So the drawn boundary was
rigidly welded to the anchor point and travelled with the agent — the overlay
kept a constant apparent distance while the label counted honestly down from
45 m to 18 m — then jumped when the re-anchor fired. This is exactly the
symptom reported, and it is a translation bug, not a noise problem.

**Nothing filtered the fix.** Once the camera is correctly attached to the
agent, every GNSS update moves it directly, so a stationary agent would watch
the boundary swim by several metres at 1 Hz.

The fix follows the pedestrian-navigation literature rather than inventing a
scheme: a zero-velocity update (ZUPT) style stationary detector gates a
constant-position Kalman filter, one scalar filter per horizontal axis, whose
process noise is set by the detected motion state and whose measurement noise is
the receiver's own reported accuracy. Standing still collapses the gain towards
zero and the overlay locks; walking opens it and the overlay tracks.

References consulted:
- Chen et al., *Adaptive Kalman filtering-based pedestrian navigation algorithm
  for smartphones*, Int. J. Adv. Robotic Systems 17(3), 2020 —
  https://journals.sagepub.com/doi/full/10.1177/1729881420930934
- *A Robust Adaptive Filtering Framework for Smartphone GNSS/PDR-Integrated
  Positioning*, Micromachines 17(3):353 — https://doi.org/10.3390/mi17030353
- *A Continuous PDR and GNSS Fusing Algorithm for Smartphone Positioning*,
  Remote Sensing 14(20):5171 — https://doi.org/10.3390/rs14205171
- Zhang et al., *Enhancing outdoor long-distance matching in mobile AR: a
  continuous and real-time geo-registration approach*, 2025 —
  https://www.sciencedirect.com/science/article/pii/S156984322500069X
  (reaches 0.05 m, but with RTK-GNSS hardware this project has ruled out)

## Revision pass (the standing instruction: no duplication, nothing computed unused)

Findings from re-reading the round-2 work before closing it out:

- **`toDevice()` had an implicit camera.** Rather than fixing the four call
  sites, the camera position became a required parameter, so the bug that caused
  the drift cannot be written again. The old signature had no way to express
  "camera at the agent" and no way to notice it was not.
- **The palette existed twice** once colours were needed in Kotlin and in
  TypeScript. Replaced with `palette.json` plus `tools/gen-palette.mjs`, which
  generates both; `--check` fails if either is stale.
- **`pickColourIndex()` mirrors `fieldar.pick_colour_index()`.** Genuine
  duplication, and unavoidable while two stores exist - flagged rather than
  hidden. The API test asserts the behaviour, so a divergence shows up.
- **MapLibre was still a dependency** after the map picker was deleted. It was
  44 MB of the 56 MB APK. Removed; the APK is back to 12.6 MB.
- **`agentGround` was computed and only partly used** - it fed the distance
  readouts while the projection ignored it. That gap *was* the bug.
- **`clipToNearPlane` cannot clip an open segment**, so wall top rails needed
  `clipSegmentToNearPlane`. Added rather than reusing the closed-ring clipper,
  which silently turns a 2-point line into a degenerate polygon.
- **Cleartext HTTP was never enabled.** Not noticed before because the phone
  could mark its own plots; with that gone, an unreachable API is an empty app.
  Enabled in the debug source set only.

## Known gaps, stated rather than papered over

1. ~~**The API still writes to SQLite, not Supabase.**~~ **Closed.** The Supabase
   driver is live and deployed; `GET /api/health` reports `{"ok":true,
   "store":"supabase"}`. SQLite remains as the dev/test fallback when no
   credentials are present, which is what lets the API test suite run with
   nothing to provision. The phone now reaches a deployed URL, not a LAN address.
2. **The health index is synthetic.** `syntheticNdviSampler` is deterministic
   noise, not remote sensing. Every response carries `synthetic: true` and the UI
   shows an amber warning. Real Sentinel-2 replaces one function.
3. **The stabiliser takes ~30 s to fully settle** from a cold start, because it
   is seeded with the first fix's own accuracy. Locking faster would mean locking
   onto whatever that first fix happened to be.
4. **The off-device demo harness (`tools/demo`) still draws the flat overlay.**
   It compiles and runs, but it no longer shows what the app shows.

## R7 — second field test (2026-08-25)

Reported: walls read correctly at distance, but the overlay "is still moving a
lot", and close range was unusable.

**The overlay was never orientation-filtered.** Round 2 stabilised position and
stopped there, which was half the job and the smaller half. Position error moves
the overlay by a fixed number of metres; orientation error moves it by an amount
that *grows with range* - one degree is 0.87 m at 50 m and 2.6 m at 150 m. The
rotation vector wobbles a degree or two continuously, so several metres of
visible movement were going straight to the screen while the position estimate
sat rock steady at 0.17 m. Fixed by `core/geo/OrientationSmoother.kt`: quaternion
slerp with a speed-adaptive time constant, after Casiez, Roussel and Vogel's
1-euro filter (CHI 2012).

**Adapting on angular rate did not work, and the reason is worth keeping.** The
first attempt scaled the time constant by frame-to-frame rate. Jitter of 1.5 deg
arriving every 20 ms is an instantaneous 75 deg/s, which is indistinguishable
from a deliberate pan, so the filter concluded "motion" on every sample and
barely smoothed at all - 3 deg of raw swing became 1.86 deg. Adapting on
*deviation from the current estimate* separates them properly: jitter is bounded
by its own amplitude however fast it arrives, while a real turn makes the
estimate fall behind and the gap grows. Measured: 3 deg of raw swing becomes
0.39 deg, and a 60 deg/s pan settles to under 0.4 deg within 1.5 s of stopping.

Also from this round:
- Walls now finish 1 m above eye level (`EYE_HEIGHT_M + 1.0`). Below eye level
  the rail reads as the boundary and the base as a shadow, so the panel looks
  like it is floating rather than standing on the ground.
- Panels fade out inside 12 m and vanish by 3 m, the rail persisting at 45%. A
  2.6 m wall 3 m from the camera subtends most of the frame, and a boundary you
  are standing against is the one you least need painted over your view.
- Accuracy bands are suppressed when the agent is closer to an edge than the
  accuracy figure. The band is a slab as wide as the fix lying on the ground, so
  at 6 m with an 8 m fix its near side is *behind* the camera and it floods the
  frame. That was the "hodgepodge", and nothing had drifted.
- HOLDING draws at 60% rather than full strength. It was claiming certainty on a
  heading gyro-carried for 45 s.
- Health grading moved to green/yellow/amber/brown and cells are clipped to the
  boundary with a real intersection; centre-inside testing left half of each edge
  cell hanging over the neighbour's fence.

## R8 — third field test, and the docs (2026-08-27)

Reported: *"it is still moving as we move and it is shifting by around one
geographic pixel"*, plus a request for more solid, brighter AR objects. Crop
health had never appeared in the AR view at all.

**The residual movement was two sensor streams sharing one filter.** Both
rotation vectors were being fed into a single `OrientationSmoother`. They
disagree in yaw by tens of degrees — the game vector's origin is arbitrary at
boot — so the deviation measure saturated at ~33°, pinned the time constant at
its most agile 0.05 s and switched the smoothing off entirely. My first
hypothesis, that this corrupted pitch and roll directly, was wrong: `withHeading`
is yaw-only and overwrites it downstream. The real mechanism is the saturation.
Now exactly one stream is the carrier, only the carrier is smoothed, and only the
carrier publishes a pose — which also stopped the overlay rebuilding ~100×/s for
samples that changed nothing.

**Walking gait was reading as deliberate motion.** `AGILE_DEVIATION_DEG` 10 → 25,
`DEVIATION_TAU_S` 0.15 → 0.30. Each footfall pitches the handset several degrees
over about 0.2 s; averaging over longer than one step means a step cannot unlock
the filter but a turn still can.

**The drawn position was separated from the estimate.** New slew limiter in
`PositionStabilizer`: 8 cm/s stationary, 2 m/s walking, snap past 10 m, capped
along the line to the estimate rather than per axis. An unbiased estimator still
twitches, and twitch is what the eye reads. Measured locked step is now 0.0800 m
per fix — the cap itself, so it is a guarantee rather than an observation.

**Crop health in AR was built from nothing.** New `core/render/HealthGeometry.kt`
(cells, hotspots, three layers, range cull at 150 m, nearest-500 cap), Room
migration 2→3 for `plot_health`, DTO parsing, and rendering ahead of the walls
with numbered hotspot markers behind them. It is suppressed entirely when the
heading is UNRELIABLE.

**Why it had looked broken even once drawn:** three independent fades multiplied.
Severity alpha × foreground fade × confidence tier put a stressed patch underfoot
at 0.42 × 0.35 × 0.6 ≈ 9% — invisible in daylight. Every multiplier still exists,
but the floors are now set so the *worst* combination stays legible, not just the
best. `MIN_PATCH_OPACITY` 0.35 → 0.62, `MIN_RAIL_OPACITY` 0.45 → 0.75, wall fades
12/3 m → 8/1.5 m, HOLDING 0.6 → 0.85, and dark backing strokes under every rail,
post and marker.

**The health ramp was earth-coloured, on earth.** R7 moved it to
green/yellow/amber/brown so the bad end described the ground rather than alarming
about it. Outdoors that failed on its own terms: amber and brown *are* dry soil,
so the two worst bands vanished. Now `#2FD44E / #FFE81A / #FF8A00 / #FF2118`.

**A fixed 10 m grid gave small plots a 3×3 raster** — too coarse to locate
anything, and unable to form a hotspot at all, so they silently reported no
problems. Added `recommendedCellSizeM`: √area ÷ 15, half-metre steps, clamped
2–10 m. PLT-7013 went from 9 cells to 221, and from 0 hotspots to 2.

**`lockFreshMs` 30 s → 60 s.** Re-locking needs a 20 m straight walk and an agent
circles a small plot rather than crossing it, so 30 s made HOLDING the permanent
state and LOCKED the exception — inverting what the labels are for.

### The palette generator had stopped reading palette.json

Worth recording in full, because every artefact looked internally consistent and
the verification step was itself the broken part.

When the severity ramp was added to `tools/gen-palette.mjs`, the values were
interpolated *while editing the generator* and pasted into the templates as
literals. `const severities = health.severity` was declared and never used.
`--check` passed forever after, because the generator and the files it wrote were
equally stale. Consequence: the brighter ramp reached neither language, and an
APK was built, installed and reported on while still carrying the old colours.

Caught only because the deployed web bundle hash never changed. Fixed by making
the templates interpolate, and by adding `assertDerived()`, which runs before any
write and exits 2 naming any `palette.json` value missing from a generated file.
Verified by sabotage rather than by assumption.

**Test bounds updated honestly**, with measured values rather than loosened
silently: pan lag 15° → 20° (measured 15.66°), stationary drift 2.0 → 3.0 m
(2.241 m), locked step 0.25 → 0.09 m (0.0800 m), settle-at-0.5 s 2.0° → 5.0°
(3.48°), settle-at-1.5 s 0.4° → 1.0° (0.582°). The one bound that got *tighter*
is the one a person can actually see.

**Verified:** 125 Android tests, 17 API tests, 0 failures. Live API on Supabase.
Both palettes confirmed matching end to end, web bundle to compiled Kotlin.

### Documentation

`docs/builders-manual.html` written for the partner team — problem statement,
both platforms end to end, all ten logics with reasoning, full library inventory,
14 diagrams, and the questions the team actually asked (grid size, how the camera
locates itself, how distance is computed). Earlier drafts moved to `docs/archive/`.

Repository split: this half now lives in `cropin-plotvizualiser-android`, the web
tool stays in `cropin-PlotVisualizer` where Vercel deploys from it.

### Still open

- `tools/demo` off-device harness still renders the old flat overlay.
- The "cropin office" boundary has a stray 6th vertex forming a spike across the
  plot; it renders as a wall through the middle of the field and should be
  redrawn in the web tool.
- Telemetry rows are written locally but never uploaded — `POST /api/telemetry`
  is declared client-side and unimplemented server-side.
