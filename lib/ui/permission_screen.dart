import 'package:flutter/material.dart';

import 'theme.dart';

/// What the permission gate shows until camera and location are granted.
class PermissionScreen extends StatelessWidget {
  const PermissionScreen({super.key, required this.onGrant, required this.onOpenSettings});

  final VoidCallback onGrant;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Hero(topInset: topInset),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Plot Finder needs the camera and your location',
                          style: TextStyle(fontSize: 22, height: 1.27, fontWeight: FontWeight.w700, color: GrowColors.text),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Both are used on this phone only. Neither leaves the device.',
                          style: TextStyle(fontSize: 14, height: 1.43, color: GrowColors.mutedText),
                        ),
                        const SizedBox(height: 16),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: GrowColors.surface,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: GrowColors.outline),
                          ),
                          child: const Column(
                            children: [
                              _PermissionRow(
                                icon: Icons.photo_camera_outlined,
                                title: 'Camera',
                                detail: 'The view the plot boundary is drawn on.',
                              ),
                              Divider(indent: 16, endIndent: 16),
                              _PermissionRow(
                                icon: Icons.my_location,
                                title: 'Precise location',
                                detail: 'Anchors the boundary to the ground and sorts plots by distance.',
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: GrowColors.successTint,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.verified_user_outlined, size: 18, color: GrowColors.successText),
                              SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Works offline once plots are cached. Nothing is uploaded while you search.',
                                  style: TextStyle(fontSize: 13, height: 1.38, color: GrowColors.successText),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton(
                    onPressed: onGrant,
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
                    child: const Text('Grant permissions'),
                  ),
                  const SizedBox(height: 8),
                  // Once Android stops showing the dialog, the setting is the
                  // only way back.
                  TextButton(onPressed: onOpenSettings, child: const Text('Open app settings')),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.topInset});

  final double topInset;

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.fromLTRB(24, topInset + 20, 24, 32),
        decoration: const BoxDecoration(
          color: GrowColors.primary,
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                // Embedded in a host app this is a pushed page; someone who
                // declines needs a way out besides the system gesture.
                if (Navigator.of(context).canPop())
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: BackButton(color: Colors.white),
                  ),
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.place_outlined, size: 20, color: GrowColors.primary),
                ),
                const SizedBox(width: 10),
                const Text('Plot Finder', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
              ],
            ),
            const SizedBox(height: 20),
            Semantics(
              label: 'Phone camera view with the target plot outlined on the ground',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: const AspectRatio(
                  aspectRatio: 342 / 180,
                  child: CustomPaint(painter: _FieldIllustrationPainter()),
                ),
              ),
            ),
          ],
        ),
      );
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({required this.icon, required this.title, required this.detail});

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(color: GrowColors.primaryTint, shape: BoxShape.circle),
              child: Icon(icon, size: 20, color: GrowColors.primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: GrowColors.text)),
                  const SizedBox(height: 2),
                  Text(detail, style: const TextStyle(fontSize: 13, height: 1.38, color: GrowColors.mutedText)),
                ],
              ),
            ),
          ],
        ),
      );
}

/// A field seen through the phone with the target plot outlined: what the
/// permissions are for, in one picture.
class _FieldIllustrationPainter extends CustomPainter {
  const _FieldIllustrationPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 342;
    final sy = size.height / 180;
    Offset p(double x, double y) => Offset(x * sx, y * sy);
    Path poly(List<Offset> points) => Path()..addPolygon(points, true);

    canvas.drawRect(Offset.zero & size, Paint()..color = GrowColors.primaryDark);
    canvas.drawPath(poly([p(0, 84), p(342, 70), p(342, 180), p(0, 180)]), Paint()..color = const Color(0xFF2E4A3A));
    canvas.drawPath(poly([p(0, 84), p(120, 79), p(60, 180), p(0, 180)]), Paint()..color = const Color(0xFF35553F));
    canvas.drawPath(poly([p(222, 74), p(342, 70), p(342, 180), p(290, 180)]), Paint()..color = const Color(0xFF35553F));

    final plot = poly([p(128, 96), p(236, 91), p(272, 158), p(92, 164)]);
    canvas.drawPath(plot, Paint()..color = const Color(0x3864D2FF));
    canvas.drawPath(
      plot,
      Paint()
        ..color = const Color(0xFF64D2FF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(p(182, 170), 8, Paint()..color = Colors.white);
    canvas.drawCircle(p(182, 170), 6, Paint()..color = const Color(0xFFF59E0B));
  }

  @override
  bool shouldRepaint(_FieldIllustrationPainter oldDelegate) => false;
}
