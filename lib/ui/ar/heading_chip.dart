import 'package:flutter/material.dart';

import '../../core/heading/heading_model.dart';
import '../../pose/pose_source.dart';
import '../theme.dart';

/// Persistent heading-confidence chip. Not optional.
///
/// Without it the agent has no way to tell a heading good to 3 degrees from one
/// good to 25, and both look identical on screen - a confident overlay sitting on
/// the wrong field. The **Unreliable** state also carries the single most
/// valuable instruction in the app: "walk a few steps to lock direction" turns
/// the worst failure mode into a two-second user action.
class HeadingChip extends StatelessWidget {
  const HeadingChip({super.key, required this.status});

  final HeadingStatus status;

  @override
  Widget build(BuildContext context) {
    final (dot, title) = switch (status.confidence) {
      HeadingConfidence.locked => (const Color(0xFF4ADE80), 'Heading locked'),
      HeadingConfidence.holding => (const Color(0xFFF59E0B), 'Heading holding'),
      HeadingConfidence.unreliable => (const Color(0xFF9CA3AF), 'Heading unreliable'),
    };

    final error = status.expectedErrorDeg.toInt();
    final detail = switch (status.confidence) {
      HeadingConfidence.locked => switch (status.source) {
          HeadingSource.courseOverGround => 'from your walk  ±$error°',
          HeadingSource.landmarkSnap => 'from landmark snap  ±$error°',
          HeadingSource.magnetometer => 'compass  ±$error°',
        },
      HeadingConfidence.holding => 'gyro-carried  ${status.ageSeconds}s since fix',
      HeadingConfidence.unreliable => 'compass only — walk a few steps to lock direction',
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: PlotFinderColors.scrim, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(detail, style: const TextStyle(color: PlotFinderColors.mutedText, fontSize: 12)),
        ],
      ),
    );
  }
}
