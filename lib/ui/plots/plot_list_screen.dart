import 'package:flutter/material.dart';

import '../formatting.dart';
import 'plot_list_controller.dart';

/// Screen 1: cached plots, nearest first, with a sync button.
class PlotListScreen extends StatelessWidget {
  const PlotListScreen({super.key, required this.controller, required this.onOpenPlot});

  final PlotListController controller;
  final ValueChanged<String> onOpenPlot;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ValueListenableBuilder<PlotListState>(
            valueListenable: controller,
            builder: (context, state, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Plots', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
                Text(
                  state.hasFix
                      ? '${state.items.length} cached, nearest first'
                      : '${state.items.length} cached — waiting for a fix to sort by distance',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: state.syncing ? null : controller.sync,
                      child: Text(state.syncing ? 'Syncing…' : 'Sync', maxLines: 1),
                    ),
                  ),
                ),
                if (state.lastSyncMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(state.lastSyncMessage!, style: TextStyle(fontSize: 12, color: muted)),
                  ),
                if (state.items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: Text(
                      'Nothing cached yet. Tap Sync while you still have signal — the field '
                      'will not have any.\n\nPlots are drawn in the web tool; this app finds them.',
                      style: TextStyle(color: muted),
                    ),
                  )
                else
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: ListView.separated(
                        itemCount: state.items.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) => _PlotRow(item: state.items[i], onTap: onOpenPlot),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlotRow extends StatelessWidget {
  const _PlotRow({required this.item, required this.onTap});

  final PlotListItem item;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final distance = item.distanceM;
    return InkWell(
      key: ValueKey(item.plot.id),
      onTap: () => onTap(item.plot.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(item.plot.name, style: const TextStyle(fontWeight: FontWeight.w500))),
                Text(distance == null ? '—' : formatDistance(distance), style: TextStyle(color: scheme.primary)),
              ],
            ),
            Text(
              '${item.plot.id}  ·  ${formatHectares(item.plot.areaSqM)}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
