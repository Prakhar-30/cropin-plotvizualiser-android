# Holding a geo-anchored overlay still: research notes

Prompted by the first real-phone test (14 Oct 2026, indoors, plot PLT-8863):
walking about 9 m towards the plot, the boundary receded in front of the agent
and finished metres from where it belonged.

## What went wrong

The plot's corners were never the problem. They are fixed WGS84 points, turned
into metres once against a local frame. What moves the drawing is the
**camera's** position, and that came only from GNSS:

- Under a roof the receiver reported ~13 m accuracy and near-zero Doppler speed
  while the agent walked.
- The stabiliser read "speed ≈ 0" as standing still, held its estimate, and let
  the drawn position creep at 8 cm/s.
- The camera physically advanced 9 m; the app believed it had not, so it redrew
  the plot 9 m further away every metre the agent walked. The boundary
  "walked away".

So "fixing the plot to its geo-points" means tracking the *agent* properly
between and through poor fixes. That is a solved problem in pedestrian
navigation.

## What the literature says

- **GNSS alone cannot register outdoor AR.** Azuma's survey puts consumer GPS
  far outside AR tolerances and notes that inertial sensors are immune to the
  environment but drift. Every practical system pairs a drift-free absolute
  source (GNSS) with a responsive relative one (inertial or visual) [1].
  Commercial location-based AR that fuses only GPS and compass "often lacks the
  precision needed for aligning content" [2].
- **Pedestrian dead reckoning (PDR) is the standard relative source on a
  phone.** It has three parts: step detection, step length, heading. Position
  is accumulated step by step and its error grows with distance walked, which
  is why it is fused with GNSS rather than used alone [3][4]. A multi-rate
  Kalman filter merging PDR and GNSS is the usual structure [5]. Reported
  results: 2.7–4.2 m with fusion against ~30 m GNSS-only in urban tests [6].
- **Step detection.** Peak-valley detection on the acceleration magnitude is
  the common method, because the magnitude does not depend on how the phone is
  held [4]. Android's built-in step detector has been reported to deliver
  results late for real-time PDR [7], which is why we detect steps ourselves.
- **Step length.** Weinberg's model, `L = K·(a_max − a_min)^¼`, ranked closest
  to the true length in 11 of 28 datasets and least scattered in 18 of 28 in a
  ten-method comparison [8]. Its one gain K is personal and must be calibrated
  [8]; GNSS is the usual reference, calibrating whenever its accuracy is good
  [9][10].
- **Beyond PDR: visual-inertial odometry (VIO).** Camera plus IMU tracking
  (what ARCore and ARKit run underneath) holds an anchor to centimetres over
  tens of metres. Outdoor geo-AR systems fuse VIO with GPS in an error-state
  filter and correct its drift with geo-registration [11][12].

## What is now in the app

| Piece | Where | Notes |
|---|---|---|
| Step detection | `lib/core/motion/step_detector.dart` | Peak-valley on low-passed accelerometer magnitude, adaptive gravity estimate, minimum swing and interval. No ACTIVITY_RECOGNITION permission needed |
| Step length | `StepLengthModel` | Weinberg, K = 0.45 default, clamped 0.30–0.65 |
| Calibration | `lib/core/motion/step_calibrator.dart` | Over ≥30 m walks with every fix ≤6 m accuracy, compares the vector sum of steps with the GNSS displacement; rejects walks where they disagree on direction by >25° |
| Fusion | `PositionStabilizer.onStep` | Each step moves the estimate **and** the drawn position at once, no slew lag. Steps, not Doppler, decide moving vs still. Poor fixes (>6 m, fully at 10 m) count 3× less while walking, because fixes under a roof are correlated, not independent |

GNSS remains the absolute reference: outdoors with good fixes it corrects
step-length and heading drift within seconds; indoors or under canopy the steps
carry the position and GNSS only nudges.

**Speed:** the overlay now responds to each step, about 150 ms after the
footfall, instead of waiting for the next 1 Hz fix and then slewing.

## Obstacles: crops, trees, people, chairs

Two separate questions:

1. **Do obstacles break the placement?** No. Placement uses GNSS, inertial
   sensors and the plot's stored coordinates; nothing in it looks at the image.
   A wall of sugarcane or a row of chairs cannot move the boundary. What
   obstacles *can* do is degrade GNSS (canopy, buildings, multipath), which is
   exactly the case step counting now covers.
2. **Is the overlay drawn on top of obstacles?** Yes, today, and that is the
   right default. A boundary hidden behind the crop it encloses would vanish at
   the moment the agent most needs it. The design already works with this:
   the walls stand 2.6 m tall with a rail above eye height so the line reads
   above crops and people, and the ground fill fades nearby.

True occlusion, with nearer objects hiding the overlay, needs per-pixel depth.
On Android that means the ARCore Depth API (depth from motion, no special
sensor needed) or a monocular depth model. Both are worth it only once the
pose comes from VIO, below.

## Recommended next step: ARCore motion tracking (not Geospatial)

The README rejects ARCore's **Geospatial API** because it depends on Street
View imagery that farmland lacks. ARCore's plain **motion tracking** is a
different thing: on-device VIO with no imagery, no network and no Street View.
The best-known way to make a geo-anchored overlay stay put while walking is:

1. Align once: take the ARCore world frame and fix it to ENU using the
   stabilised GNSS position and the locked heading (walk lock or landmark snap).
2. Then let VIO move the camera: centimetre-level motion, no step-length error,
   correct sideways and backwards motion too, and depth for occlusion.
3. Keep GNSS as a slow drift correction, exactly as it now corrects PDR.

The costs: ARCore must own the camera (the preview becomes ARCore's texture
instead of the camera plugin's), it only runs on ARCore-certified phones, and
low-texture scenes (a uniform crop canopy, glare) can drop tracking. That makes
it an upgrade with PDR as the fallback, not a replacement. `PoseSource` is
already the seam for it.

## Second field test: the boundary slides sideways on approach

Same indoor setting, steps now counted. The boundary no longer receded, but as
the agent closed in it slid sideways from frame to frame. The chip read heading
*HOLDING* and the receiver ±15 m.

Close to a boundary, small position errors turn into large angles on screen. At
3 m range, 1 m of position error is about 18° of apparent shift. Under a roof
every GNSS fix moved the estimate by a fraction of its 10–15 m scatter, and the
step model added its own length and direction error. Both were visible.

What the literature does about it:

- **Use VIO for the relative motion and GNSS for the absolute position only.**
  Schall et al. fuse GNSS, inertial and vision for outdoor AR so that the
  responsive visual tracker carries the frame-to-frame pose while GNSS anchors
  it [13]. GVINS and VINS-Fusion formalise the same split as a factor graph:
  VIO is locally accurate but drifts, GNSS is globally consistent but noisy,
  and the GNSS term only corrects the slow drift [14][15].
- **Commercial geo-AR does the same, plus a manual correction.** Esri's
  world-scale AR guidance: "take an initial position from device GNSS, let the
  user adjust the overlay, and then use ARCore or ARKit to track relative
  motion" [16].
- **ARCore's motion tracking needs texture and light.** It tracks feature
  points in the camera image together with the IMU. It reports why it has lost
  tracking: too dark, too fast, or too little texture [17].

### What is now in the app

| Piece | Where | Notes |
|---|---|---|
| ARCore session and preview | `android/.../ArCoreView.kt` | Motion tracking only: plane finding, light estimation and depth are off, and there is no Geospatial API or network. A `GLSurfaceView` platform view (hybrid composition) draws the camera image, and each frame sends the display-oriented camera pose and projection to Dart |
| Frame conversion | `lib/core/geo/arcore_pose.dart` | ARCore's Y-up world becomes yaw-arbitrary ENU (east = x, north = −z). The overlay's FOV is taken from the projection ARCore actually renders with, so it matches the picture underneath |
| Pose source | `lib/pose/vio_pose_source.dart` | ARCore's yaw is the heading fusion's carrier, in place of the game rotation vector. Walk lock and landmark snap still pin it to true north. Each frame's displacement is rotated into true ENU |
| Fusion | `PositionStabilizer.onVisualMotion` | Visual displacement moves the estimate **and** the drawn position on the same frame. While it flows, fixes count 3× less (in σ) and process noise drops to 5 cm/s. The drawn position absorbs GNSS corrections at no more than 5 cm/s |
| Position pin | `PositionStabilizer.pinTo`, "I'm standing at the access point" | Replaces the estimate with the surveyed access point. Fixes then count a further 10× less, so a receiver several metres off cannot pull the pin away |
| Fallback | `ArScreen` | Without ARCore, or if its session fails or sends no frames for 6 s, the screen falls back to the camera plugin, rotation sensors and counted steps. Steps are ignored while ARCore tracks, so motion is never counted twice |

Regression test: a ±15 m receiver scattered around a point 8 m to one side, a
10 m tracked approach. The drawn position follows the camera to within 0.6 m
and moves under 1 m sideways over the whole walk. With the pin it ends within
0.6 m of the truth.

**What it does not fix.** Heading still comes from walk lock, landmark snap or
the magnetometer. A wrong heading rotates the whole plot about the agent; it
does not make the plot swim. VIO also needs texture: a uniform crop canopy
filling the frame, or glare, can drop tracking. When that happens a banner says
why, and the steps take over until tracking returns.

## Sources

1. Azuma, *A Survey of Augmented Reality* (1997) — [PDF](https://sreal.ucf.edu/wp-content/uploads/2017/02/Azuma1998.pdf)
2. Brata et al., location-based AR with VSLAM and Street View anchoring, *Sensors* 2024 — [PMC10893312](https://pmc.ncbi.nlm.nih.gov/articles/PMC10893312)
3. GNSS/PDR integration with factor graph optimisation, *GPS Solutions* 2022 — [Springer](https://link.springer.com/10.1007/s10291-022-01260-0)
4. Step detection and adaptive step length for PDR at various walking speeds — [PMC5038701](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC5038701/)
5. Multi-rate Kalman fusion of PDR and GNSS, University of Florence — [FLORE](https://flore.unifi.it/handle/2158/1236100)
6. Luo et al., GNSS, BLE and inertial sensors in urban environments, *IEEE Access* 2021 — [PolyU](https://www.polyu.edu.hk/aae/ipn-lab/us/publications/Fullpaper/Integration%20of%20GNSS%20and%20BLE%20Technology%20With%20Inertial%20Sensors%20for%20Real-Time%20Positioning%20in%20Urban%20Environments.pdf)
7. Real-time step detection based on dynamic peaks, SPIE 2023 — [SPIE](https://medicalimaging.spiedigitallibrary.org/conference-proceedings-of-spie/12707/1270750/A-real-time-step-detection-algorithm-based-on-dynamic-peak/10.1117/12.2681008.full)
8. Comparison of step-length estimation methods (Weinberg evaluation) — [Mersin](https://publish.mersin.edu.tr/index.php/igd/article/download/516/430); review: *Pedestrian Inertial Navigation: An Overview* — [arXiv 2407.21676](https://arxiv.org/pdf/2407.21676)
9. *Adaptative pedestrian displacement estimation with a smartphone* (GNSS-calibrated step model) — [HAL](https://hal.archives-ouvertes.fr/hal-01470447)
10. Robust step detection with low-cost MEMS accelerometers (patent) — [USPTO](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/11808605)
11. *Cross-View Visual Geo-Localization for Outdoor Augmented Reality* — [arXiv 2303.15676](https://arxiv.org/pdf/2303.15676)
12. Chen et al., *Sensor-Aware Recognition and Tracking for Wide-Area AR on Mobile Phones*, *Sensors* 2015 — [PMC4721767](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC4721767/)

13. Schall et al., *Global Pose Estimation using Multi-Sensor Fusion for Outdoor Augmented Reality*, ISMAR 2009 — [IEEE](https://ieeexplore.ieee.org/document/5336489)
14. Cao, Lu, Shen, *GVINS: Tightly Coupled GNSS–Visual–Inertial Fusion for Smooth and Consistent State Estimation*, IEEE T-RO 2022 — [arXiv 2103.07899](https://arxiv.org/abs/2103.07899)
15. Qin et al., *A General Optimization-based Framework for Global Pose Estimation with Multiple Sensors* (VINS-Fusion) — [arXiv 1901.03642](https://arxiv.org/abs/1901.03642)
16. Esri, *Display scenes in augmented reality: world-scale AR* — [ArcGIS Maps SDKs](https://developers.arcgis.com/kotlin/scenes-3d/display-scenes-in-augmented-reality/)
17. Google, *ARCore fundamental concepts: motion tracking* — [developers.google.com](https://developers.google.com/ar/develop/fundamentals)

The numbers quoted are the authors' own results from their test conditions,
not general benchmarks.
