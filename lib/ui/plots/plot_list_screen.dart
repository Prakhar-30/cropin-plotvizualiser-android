import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/geo/enu.dart';
import '../../core/geo/polygon_geometry.dart';
import '../../core/render/plot_palette.dart';
import '../../data/plot.dart';
import '../formatting.dart';
import '../theme.dart';
import 'plot_list_controller.dart';

/// Screen 1: cached plots, nearest first, with search and a sync bar.
class PlotListScreen extends StatefulWidget {
  const PlotListScreen({super.key, required this.controller, required this.onOpenPlot});

  final PlotListController controller;
  final ValueChanged<String> onOpenPlot;

  @override
  State<PlotListScreen> createState() => _PlotListScreenState();
}

class _PlotListScreenState extends State<PlotListScreen> {
  String _query = '';

  List<PlotListItem> _filter(List<PlotListItem> items) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return items;
    return [
      for (final item in items)
        if (item.plot.name.toLowerCase().contains(query) || item.plot.id.toLowerCase().contains(query)) item,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PlotListState>(
      valueListenable: widget.controller,
      builder: (context, state, _) {
        final visible = _filter(state.items);
        return Scaffold(
          body: Column(
            children: [
              _Header(
                count: state.items.length,
                hasFix: state.hasFix,
                onQueryChanged: (value) => setState(() => _query = value),
              ),
              Expanded(
                child: state.items.isEmpty
                    ? const _EmptyState()
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                        children: [
                          Align(alignment: Alignment.centerLeft, child: _FixChip(hasFix: state.hasFix)),
                          const SizedBox(height: 8),
                          for (final item in visible)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _PlotCard(item: item, onTap: widget.onOpenPlot),
                            ),
                          if (visible.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 24),
                              child: Text(
                                'No cached plot matches that search.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: GrowColors.mutedText),
                              ),
                            ),
                          const Padding(
                            padding: EdgeInsets.only(top: 4),
                            child: Text(
                              'Boundaries are drawn in the web tool. This app finds them.',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12, color: GrowColors.mutedText),
                            ),
                          ),
                        ],
                      ),
              ),
              _SyncBar(state: state, onSync: widget.controller.sync),
            ],
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.count, required this.hasFix, required this.onQueryChanged});

  final int count;
  final bool hasFix;
  final ValueChanged<String> onQueryChanged;

  @override
  Widget build(BuildContext context) => Container(
        color: GrowColors.primary,
        padding: EdgeInsets.fromLTRB(20, MediaQuery.paddingOf(context).top + 12, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Plots', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w500)),
            Text(
              hasFix ? '$count cached · nearest first' : '$count cached · waiting for a fix to sort by distance',
              style: const TextStyle(color: GrowColors.onPrimaryMuted, fontSize: 12),
            ),
            if (count > 0) ...[
              const SizedBox(height: 12),
              TextField(
                onChanged: onQueryChanged,
                textInputAction: TextInputAction.search,
                style: const TextStyle(fontSize: 15, color: GrowColors.text),
                decoration: InputDecoration(
                  hintText: 'Search by plot name or ID',
                  hintStyle: const TextStyle(color: GrowColors.mutedText),
                  prefixIcon: const Icon(Icons.search, color: GrowColors.mutedText),
                  filled: true,
                  fillColor: Colors.white,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                ),
              ),
            ],
          ],
        ),
      );
}

class _FixChip extends StatelessWidget {
  const _FixChip({required this.hasFix});

  final bool hasFix;

  @override
  Widget build(BuildContext context) {
    final (background, foreground, dot, label) = hasFix
        ? (GrowColors.successTint, GrowColors.successText, GrowColors.success, 'GPS fix')
        : (GrowColors.warningTint, GrowColors.warning, GrowColors.warning, 'Waiting for a GPS fix');
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(14)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: foreground, fontSize: 12, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

class _PlotCard extends StatelessWidget {
  const _PlotCard({required this.item, required this.onTap});

  final PlotListItem item;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final plot = item.plot;
    final distance = item.distanceM;
    return Material(
      key: ValueKey(plot.id),
      color: GrowColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: GrowColors.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onTap(plot.id),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(color: GrowColors.sketchPlate, borderRadius: BorderRadius.circular(10)),
                child: CustomPaint(painter: PlotThumbnailPainter(plot)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      plot.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: GrowColors.text),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${plot.id} · ${formatHectares(plot.areaSqM)}',
                      style: const TextStyle(fontSize: 12, color: GrowColors.mutedText),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Cached ${formatCacheAge(plot.syncedAtMs)}',
                      style: const TextStyle(fontSize: 12, color: GrowColors.mutedText),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    distance == null ? '—' : formatDistance(distance),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: GrowColors.primary),
                  ),
                  if (distance != null)
                    const Text('away', style: TextStyle(fontSize: 11, color: GrowColors.mutedText)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_download_outlined, size: 48, color: GrowColors.primary),
              SizedBox(height: 16),
              Text(
                'Nothing cached yet',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: GrowColors.text),
              ),
              SizedBox(height: 8),
              Text(
                'Tap Sync now while you still have signal. The field will not have any.\n\n'
                'Plots are drawn in the web tool; this app finds them.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, height: 1.43, color: GrowColors.mutedText),
              ),
            ],
          ),
        ),
      );
}

/// Sync lives at the bottom, within thumb reach, rather than in the header.
class _SyncBar extends StatelessWidget {
  const _SyncBar({required this.state, required this.onSync});

  final PlotListState state;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final newest = state.items.isEmpty ? null : state.items.map((i) => i.plot.syncedAtMs).reduce(math.max);
    final title = newest == null ? 'Nothing cached yet' : 'Last synced ${formatCacheAge(newest)}';
    final detail = state.lastSyncMessage ?? 'Sync while you have signal';
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: GrowColors.surface,
        border: Border(top: BorderSide(color: GrowColors.outline)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: GrowColors.text)),
                    const SizedBox(height: 2),
                    Text(detail, style: const TextStyle(fontSize: 12, color: GrowColors.mutedText)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: state.syncing ? null : onSync,
                icon: state.syncing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: GrowColors.mutedText),
                      )
                    : const Icon(Icons.sync, size: 18),
                label: Text(state.syncing ? 'Syncing…' : 'Sync now', maxLines: 1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The boundary in its palette colour, scaled into a small square. Drawn from
/// the cached ring, so it is there offline like everything else on the list.
class PlotThumbnailPainter extends CustomPainter {
  PlotThumbnailPainter(this.plot);

  final Plot plot;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = EnuFrame(plot.centroid);
    final ring = openRing([for (final p in plot.ring) frame.toEnu(p)]);
    if (ring.length < 3) return;

    final minE = ring.map((p) => p.east).reduce(math.min);
    final maxE = ring.map((p) => p.east).reduce(math.max);
    final minN = ring.map((p) => p.north).reduce(math.min);
    final maxN = ring.map((p) => p.north).reduce(math.max);
    const padding = 8.0;
    final spanE = math.max(maxE - minE, 1.0);
    final spanN = math.max(maxN - minN, 1.0);
    final scale = math.min((size.width - padding * 2) / spanE, (size.height - padding * 2) / spanN);
    final offsetX = (size.width - spanE * scale) / 2;
    final offsetY = (size.height - spanN * scale) / 2;
    Offset toScreen(Enu p) =>
        Offset(offsetX + (p.east - minE) * scale, size.height - offsetY - (p.north - minN) * scale);

    final colour = Color(plotColour(plot.colourIndex).argb);
    final path = Path()..addPolygon([for (final p in ring) toScreen(p)], true);
    canvas.drawPath(path, Paint()..color = colour.withValues(alpha: 0.18));
    canvas.drawPath(
      path,
      Paint()
        ..color = colour
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(PlotThumbnailPainter oldDelegate) => oldDelegate.plot != plot;
}
