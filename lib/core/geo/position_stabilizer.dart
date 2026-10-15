import 'dart:math' as math;

import '../math_util.dart';
import 'enu.dart';

/// Holds the agent's position still while they are standing still.
///
/// A raw GNSS fix wanders by several metres from one second to the next even on a
/// phone lying motionless on a wall. Feeding that straight into the camera pose
/// makes the boundary swim, which reads to a farmer as "the app does not know
/// where my field is" - and they are not wrong to read it that way.
///
/// The approach is the standard one from pedestrian navigation, not an invention:
/// a zero-velocity detector gates a constant-position Kalman filter, one scalar
/// filter per horizontal axis. See Chen et al., *Adaptive Kalman filtering-based
/// pedestrian navigation algorithm for smartphones* (Int. J. Adv. Robotic Systems
/// 17(3), 2020) and *A Continuous PDR and GNSS Fusing Algorithm for Smartphone
/// Positioning* (Remote Sensing 14(20):5171).
///
/// The whole behaviour falls out of two numbers:
///
///  - **process noise** says how fast the true position may be changing. While
///    stationary it is set to a couple of centimetres per second, so the
///    estimate's variance stays small, the Kalman gain collapses towards zero and
///    new fixes barely move the estimate: the overlay locks. While walking it
///    opens up to roughly a brisk pace, the gain rises and the estimate tracks.
///  - **measurement noise** is the receiver's own reported accuracy, squared. A
///    fix that admits it is poor is automatically trusted less, with no threshold
///    to tune.
///
/// Between fixes the estimate is moved by counted steps (see [onStep]) - not by
/// integrating accelerometers, which on a hand-held phone drifts metres within
/// seconds and would trade a visible jitter for an invisible bias. A step is a
/// discrete, bounded displacement: its length error is a scale factor, its
/// direction error is the heading error, and GNSS corrects both over time.

/// Below this ground speed the agent counts as standing still.
const double stationarySpeedMps = 0.35;

/// Assumed rate of true position change while stationary. Small on purpose.
const double _stationaryProcessNoiseMps = 0.02;

/// Assumed rate of true position change while walking, a brisk pace.
const double _walkingProcessNoiseMps = 1.6;

/// The same while walking with steps being counted. The steps already carry the
/// motion, so what is left to model is only what they miss - a mis-sized or
/// uncounted step - and a third of a metre a second covers that.
const double _steppingProcessNoiseMps = 0.5;

/// Per-step position uncertainty, as a fraction of the step's length. Covers
/// a step-length error of ~20% and a few degrees of heading error.
const double _stepUncertaintyFraction = 0.3;

/// While walking on counted steps, poor fixes are trusted this many times less
/// (in standard deviation) once they are worse than [_poorFixFromM].
///
/// A filter like this one treats every fix as an independent measurement. Under
/// a roof or a canopy they are nothing of the kind: the receiver sits on the
/// same multipath reflection for tens of seconds, so ten fixes carry roughly
/// the information of one. Believing all ten makes the filter overconfident and
/// it drags a correctly-stepped walk back towards the stuck fix - in the field
/// test that is the overlay losing a quarter of every metre walked. Good fixes,
/// in the open, keep their full weight: they are what corrects the step length.
const double _poorFixInflation = 3.0;
const double _poorFixFromM = 6.0;
const double _poorFixFullM = 10.0;

/// While visual tracking carries the motion, every fix is trusted this many
/// times less (in standard deviation). Visual-inertial odometry is accurate to
/// centimetres over tens of metres; GNSS is accurate to metres. Letting GNSS
/// pull at full weight would put back exactly the swimming the visual tracking
/// removes, so it is left to correct only slow drift - minutes, not seconds.
const double _visualFixInflation = 3.0;

/// After the agent pins their position at a known point, fixes are trusted
/// this many times less again: the pin is the best absolute position this
/// session will get, and a receiver under a roof must not walk it away.
const double _pinnedFixInflation = 10.0;

/// Process noise while visual tracking carries the motion: what is left to
/// model is the tracker's own drift, about a centimetre or two per metre.
const double _visualProcessNoiseMps = 0.05;

/// Visual motion faster than this counts as moving, for the still/moving cue.
const double _visualMovingMps = 0.3;

/// Visual motion older than this, on the fixes' clock, means tracking is gone.
const int _visualTimeoutMs = 2000;

/// With steps being counted, no step for this long means standing still.
///
/// This replaces Doppler speed as the motion cue whenever steps are available.
/// Doppler is excellent in the open and useless under a roof or a canopy,
/// where it reads near zero while the agent walks - which held the estimate
/// still and made the boundary recede as they approached it. Two steps at a
/// slow walk take about 1.5 s.
const int _stepStillnessMs = 1500;

/// Floor on the accuracy a fix is allowed to claim.
///
/// Android receivers routinely report 1 m or better when the true error is
/// several. Believing that verbatim makes the filter over-confident and it starts
/// ignoring good fixes, so no measurement is ever treated as sharper than this.
const double _minTrustedAccuracyM = 3.0;

/// Innovation beyond this many sigma is treated as an outlier and held back.
const double _outlierSigma = 3.0;

/// Consecutive rejections after which the filter gives up and jumps.
///
/// Without it, a genuine relocation - walking out from behind a shed, or a cold
/// receiver settling onto a better constellation - would be rejected forever and
/// the overlay would stay confidently wrong.
const int _maxConsecutiveRejections = 4;

/// Wall-clock cap on how long a rejection may hold, whatever the fix count.
///
/// A count alone is not a bound. Four samples is four seconds at 1 Hz and
/// *forever* at 0 Hz, so a receiver that goes quiet immediately after one wild
/// fix would strand the estimate on a stale position indefinitely - which is
/// precisely the "the boundary does not move" failure this class exists to fix,
/// reintroduced from the other direction. Whichever limit is reached first wins.
const int _maxRejectionHoldMs = 5000;

/// How fast the *drawn* position may move while the agent is standing still.
///
/// The Kalman estimate above is built to be unbiased, which is the right goal for
/// an estimator and the wrong one for something a person is looking at. An
/// unbiased estimate still twitches: each fix nudges it a few centimetres, and
/// because the overlay is redrawn from it, the boundary and the crop-health
/// patches twitch with it. On a phone held to the eye that reads as the field
/// sliding around, which is the single complaint this whole feature keeps
/// attracting.
///
/// So the estimate and the thing that gets drawn are separated. The estimate
/// tracks the receiver; the drawn position *chases* the estimate at a bounded
/// rate. Standing still, 8 cm/s means a 1 m disagreement takes twelve seconds to
/// absorb - far below the threshold where the eye reads motion, while still
/// converging long before the agent has finished looking at anything.
///
/// This trades accuracy for stability on purpose, and the trade is the right way
/// round here: the agent is looking for *which* corner of a field is failing, and
/// a boundary that sits still while being half a metre out is worth far more than
/// one that is unbiased and never settles.
const double _renderSlewStationaryMps = 0.08;

/// The same bound while walking, set above walking pace so it never lags a real
/// walk. Its job is only to reject the sudden metre-scale jumps a receiver makes
/// when its satellite geometry changes - which are not walks, whatever the speed
/// field says.
const double _renderSlewWalkingMps = 2.0;

/// Beyond this the drawn position stops chasing and snaps.
///
/// At 8 cm/s a genuine relocation - an agent who drove to the next field with the
/// screen on - would take minutes to catch up, and would spend those minutes
/// drawing a boundary that is somewhere else entirely. Slewing is for suppressing
/// noise, not for hiding the truth.
const double _renderSnapM = 10.0;

/// The bound while visual tracking carries the motion, walking or not.
///
/// The camera's real motion reaches the drawn position directly, through
/// [PositionStabilizer.onVisualMotion], so whatever is left between the drawn
/// position and the estimate is a GNSS drift correction - and a drift
/// correction must not be visible as the boundary sliding sideways while the
/// agent walks up to it. A slow walk is about 1 m/s; this is a twentieth of
/// that, so a metre of disagreement is absorbed over twenty seconds - slower
/// even than the stationary bound, because here the camera is known to be
/// tracked and every bit of the gap is the receiver's.
const double _renderSlewVisualMps = 0.05;

/// What the stabiliser believes, and how sure it is.
class StabilizedPosition {
  const StabilizedPosition({
    required this.position,
    required this.uncertaintyM,
    required this.stationary,
    required this.shiftM,
    required this.rejectedOutlier,
  });

  final LatLng position;

  /// 1-sigma horizontal uncertainty of the estimate, in metres.
  final double uncertaintyM;
  final bool stationary;

  /// How far this estimate moved from the previous one, in metres.
  final double shiftM;

  /// True when the fix was too far from the estimate to be believed.
  final bool rejectedOutlier;
}

class PositionStabilizer {
  PositionStabilizer({double stationarySpeedThresholdMps = stationarySpeedMps})
      : _stationarySpeedMps = stationarySpeedThresholdMps;

  final double _stationarySpeedMps;

  /// Internal metric frame. The filter runs in metres, never in degrees: a
  /// variance expressed in degrees would mean two different distances on the
  /// two axes and the filter would be anisotropic for no physical reason.
  EnuFrame? _frame;

  double _east = 0.0;
  double _north = 0.0;
  double _varEast = 0.0;
  double _varNorth = 0.0;
  int _lastFixMs = 0;
  int _rejections = 0;
  int _firstRejectionAtMs = 0;

  /// Last published estimate, for reporting frame-to-frame shift.
  LatLng? _lastPublished;

  /// The drawn position, in the active frame's metres.
  ///
  /// Deliberately not the filter's own estimate - see [_renderSlewStationaryMps].
  /// Held in the same frame as [_east]/[_north] so re-anchoring moves both
  /// together and the slew never sees a jump that is really a change of origin.
  double _renderEast = 0.0;
  double _renderNorth = 0.0;
  bool _renderSeeded = false;
  int _lastPublishMs = 0;

  bool _stationary = false;
  bool get stationary => _stationary;

  /// When the last counted step - or visually tracked movement - happened, on
  /// the fixes' clock; 0 before any.
  int _lastStepMs = 0;

  /// True once a step or visual movement has been seen: from then on they, not
  /// Doppler, decide whether the agent is moving.
  bool get countingSteps => _lastStepMs != 0;

  /// When the last visual-tracking update arrived; 0 before any.
  int _lastVisualMs = 0;
  int _lastVisualMotionMs = 0;

  /// True while visual tracking is feeding [onVisualMotion].
  bool get visualTracking => _lastVisualMs != 0 && _lastFixMs - _lastVisualMs < _visualTimeoutMs;

  bool _pinned = false;

  /// True after [pinTo], until a reset or a relocation abandons the pin.
  bool get pinned => _pinned;

  /// Current 1-sigma horizontal uncertainty, metres. Zero before the first fix.
  double get uncertaintyM => math.sqrt((_varEast + _varNorth) / 2.0);

  /// Folds one fix into the estimate.
  ///
  /// [speedMps] is the Doppler-derived ground speed when the receiver provides
  /// it. It is a far better motion cue than differencing successive positions,
  /// because it does not inherit the positions' noise. Pass `null` when the fix
  /// carries no speed and the displacement fallback will be used instead.
  StabilizedPosition update({
    required LatLng position,
    required double accuracyM,
    required double? speedMps,
    required int timestampMs,
  }) {
    final existing = _frame;
    if (existing == null) {
      return _seed(position, accuracyM, timestampMs);
    }

    // Keep the working frame near the agent so the equirectangular
    // approximation stays sub-metre, and so east/north never grow large
    // enough to lose precision against the variances.
    final active =
        existing.needsReanchor(_estimateLatLng(existing)) ? _reanchor(existing) : existing;

    final measured = active.toEnu(position);
    final dtS = math.max(timestampMs - _lastFixMs, 0) / 1000.0;
    _lastFixMs = timestampMs;

    _stationary = _isStationary(speedMps, measured, dtS);

    // --- predict -------------------------------------------------------
    // Constant-position model: the estimate does not move on its own, only
    // its uncertainty grows, at the rate the motion state implies.
    final processNoiseMps = _stationary
        ? _stationaryProcessNoiseMps
        : visualTracking
            ? _visualProcessNoiseMps
            : (countingSteps ? _steppingProcessNoiseMps : _walkingProcessNoiseMps);
    final growth = (processNoiseMps * dtS) * (processNoiseMps * dtS);
    _varEast += growth;
    _varNorth += growth;

    // --- gate ----------------------------------------------------------
    final trusted = _trustedAccuracy(accuracyM) *
        (countingSteps && !_stationary ? _fixInflation(accuracyM) : 1.0) *
        (_pinned ? _pinnedFixInflation : (visualTracking ? _visualFixInflation : 1.0));
    final measurementVariance = trusted * trusted;
    final innovationE = measured.east - _east;
    final innovationN = measured.north - _north;
    final gateE = _outlierSigma * math.sqrt(_varEast + measurementVariance);
    final gateN = _outlierSigma * math.sqrt(_varNorth + measurementVariance);

    if (innovationE.abs() > gateE || innovationN.abs() > gateN) {
      if (_rejections == 0) _firstRejectionAtMs = timestampMs;
      _rejections++;
      final heldForMs = timestampMs - _firstRejectionAtMs;
      if (_rejections < _maxConsecutiveRejections && heldForMs < _maxRejectionHoldMs) {
        // Hold the estimate but let the uncertainty keep growing, so a
        // genuinely relocated agent is believed within a few seconds.
        return _publish(active, rejectedOutlier: true);
      }
      // Persistent disagreement means the estimate, not the fix, is wrong -
      // and a pin that disagrees with that many fixes has been left behind.
      _pinned = false;
      return _seed(position, accuracyM, timestampMs);
    }
    _rejections = 0;

    // --- correct -------------------------------------------------------
    final gainE = _varEast / (_varEast + measurementVariance);
    final gainN = _varNorth / (_varNorth + measurementVariance);
    _east += gainE * innovationE;
    _north += gainN * innovationN;
    _varEast *= (1.0 - gainE);
    _varNorth *= (1.0 - gainN);

    return _publish(active, rejectedOutlier: false);
  }

  /// Moves the estimate by one counted step.
  ///
  /// The drawn position moves by exactly the same amount, at once, rather than
  /// chasing it through the slew limiter: a step is the agent really moving,
  /// and the overlay has to keep pace with the camera or the plot appears to
  /// slide away as they approach it. The slew still governs GNSS corrections,
  /// which is what it is for.
  ///
  /// [timestampMs] must be on the same clock as the fixes. Returns null before
  /// the first fix, when there is no position to step from.
  StabilizedPosition? onStep({required double lengthM, required double headingDeg, required int timestampMs}) {
    if (lengthM <= 0) return null;
    final h = toRadians(headingDeg);
    _lastStepMs = timestampMs;
    _stationary = false;
    return _move(lengthM * math.sin(h), lengthM * math.cos(h), _stepUncertaintyFraction * lengthM, timestampMs);
  }

  /// Moves the estimate by the camera's displacement as visual-inertial
  /// tracking measured it, in true east-north metres.
  ///
  /// Like a step, it moves the drawn position by the same amount at once. Unlike
  /// a step it is measured rather than modelled - no step length, no assumption
  /// that the agent walks where they look - so it carries only a centimetre or
  /// two of uncertainty per metre, and while it flows GNSS is reduced to a slow
  /// drift correction. That is the whole point: the boundary stays standing
  /// where it is as the agent walks up to it.
  StabilizedPosition? onVisualMotion({required double dEast, required double dNorth, required int timestampMs}) {
    final previous = _lastVisualMs;
    _lastVisualMs = timestampMs;
    final distance = hypot(dEast, dNorth);
    final dtS = previous == 0 ? 0.0 : (timestampMs - previous) / 1000.0;
    if (dtS > 0 && distance / dtS > _visualMovingMps) {
      _lastStepMs = timestampMs;
      _lastVisualMotionMs = timestampMs;
      _stationary = false;
    }
    return _move(dEast, dNorth, 0.02 * distance + 0.001, timestampMs);
  }

  /// When visual tracking last saw the agent moving; 0 before any.
  int get lastVisualMotionMs => _lastVisualMotionMs;

  /// Declares that the agent is standing exactly at [position].
  ///
  /// For the moment the agent reaches a known point - the plot's access point,
  /// a surveyed corner - and says so. That point is worth more than any fix a
  /// phone will get there: it replaces the estimate outright, the drawn
  /// position jumps to it (the agent asked for that), and from then on fixes
  /// count ten times less, so a receiver several metres off cannot walk the
  /// overlay away from the point the agent is standing on.
  StabilizedPosition pinTo(LatLng position, {required int timestampMs, double accuracyM = 1.0}) {
    final published = _seed(position, accuracyM, timestampMs, varianceFloorM: accuracyM);
    _pinned = true;
    return published;
  }

  StabilizedPosition? _move(double dEast, double dNorth, double sigma, int timestampMs) {
    final existing = _frame;
    if (existing == null) return null;
    final active = existing.needsReanchor(_estimateLatLng(existing)) ? _reanchor(existing) : existing;

    _east += dEast;
    _north += dNorth;
    _renderEast += dEast;
    _renderNorth += dNorth;
    _varEast += sigma * sigma;
    _varNorth += sigma * sigma;
    return _publish(active, rejectedOutlier: false, atMs: timestampMs);
  }

  /// Forgets everything.
  ///
  /// Called when the agent's position changes discontinuously for a reason that
  /// is *not* measurement noise - starting a session, for instance. Such a jump is not an observation to be filtered against the
  /// old estimate; the old estimate no longer refers to anything.
  void reset() {
    _frame = null;
    _lastPublished = null;
    _rejections = 0;
    _firstRejectionAtMs = 0;
    _stationary = false;
    _renderSeeded = false;
    _lastPublishMs = 0;
    _lastStepMs = 0;
    _lastVisualMs = 0;
    _lastVisualMotionMs = 0;
    _pinned = false;
  }

  StabilizedPosition _seed(LatLng position, double accuracyM, int timestampMs, {double? varianceFloorM}) {
    final fresh = EnuFrame(position);
    _frame = fresh;
    _east = 0.0;
    _north = 0.0;
    final accuracy = varianceFloorM ?? _trustedAccuracy(accuracyM);
    _varEast = accuracy * accuracy;
    _varNorth = accuracy * accuracy;
    _lastFixMs = timestampMs;
    _rejections = 0;
    _firstRejectionAtMs = 0;
    _stationary = false;
    // A seed is a discontinuity by definition - first fix, or an estimate
    // abandoned as wrong. There is nothing to slew away from.
    _renderEast = 0.0;
    _renderNorth = 0.0;
    _renderSeeded = true;
    _lastPublishMs = timestampMs;
    return _publish(fresh, rejectedOutlier: false, atMs: timestampMs);
  }

  EnuFrame _reanchor(EnuFrame previous) {
    // Re-express the estimate against a new origin. Only the origin changes:
    // the estimate and its variance are physical quantities and survive
    // untouched, so re-anchoring is invisible on screen.
    final here = _estimateLatLng(previous);
    final fresh = EnuFrame(here);
    _frame = fresh;
    // The drawn position is carried across as a displacement from the
    // estimate, not reset. It is a physical place; only the origin changed.
    _renderEast -= _east;
    _renderNorth -= _north;
    _east = 0.0;
    _north = 0.0;
    return fresh;
  }

  LatLng _estimateLatLng(EnuFrame against) => against.toLatLng(Enu(_east, _north));

  StabilizedPosition _publish(EnuFrame active, {required bool rejectedOutlier, int? atMs}) {
    _advanceRender(atMs ?? _lastFixMs);

    final here = active.toLatLng(Enu(_renderEast, _renderNorth));
    final previous = _lastPublished;
    final shift = previous == null ? 0.0 : distanceM(previous, here);
    _lastPublished = here;
    return StabilizedPosition(
      position: here,
      uncertaintyM: uncertaintyM,
      stationary: _stationary,
      shiftM: shift,
      rejectedOutlier: rejectedOutlier,
    );
  }

  /// Moves the drawn position toward the estimate, at most so far.
  ///
  /// The cap is on *distance*, applied along the line to the estimate, rather
  /// than per axis. A per-axis cap would let a diagonal correction travel
  /// sqrt(2) times the intended rate and would bend the path toward the axes,
  /// which is visible as the overlay sidling rather than sliding.
  void _advanceRender(int atMs) {
    if (!_renderSeeded) {
      _renderEast = _east;
      _renderNorth = _north;
      _renderSeeded = true;
      _lastPublishMs = atMs;
      return;
    }

    final dtS = math.max(atMs - _lastPublishMs, 0) / 1000.0;
    _lastPublishMs = atMs;

    final gapE = _east - _renderEast;
    final gapN = _north - _renderNorth;
    final gap = hypot(gapE, gapN);
    if (gap < 1e-6) return;

    if (gap > _renderSnapM) {
      _renderEast = _east;
      _renderNorth = _north;
      return;
    }

    final rate = visualTracking
        ? _renderSlewVisualMps
        : (_stationary ? _renderSlewStationaryMps : _renderSlewWalkingMps);
    final limit = rate * dtS;
    if (limit >= gap) {
      _renderEast = _east;
      _renderNorth = _north;
    } else {
      _renderEast += gapE / gap * limit;
      _renderNorth += gapN / gap * limit;
    }
  }

  /// Doppler speed decides when the receiver reports it. Otherwise fall back to
  /// asking whether the displacement since the last estimate is bigger than the
  /// noise that displacement is measured with - below that, "moved" and "did
  /// not move" are indistinguishable and standing still is the safer reading.
  bool _isStationary(double? speedMps, Enu measured, double dtS) {
    if (visualTracking) return _lastFixMs - _lastVisualMotionMs > _stepStillnessMs;
    if (countingSteps) return _lastFixMs - _lastStepMs > _stepStillnessMs;
    if (speedMps != null) return speedMps < _stationarySpeedMps;
    if (dtS <= 0.0) return _stationary;
    final displacement = hypot(measured.east - _east, measured.north - _north);
    return displacement / dtS < _stationarySpeedMps;
  }

  /// 1 for a good fix, rising to [_poorFixInflation] across 6-10 m reported
  /// accuracy. Smooth, so a fix hovering around the threshold does not make the
  /// overlay jump between two weightings.
  static double _fixInflation(double accuracyM) {
    if (!accuracyM.isFinite) return _poorFixInflation;
    final t = clampDouble((accuracyM - _poorFixFromM) / (_poorFixFullM - _poorFixFromM), 0.0, 1.0);
    return 1.0 + (_poorFixInflation - 1.0) * t;
  }

  double _trustedAccuracy(double reported) =>
      reported.isFinite && reported > _minTrustedAccuracyM ? reported : _minTrustedAccuracyM;
}
