# Plot Finder (Flutter) — AR plot finder

> **This is the `flutter` branch.** The app has been rebuilt in Flutter, feature
> for feature; `main` keeps the original Kotlin/Compose app. The port kept every
> algorithm; the October 2026 field tests then added ARCore motion tracking, a
> single "I'm at the access point" action, direction from the walk, native
> rendering with occlusion, a minimap and a startup loader - see
> [In the field](#in-the-field) and [Why not ARCore](#why-not-arcore). Every step
> is logged milestone by milestone in [`MILESTONES.md`](MILESTONES.md).
>
> It is packaged as a **Flutter plugin** so another Flutter app can embed it with
> one dependency and one screen - see [`INTEGRATION.md`](INTEGRATION.md). The
> standalone app lives in `example/`.


A field agent is dispatched to a farm plot, arrives at the nearest road, and is
surrounded by visually identical fields. This app points the phone around, shows
the target plot highlighted on the ground through the camera, and shows roughly
where its boundary runs.

Plots come from the companion web tool, which lives in its own repository:
**[cropin-PlotVisualizer](https://github.com/Prakhar-30/cropin-PlotVisualizer)**.
Boundaries are drawn there and only there; this app is a reader.

> **Start here:** [`docs/builders-manual.html`](docs/builders-manual.html) is the
> full builder's manual — the problem, both halves of the system, every algorithm
> with its reasoning, the library inventory, and 14 diagrams — revised for this
> branch in October 2026. Open it in a browser. This README is the operational
> summary; the field-test research is in
> [`docs/research/ar-positioning.md`](docs/research/ar-positioning.md).

## Hard constraints

| | |
|---|---|
| **Phone only** | No external GNSS, no Bluetooth accessory, no RTK, no NTRIP, nothing installed in the field |
| **Offline once cached** | Rural sites have no data. Every read is from the local SQLite cache; sync is an explicit, optional action |
| **No ARCore Geospatial API** | It depends on Google's Visual Positioning System, which needs Street View coverage farmland does not have — and it reports confident accuracy figures while silently falling back to raw GPS. See [Why not ARCore](#why-not-arcore) |

## In the field

1. **Pick the plot** from the cached list, open its detail page, tap
   **Find this plot**.
2. **A loader** over the camera ticks off *Camera*, *Motion tracking* and *GPS*
   with a seconds counter, and after 20 s says to step into the open. The
   location stream sends a last-known fix under 30 s old the moment it opens, so
   the wait is usually short.
3. **Walk to the access point** following the arrow pill. Meanwhile the app
   works out north by itself, by fitting ARCore's tracked walk to the GNSS fixes
   taken along it (`TrajectoryAligner`). No aiming step.
4. **Tap "I'm at the access point"** - the one button. It stays disabled until
   GPS puts you within **50 m** of the access point, and says how far is left.
   Tapping fixes your position to the surveyed point; each step into the plot
   then refines the direction.
5. **Look**: walls on the boundary, crop-health cells on the ground, people and
   trees in front hiding it (where the phone has ARCore depth), and a **minimap**
   bottom-right - north up, health colours, ranked hotspots, you as a blue
   arrow. Tap it to enlarge.

Where GPS is too weak for the walk to set the direction (indoors, mostly), the
expanded sheet offers the fallback: *Direction off? Aim at the access point and
tap*, from at least 10 m away.

## Layout

```
lib/core/geo       ENU frame, pinhole projection, near-plane clipping, polygon
                   distance, position stabiliser, orientation smoother, camera FOV
lib/core/heading   heading fusion, trajectory alignment (direction from the
                   walk), course-over-ground detection, landmark snap
lib/core/render    what to draw: screen-space overlay for the sensor path, the
                   world scene and placement for the native ARCore renderer
lib/pose           PoseSource interface: sensor and ARCore (VIO) implementations
lib/location       LocationSource interface + fused location
lib/core/motion    step detection, step length, step-length calibration
lib/data           sqflite cache, HTTP sync, repositories
lib/platform       Dart end of the native channel, monotonic clock
lib/ui             Flutter screens: plot list, plot detail, AR view
lib/plot_finder.dart
                   the public API: PlotFinderScreen, PlotFinderConfig
android/src/main/kotlin
                   the plugin's native side: rotation vectors, accelerometer,
                   camera geometry, location, permissions, device info, and the
                   ARCore view + GL renderer (ArCoreView.kt, ArOverlayRenderer.kt)
example/           the standalone app, which embeds the package like any host
```

Everything under `lib/core/` imports nothing but `dart:math`. That is what makes
the maths that decides where the overlay lands testable with no device — and it
is where the bugs in this kind of app actually live.

### Why there is any Kotlin at all

Three inputs are taken from Android directly rather than through Flutter
plugins, because the plugins cannot hand them over faithfully:

- **The two rotation vectors.** Plugins expose raw accelerometer, gyroscope and
  magnetometer streams. Rebuilding Android's own `TYPE_GAME_ROTATION_VECTOR`
  fusion from those in Dart would be a second, subtly different sensor fusion.
  The native side only converts each sample to a rotation matrix and remaps it
  to the display; smoothing and heading fusion stay in Dart.
- **The camera's physical sensor size and focal length,** which set the FOV —
  the scale factor on every projected point. The camera plugin does not expose
  `CameraCharacteristics`.
- **Fixes that admit when they have no bearing.** `Location.hasBearing()`
  goes through as a null, so course over ground rejects the fix instead of
  reading it as "due north". Fixes come from the framework's `LocationManager`
  (its fused provider on Android 12+, GPS before that) rather than Google Play
  Services, so location adds no native dependency to clash with a host app's.
- **ARCore motion tracking** (visual-inertial odometry - not the Geospatial
  API), when Google Play Services for AR is installed. ARCore owns the camera
  then: the native side draws its preview on a `GLSurfaceView` platform view,
  draws the plot itself in the same GL frame (so it cannot lag the image),
  finds the floor from ARCore's planes and, where the Depth API is available,
  lets nearer people, trees and walls hide the boundary.

The Flutter camera plugin chooses its own preview size, often 16:9 from a 4:3
sensor, which crops the axis that spans a portrait screen. `CameraGeometry`
undoes that crop when it computes the FOV; the Kotlin app avoided the problem by
sizing CameraX to the sensor.

## Running the tests

```bash
flutter test
```

**190 tests.** Every Kotlin test was ported, with the same hand-computed expected values —
derived from the documented model rather than by calling the code back on
itself. They cover the ENU frame, projection and clipping, the position and
orientation filters, heading fusion, the overlay builders, the health raster and
the wire format, plus new tests for the preview-crop FOV correction, step
counting and step-length calibration, walking indoors on poor GNSS, and a few
widgets. None of them needs a device.

CI (`.github/workflows/flutter.yml`) runs `flutter analyze` and `flutter test`
on every push to this branch, on the current Flutter and on 3.22 (the oldest
the package supports), then builds the example's debug APK and keeps it as a
downloadable artifact of the run.

## Coordinate math

WGS84 is converted once into a local East-North-Up metric frame anchored at the
agent's current fix, and nothing downstream ever touches degrees:

```
east  = (lng - origin_lng) * cos(origin_lat) * 111320
north = (lat - origin_lat) * 110540
```

At the working latitude (12.79 N) a degree of longitude is 108 560 m and a degree
of latitude is 110 540 m — a 2.5% difference, so anything computed in raw degrees
is wrong by a different amount in each direction. The frame re-anchors once the
agent walks more than **50 m**.

Projection rotates the world point into the camera frame using the device
rotation matrix, then applies a pinhole projection with the camera's **actual**
horizontal FOV from `CameraCharacteristics` (corrected for the preview crop) — never a hardcoded 60°, which is
wrong on most phones and scales every screen position. All plot geometry sits on
the ground plane at the device's altitude minus a fixed 1.6 m eye height; there
is no terrain model and no attempt at one.

**Points behind the camera are culled before projection.** Without that, a
negative depth flips the sign and the field behind the agent renders mirrored on
top of the one in front. Polygons that straddle the camera are *clipped* rather
than filtered, so an agent standing inside a plot sees the visible part of the
boundary instead of an outline closed across the middle of the field.

## Heading — the whole ballgame

Position error shifts the overlay a few metres, which is invisible at 80 m.
Heading error scales with distance: 20° at 80 m puts the boundary 29 m sideways,
in the neighbour's field. So heading is never a bare number.

| Source | Error | When |
|---|---|---|
| `COURSE_OVER_GROUND` | 3–5° | sensor path: walked >20 m in a straight line at >0.7 m/s. ARCore path: the tracked walk fitted to GNSS (any route), error reported per fit |
| `LANDMARK_SNAP` | 2–3° | aimed at a known point and tapped (now a fallback in the sheet) |
| `MAGNETOMETER` | 15–25° | fallback only |

Course over ground comes from `Location.bearing` accumulated over a walking
segment. It is derived from GNSS motion, not the magnetic field, so a tractor or
a transformer cannot corrupt it. Segments are rejected if the bearing variance
across the window is high — a walk where the agent turned is *worse* than no
walk, because averaging its two legs gives a confident heading pointing between
them.

Once locked, the heading is carried by `TYPE_GAME_ROTATION_VECTOR` (gyro + accel,
**no** magnetometer) and the magnetic heading is applied only as a slow drift
trim: a 300 s time constant, plus a hard 10° ceiling on how far the compass may
ever pull a lock. Without that ceiling a magnetically disturbed site would drag a
good lock onto the neighbouring field slowly enough that nobody notices. Only yaw
is substituted — pitch and roll come from the sensors untouched.

A fix stays **LOCKED** for 60 s, then reads **HOLDING** — still gyro-carried,
still usable, but now reporting its age. The lock expires entirely after
**3 minutes** with no new fix and drops to `MAGNETOMETER`.

The 60 s window was 30 s until field testing. Re-locking needs a 20 m straight
walk, and an agent inspecting a small plot walks *around* it rather than across,
so at 30 s an entire visit ran in HOLDING — which inverted what the two labels
are for. The carried heading did not become more accurate; it simply is not
stale at a minute, and its drift is bounded separately by the 10° trim ceiling
and printed on the chip in degrees either way.

**Landmark snap**: the agent aims the crosshair at the plot's access point (whose
coordinates are cached) and taps. Both endpoints are known, so the true bearing
is computable outright; the crosshair's horizontal offset from the optical centre
is subtracted. One tap, heading pinned. Refused inside 10 m, where the agent's
own fix error would dominate the bearing.

**On the ARCore path** ARCore's visually tracked yaw is the carrier. A lock lasts
the whole visit and the compass gets no say over it (indoors it rotated the plot
about a standing agent); before any lock the compass offset is smoothed over 3 s.
The walk lock is the trajectory aligner: ARCore's tracked path, rotated onto the
GNSS fixes taken along it (weighted 2-D Procrustes), anchored at the access-point
pin when there is one. Fixes worse than 15 m are ignored, and a fit is used only
under 10°. The landmark snap takes its bearing from the same position the plot is
drawn from, and checks "too close" (under 10 m) before "position too uncertain".

## Holding the overlay still

Two filters, because the two error sources behave differently and a single one
cannot address both.

**Walking — counted steps.** The first real-phone test, walking nine metres
towards a plot indoors, showed the boundary receding as the agent approached.
Under a roof GNSS reports ~13 m accuracy and near-zero Doppler speed whatever
the agent does, so the filter read them as standing still and froze the drawn
position while the camera moved. Now `lib/core/motion` counts steps from the
accelerometer (peak-valley on the magnitude, no extra permission), sizes each
with Weinberg's model, and moves the estimate *and* the drawn position along
the locked heading at once - pedestrian dead reckoning. Steps, not Doppler,
decide when the agent is moving; poor fixes are de-weighted while walking on
steps, because fixes under a roof are correlated, not independent; and good
fixes outdoors both correct drift and calibrate the step length. Research
behind it: [`docs/research/ar-positioning.md`](docs/research/ar-positioning.md).

**Position** — `lib/core/geo/position_stabilizer.dart`. A constant-position Kalman
filter per horizontal axis, gated by a zero-velocity detector; the standard
pedestrian-navigation construction. Standing still the process noise is 2 cm/s,
so the gain collapses and new fixes barely move the estimate; walking it opens to
1.6 m/s and the estimate tracks. Measurement noise is the receiver's own reported
accuracy, floored at 3 m because Android receivers routinely claim 1 m when the
true error is several. A 3σ gate rejects outliers, but only for four fixes or
five seconds — a count alone is not a bound, and a receiver that goes quiet after
one wild fix would otherwise strand the estimate forever.

On top of that sits a **slew limiter**, and it is the piece that closed out field
testing. A Kalman estimate is built to be unbiased, which is right for an
estimator and wrong for something a person is looking at: every fix nudges it a
few centimetres and the overlay twitches along. So the drawn position is separate
from the estimate — it *chases* it at 8 cm/s while stationary, 2 m/s while
walking, and snaps outright past 10 m so a real relocation is never hidden. The
cap is on distance along the line to the estimate, not per axis; a per-axis cap
lets a diagonal correction travel √2 times the intended rate and bends the path
toward the axes, which looks like the overlay sidling rather than sliding.

The trade is deliberate: half a metre of standing bias bought in exchange for
stillness. A boundary that sits still while being slightly out reads as correct;
one that is unbiased and never settles reads as broken.

**Orientation** — `lib/core/geo/orientation_smoother.dart`. This matters more than the
position filter, because orientation error scales with range: at 50 m one degree
of jitter swings a boundary 0.87 m sideways, at 150 m it is 2.6 m. Spherical
interpolation between quaternions (never element-wise on matrices, which does not
produce a rotation — it shears the overlay instead of turning it), with a time
constant that adapts from 0.65 s at rest to 0.05 s under deliberate motion.

It adapts on **deviation from the current estimate**, not on angular rate. Jitter
of 1.5° arriving every 20 ms is an instantaneous 75 °/s, which looks exactly like
a deliberate pan and defeats a rate-adaptive filter outright. Deviation separates
them: jitter is bounded by its own amplitude however fast it arrives, while a
real turn makes the estimate fall behind until the filter speeds up to catch it.

> One bug here is worth knowing about, because the symptom pointed nowhere near
> the cause. Both rotation vectors were being fed through a single smoother. They
> disagree in yaw by tens of degrees — the game vector's origin is arbitrary at
> boot — so the deviation measure saturated permanently, pinned the time constant
> at its most agile value, and switched the smoothing off. Yaw hid the damage
> because `withHeading` overwrites it downstream; pitch and roll did not, and
> those are what tilt the ground plane. Only the carrier is smoothed now, and
> only the carrier publishes a pose.

## Two render modes

Switched on distance to the **nearest edge**, never the centroid — an elongated
plot's centroid can be 60 m away while the agent stands on its boundary.

Boundary edges stand up as **2.6 m vertical panels** in both modes — eye height
plus a metre — each with a solid rail along its top. A boundary drawn flat on the
ground reads as a coloured carpet rather than a limit, and disappears entirely
when the phone is held level, because the ground plane is then edge-on to the
camera. A wall topping out *below* eye level reads as floating; carrying it past
eye level puts the rail against the sky and the panel plainly stands on the earth.

- **Far (>30 m)** — the panels, plus a faint ground fill, a post at each vertex,
  and a label at the centroid with plot id, area and distance. An edge-of-screen
  arrow points to the plot when it is outside the FOV. The *shape*, never just a
  pin: the shape is what lets the agent confirm they are looking at the right
  field when heading is slightly off.
- **Near (<30 m)** — no fill. Each boundary edge becomes a translucent band whose
  half-width is the live GNSS horizontal accuracy, built in metres so perspective
  narrows it with distance. The band is labelled with the accuracy figure. A
  crisp line here would be a false precision claim, and it is the line that gets
  blamed the first time a farmer disputes a reading. Bands are suppressed once
  the agent is closer to the edge than the accuracy itself, where the band's near
  side falls behind the camera and floods the frame.

Panels fade out inside 8 m, so walking up to a boundary opens the camera back up
instead of filling it with colour — but the rail never drops below 0.75 opacity,
because the line *is* the boundary and losing it as you reach the fence removes
the answer at the moment you are trying to stand on it. Every rail, post and
marker is stroked twice, a dark halo under the colour: a single coloured line
vanishes wherever the background shares its luminance, and outdoor footage is
mostly bright sky, pale soil and corrugated steel.

## Crop health on the ground

The boundary answers *where is the plot*; this answers *which part of it do I
need to walk to*. Cells arrive from the API already graded and already trimmed to
the boundary, and are projected against the same eye, the same ENU frame and the
same ground plane as the boundary itself — a raster computed in its own frame
would sit metres outside the plot that is supposed to contain it.

- **Grid size is per plot**, not fixed: √area ÷ 15, rounded to 0.5 m, clamped
  2–10 m. A fixed 10 m grid gave a small plot a 3×3 raster, which cannot show
  *where inside* a problem is and cannot form a hotspot at all, since a cluster
  needs three touching stressed cells. Small plots silently reported no problems.
- **Three layers**, cycled by one button: off → problem areas → all cells.
  Problem areas is the default, because a plot is mostly healthy and painting
  every cell buries the two that matter under a green wash.
- **Hotspots are numbered** worst-first, deterministically, so the same plot
  always ranks its markers the same way and marker 1 means something.
- **Suppressed below a usable heading.** If the heading is UNRELIABLE the layer
  switches itself off — a coloured patch drawn on the wrong ground is worse than
  no patch at all.
- Range-culled at 150 m and capped at the nearest 500 cells: past that the
  ground plane is nearly edge-on and the raster stops being a map of the field,
  becoming a coloured smear along the horizon that reads as a rendering error.

**The values are synthetic.** Deterministic noise seeded from the plot id, shaped
to give a healthy field with one or two stressed patches, so the whole path from
raster to hotspot to a walk-to coordinate could be built and demonstrated. The
API returns `synthetic: true` with an explanatory note and the app labels it on
screen. Real Sentinel-2 NDVI means replacing one function; nothing downstream
knows where the numbers came from.

## Heading confidence chip

Persistent, not optional:

- **Locked** (green) — heading from a recent walk or snap
- **Holding** (amber) — gyro-carried, showing seconds since the last fix
- **Unreliable** (grey) — compass only. On the sensor path the overlay greys out;
  on the ARCore path it keeps the plot's colour, because a grey translucent wall
  is invisible against a white wall or a pale sky. The chip reads *"walk a few
  steps to lock direction"*, which turns the worst failure mode into a short walk.

## Telemetry

One row per session in a local SQLite table, no UI: timestamp, plot id, lat/lng,
reported horizontal accuracy, heading, heading source, heading confidence, render
mode, anchor shift, session duration.

**Rows are written locally and not yet uploaded.** The client side of the upload
is built — `POST /api/telemetry` is declared in `PlotApi` and the DTO matches —
but the web service does not implement the endpoint, so switching it on is a
server change alone. Nothing leaves the device today.

This is the point of shipping v0 — it produces the real accuracy distribution
across the actual device fleet, which is what justifies (or kills) phase 2.
Guessing at that from a spec is how teams buy RTK receivers they did not need.

## Why not ARCore

An agent asked for "AR boundaries" reaches for ARCore's Geospatial API, because
that is what the documentation and every tutorial suggests. It compiles, it
reports sub-2 m accuracy, and in farmland with no Street View coverage it is
wrong by 5–10 m with a 30–45° heading error.

v0 was sensor-only on purpose: the far-field identification case needs no
plane detection and no visual odometry. The field test changed that: walking
*up to* a boundary, a few metres of GNSS error is the difference between the
line ahead and the line beside you, and the overlay visibly swam.

So ARCore is now used for **motion tracking only** — on-device visual-inertial
odometry, no Street View, no network. `VioPoseSource` implements the same
`PoseSource` seam: ARCore's yaw becomes the heading fusion's carrier, its
frame-to-frame displacement moves the position filter directly, and GNSS is
weighted down to a slow drift correction. "I'm at the access point" pins the
absolute position, and the tracked walk sets the direction. The plot itself is
drawn natively in ARCore's own GL frame, on the detected floor, occluded by
nearer objects where depth is available. Phones without ARCore keep the sensor
path. Details and sources: `docs/research/ar-positioning.md`.

## Out of scope for v0

Boundary correction by the agent, photo capture, audit forms, iOS, the
ARCore Geospatial API.
`PoseSource` and the cache schema are shaped so these drop in later — `PlotEntity`
already carries the columns a boundary edit would need.

## Documentation

| File | What |
|---|---|
| [`docs/builders-manual.html`](docs/builders-manual.html) | **The main document**, revised for this branch in October 2026. Problem statement, both halves of the system, all eleven logics with their reasoning (including ARCore tracking, the access-point pin, direction from the walk and depth occlusion), full library inventory, 14 diagrams. Written for someone who has never seen the code. |
| [`docs/research/ar-positioning.md`](docs/research/ar-positioning.md) | The field tests and the literature behind each fix: PDR, VIO, latency and occlusion, the one-action flow. |
| [`INTEGRATION.md`](INTEGRATION.md) | Embedding the plugin in another Flutter app. |
| [`MILESTONES.md`](MILESTONES.md) | The build log — what each milestone covered and what is outstanding. |
| `docs/archive/` | Superseded drafts, kept for history. Not current. |

## Build notes

- Flutter plugin (minSdk 24, ARCore's floor) with its example app in `example/`
  (minSdk 26); the AR screen is portrait-locked while open (the overlay maths
  assumes the screen frame the sensor matrix is remapped into).
- CI builds a debug APK and a release arm64 APK on every push; take the
  `plot-finder-release-arm64-apk` artifact from the run.
- `cd example && flutter run` for a debug build; `flutter build apk --release`
  there for the one to put on a phone.
- The API base URL defaults to the deployed service,
  `https://cropin-plot-visualizer-service-nu.vercel.app/`. To use a local `plot-web` API instead
  (10.0.2.2 is the emulator's route to the host machine):
  `flutter run --dart-define=PLOT_API_BASE_URL=http://10.0.2.2:4000/`
- The example keeps the Kotlin build's applicationId and cache file, tables and
  schema version, so installing over it keeps the cached plots. Embedded, the
  cache file name is the host's choice.
- The rotation matrix is remapped through `SensorManager.remapCoordinateSystem`
  for the display rotation, so a natural-landscape device does not render the
  whole overlay on its side.
- **iOS is not wired up.** All of `lib/` is portable, but the plugin's native
  side exists only for Android; on iOS the screen shows an "Android only"
  notice. Support needs a Swift counterpart of `PlotFinderPlugin.kt`
  (CoreMotion attitude, AVCaptureDevice field of view, CoreLocation course).
