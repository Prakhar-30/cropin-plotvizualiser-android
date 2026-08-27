# plot-ar-android — AR plot finder

A field agent is dispatched to a farm plot, arrives at the nearest road, and is
surrounded by visually identical fields. This app points the phone around, shows
the target plot highlighted on the ground through the camera, and shows roughly
where its boundary runs.

Plots come from the companion web tool, which lives in its own repository:
**[cropin-PlotVisualizer](https://github.com/Prakhar-30/cropin-PlotVisualizer)**.
Boundaries are drawn there and only there; this app is a reader.

> **Start here:** [`docs/builders-manual.html`](docs/builders-manual.html) is the
> full builder's manual — the problem, both halves of the system, every algorithm
> with its reasoning, the library inventory, and 14 diagrams. Open it in a
> browser. This README is the operational summary.

## Hard constraints

| | |
|---|---|
| **Phone only** | No external GNSS, no Bluetooth accessory, no RTK, no NTRIP, nothing installed in the field |
| **Offline once cached** | Rural sites have no data. Every read is from Room; sync is an explicit, optional action |
| **No ARCore Geospatial API** | It depends on Google's Visual Positioning System, which needs Street View coverage farmland does not have — and it reports confident accuracy figures while silently falling back to raw GPS. See [Why not ARCore](#why-not-arcore) |

## Layout

```
core/geo       ENU frame, pinhole projection, near-plane clipping, polygon distance
core/heading   heading fusion, course-over-ground detection, landmark snap
core/render    what to draw, in screen coordinates
pose           PoseSource interface + sensor implementation
location       LocationSource interface + fused location
sim            debug-only simulated agent (implements both interfaces)
data           Room cache, Retrofit sync, repositories
ui             Compose screens: plot list, plot detail, AR view
```

Everything under `core/` imports nothing from Android. That is what makes the
maths that decides where the overlay lands testable on a plain JVM — and it is
where the bugs in this kind of app actually live.

## Running the tests

`./gradlew test` runs them the normal way. On a machine with no Android SDK they
can still be run directly:

```bash
KOTLIN_HOME=~/kotlinc \
JUNIT_CP="$HOME/jars/junit.jar:$HOME/jars/hamcrest.jar" \
tools/run-core-tests.sh
```

**125 tests**, every expected value hand-computed from the documented model
rather than by calling the code back on itself. They cover the ENU frame,
projection and clipping, the position and orientation filters, heading fusion,
the overlay builders and the health raster — all on a plain JVM, no device.

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
horizontal FOV from `CameraCharacteristics` — never a hardcoded 60°, which is
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
| `COURSE_OVER_GROUND` | 3–5° | walked >20 m in a straight line at >0.7 m/s |
| `LANDMARK_SNAP` | 2–3° | aimed at a known point and tapped |
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

## Holding the overlay still

Two filters, because the two error sources behave differently and a single one
cannot address both.

**Position** — `core/geo/PositionStabilizer.kt`. A constant-position Kalman
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

**Orientation** — `core/geo/OrientationSmoother.kt`. This matters more than the
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
- **Unreliable** (grey) — compass only. The overlay greys out and the chip reads
  *"walk a few steps to lock direction"*, which turns the worst failure mode into
  a two-second user action.

## Telemetry

One row per session in a local Room table, no UI: timestamp, plot id, lat/lng,
reported horizontal accuracy, heading, heading source, heading confidence, render
mode, anchor shift, session duration.

**Rows are written locally and not yet uploaded.** The client side of the upload
is built — `POST /api/telemetry` is declared in `PlotApi` and the DTO matches —
but the web service does not implement the endpoint, so switching it on is a
server change alone. Nothing leaves the device today.

This is the point of shipping v0 — it produces the real accuracy distribution
across the actual device fleet, which is what justifies (or kills) phase 2.
Guessing at that from a spec is how teams buy RTK receivers they did not need.

## Simulation mode

Debug builds only. An on-screen joystick injects a fake location and heading in
place of the real sensors, so the overlay can be driven around a synthetic plot
from a desk. Sliders inject deliberate **GNSS error** and **heading error** so the
failure modes reproduce on demand.

It is also the demo: show the overlay sitting correctly on the plot, then dial
heading error to 20° and watch it settle over the neighbouring field. That is the
slide that explains why the heading architecture exists.

`SimulationEngine` implements `LocationSource` *and* `PoseSource` from one piece
of state, because they are two views of one simulated agent — two independent
fakes would drift apart. Release builds contain no joystick and no sliders.

## Why not ARCore

An agent asked for "AR boundaries" reaches for ARCore's Geospatial API, because
that is what the documentation and every tutorial suggests. It compiles, it
reports sub-2 m accuracy, and in farmland with no Street View coverage it is
wrong by 5–10 m with a 30–45° heading error.

v0 is sensor-only on purpose: the far-field identification case needs no plane
detection and no visual odometry, and ARCore triples the complexity of getting
the first version on screen. `PoseSource` is the seam — an ARCore-backed
implementation satisfies the same interface and nothing above it changes.

## Out of scope for v0

Boundary correction by the agent, photo capture, audit forms, iOS, ARCore.
`PoseSource` and the Room schema are shaped so these drop in later — `PlotEntity`
already carries the columns a boundary edit would need.

## Documentation

| File | What |
|---|---|
| [`docs/builders-manual.html`](docs/builders-manual.html) | **The main document.** Problem statement, both halves of the system, all ten logics with their reasoning, full library inventory, 14 diagrams. Written for someone who has never seen the code. |
| [`MILESTONES.md`](MILESTONES.md) | The build log — what each milestone covered and what is outstanding. |
| `docs/archive/` | Superseded drafts, kept for history. Not current. |

## Build notes

- Kotlin, single app module, min SDK 26, portrait-locked (the overlay maths
  assumes the screen frame the sensor matrix is remapped into).
- API base URL is a `buildConfigField`; it defaults to `http://10.0.2.2:4000/`,
  the emulator's route to a `plot-web` API running on the host.
- The rotation matrix is remapped through `SensorManager.remapCoordinateSystem`
  for the display rotation, so a natural-landscape device does not render the
  whole overlay on its side.
