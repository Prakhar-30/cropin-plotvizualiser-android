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

1. **The API still writes to SQLite, not Supabase.** The schema is deployed and
   correct, and the wire shape (`fieldar.plots_api`) matches what the API already
   serves, but no storage driver has been swapped in. Until that is done the
   phone reaches the API over the LAN, not the internet.
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
