import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';

/// What the AR view is waiting for when it first opens, made visible.
///
/// A cold GNSS start takes 10-30 seconds, and ARCore needs a moment of camera
/// motion before it tracks. Without this the agent sees a live camera and
/// nothing on it, and reasonably concludes the feature is broken. With it they
/// see what is ready, what is still coming, and - when it is slow - what to do
/// about it.
///
/// Centred over the camera, where the plot will appear, so the eye is already
/// in the right place when it does. It never takes touches: the sheet below
/// stays usable throughout.
class StartupLoader extends StatefulWidget {
  const StartupLoader({
    super.key,
    required this.hasFix,
    required this.usesTracking,
    required this.tracking,
  });

  final bool hasFix;

  /// ARCore motion tracking is part of this session.
  final bool usesTracking;
  final bool tracking;

  /// True once nothing is left to wait for.
  static bool done({required bool hasFix, required bool usesTracking, required bool tracking}) =>
      hasFix && (!usesTracking || tracking);

  @override
  State<StartupLoader> createState() => _StartupLoaderState();
}

class _StartupLoaderState extends State<StartupLoader> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();
  late final Timer _clock;
  final Stopwatch _elapsed = Stopwatch()..start();

  /// After this long without a fix, the agent gets told what helps.
  static const int _slowAfterS = 20;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = _elapsed.elapsed.inSeconds;
    final slow = !widget.hasFix && seconds >= _slowAfterS;
    return IgnorePointer(
      child: Center(
        child: Container(
          width: 268,
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
          decoration: BoxDecoration(
            color: const Color(0xE60B0F14),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0x22FFFFFF)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 56,
                height: 56,
                child: AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, _) => CustomPaint(painter: _PulsePainter(_pulse.value)),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Finding your position',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 14),
              const _Step(label: 'Camera', done: true),
              if (widget.usesTracking)
                _Step(
                  label: 'Motion tracking',
                  done: widget.tracking,
                  pending: 'move the phone slowly',
                ),
              _Step(label: 'GPS', done: widget.hasFix, pending: '${seconds}s'),
              if (slow) ...[
                const SizedBox(height: 10),
                const Text(
                  'Taking longer than usual. Step into the open, away from roofs and trees.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: PlotFinderColors.warning, fontSize: 12, height: 1.4),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.label, required this.done, this.pending = ''});

  final String label;
  final bool done;
  final String pending;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: done
                  ? const Icon(Icons.check_circle, size: 18, color: Color(0xFF4ADE80))
                  : const Padding(
                      padding: EdgeInsets.all(2),
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(color: done ? PlotFinderColors.mutedText : Colors.white, fontSize: 14),
              ),
            ),
            Text(
              done ? 'ready' : pending,
              style: const TextStyle(color: PlotFinderColors.mutedText, fontSize: 12),
            ),
          ],
        ),
      );
}

/// A location pin with two rings spreading out from it, offset by half a
/// cycle - the familiar "searching for signal" motion.
class _PulsePainter extends CustomPainter {
  _PulsePainter(this.t);

  final double t;

  static const Color _green = Color(0xFF4ADE80);

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final maxRadius = size.width / 2;
    for (final phase in [t, (t + 0.5) % 1.0]) {
      canvas.drawCircle(
        centre,
        8 + (maxRadius - 8) * phase,
        Paint()
          ..color = _green.withAlpha(alpha8((1 - phase) * 0.7))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    canvas.drawCircle(centre, 9, Paint()..color = _green);
    canvas.drawCircle(centre, 3.5, Paint()..color = const Color(0xFF0B0F14));
  }

  @override
  bool shouldRepaint(_PulsePainter oldDelegate) => oldDelegate.t != t;
}
