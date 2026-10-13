import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../sim/simulation_engine.dart';
import '../theme.dart';

/// Debug-only controls that drive the overlay from a desk.
///
/// Worth the code several times over: the failure modes this app exists to
/// handle only occur in a field, and "drive to a farm and walk 20 m" is not a
/// debug cycle. The error sliders also make the demo reproducible on command -
/// dial heading error to 20 degrees and watch the boundary settle over the
/// neighbouring plot, which is the argument for the whole heading architecture in
/// one gesture.
///
/// Only reachable in debug builds; see `AppContainer.simulationAvailable`.
class SimulationPanel extends StatefulWidget {
  const SimulationPanel({super.key, required this.engine});

  final SimulationEngine engine;

  @override
  State<SimulationPanel> createState() => _SimulationPanelState();
}

class _SimulationPanelState extends State<SimulationPanel> {
  double _heading = 0;
  double _gnssError = 0;
  double _headingError = 0;
  double _accuracy = 6;

  SimulationEngine get _engine => widget.engine;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: const BoxDecoration(
        color: Color(0xE60B0F14),
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('SIMULATION', style: TextStyle(color: PlotFinderColors.warning, fontSize: 11)),
          Row(
            children: [
              _WalkPad(onWalk: _engine.move),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  children: [
                    _LabelledSlider(
                      label: 'Aim  ${_heading.toInt()}°',
                      value: _heading,
                      min: 0,
                      max: 359,
                      onChanged: (v) {
                        setState(() => _heading = v);
                        _engine.aim(v);
                      },
                    ),
                    _LabelledSlider(
                      label: 'Heading error  ${_headingError.toInt()}°',
                      value: _headingError,
                      min: 0,
                      max: 45,
                      onChanged: (v) {
                        setState(() => _headingError = v);
                        _engine.headingErrorDeg = v;
                        _engine.refresh();
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
          _LabelledSlider(
            label: 'GNSS error  ${_gnssError.toInt()} m',
            value: _gnssError,
            min: 0,
            max: 30,
            onChanged: (v) {
              setState(() => _gnssError = v);
              _engine.gnssErrorM = v;
              _engine.refresh();
            },
          ),
          _LabelledSlider(
            label: 'Reported accuracy  ${_accuracy.toInt()} m',
            value: _accuracy,
            min: 1,
            max: 30,
            onChanged: (v) {
              setState(() => _accuracy = v);
              _engine.reportedAccuracyM = v;
              _engine.refresh();
            },
          ),
        ],
      ),
    );
  }
}

class _LabelledSlider extends StatelessWidget {
  const _LabelledSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(color: PlotFinderColors.mutedText, fontSize: 11)),
          SizedBox(height: 32, child: Slider(value: value, min: min, max: max, onChanged: onChanged)),
        ],
      );
}

/// Thumb pad that walks the simulated agent.
///
/// Movement is world-absolute: dragging up walks north regardless of where the
/// phone is aimed, which keeps "walk to lock a heading" separable from "turn to
/// look at the plot" while debugging.
class _WalkPad extends StatefulWidget {
  const _WalkPad({required this.onWalk});

  final void Function(double eastMps, double northMps) onWalk;

  @override
  State<_WalkPad> createState() => _WalkPadState();
}

class _WalkPadState extends State<_WalkPad> {
  static const double _size = 96;
  static const double _radius = _size / 2;
  static const double _maxSpeedMps = 1.6;

  /// Keeps walking while the thumb is held still off-centre.
  ///
  /// Drag events stop arriving the moment the thumb stops moving, so without
  /// this the agent froze mid-walk and a twenty-metre course-over-ground lock
  /// needed fifteen seconds of constant wiggling. Five steps a second keeps the
  /// simulator's 0.5 s step cap from ever being reached.
  Timer? _stride;
  Offset _knob = Offset.zero;

  void _walk() => widget.onWalk(
        _knob.dx / _radius * _maxSpeedMps,
        // Screen y grows downward; dragging up must walk north.
        -_knob.dy / _radius * _maxSpeedMps,
      );

  void _release() {
    _stride?.cancel();
    _stride = null;
    setState(() => _knob = Offset.zero);
    widget.onWalk(0, 0);
  }

  @override
  void dispose() {
    _stride?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const radius = _radius;
    return GestureDetector(
      onPanStart: (_) => _stride ??= Timer.periodic(const Duration(milliseconds: 200), (_) => _walk()),
      onPanUpdate: (details) {
        var next = _knob + details.delta;
        final length = next.distance;
        if (length > radius) next = next * (radius / length);
        setState(() => _knob = next);
        _walk();
      },
      onPanEnd: (_) => _release(),
      onPanCancel: _release,
      child: Container(
        width: _size,
        height: _size,
        decoration: const BoxDecoration(color: Color(0x33FFFFFF), shape: BoxShape.circle),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Transform.translate(
              offset: Offset(
                math.max(-radius + 14, math.min(radius - 14, _knob.dx)),
                math.max(-radius + 14, math.min(radius - 14, _knob.dy)),
              ),
              child: Container(
                width: 28,
                height: 28,
                decoration: const BoxDecoration(color: PlotFinderColors.warning, shape: BoxShape.circle),
              ),
            ),
            const IgnorePointer(
              child: Text('walk', style: TextStyle(color: PlotFinderColors.background, fontSize: 9)),
            ),
          ],
        ),
      ),
    );
  }
}
