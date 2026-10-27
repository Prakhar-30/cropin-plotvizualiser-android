import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../formatting.dart';
import '../plots/plot_list_controller.dart';
import '../theme.dart';

/// The way in: what is on the phone, a sync button, and the camera.
///
/// There is no plot to pick. The AR view shows every cached plot within reach
/// with its crop condition, so choosing one first was a step that changed
/// nothing on screen. What the agent does need before walking out is to know
/// the phone holds the plots - how many, and how fresh - and a way to refresh
/// them while there is still signal.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.state, required this.onSync, required this.onStart});

  final PlotListState state;
  final VoidCallback onSync;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final count = state.items.length;
    final nearest = state.items.isEmpty ? null : state.items.first;
    return Scaffold(
      body: Column(
        children: [
          const _Header(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              children: [
                _SyncCard(state: state, onSync: onSync),
                const SizedBox(height: 12),
                _Card(
                  icon: Icons.near_me_outlined,
                  title: 'Nearest plot',
                  child: Text(
                    switch ((nearest, state.hasFix)) {
                      (null, _) => 'No plots on this phone yet',
                      (_, false) => 'Waiting for GPS…',
                      (final n?, true) => '${n.plot.name} · ${formatDistance(n.distanceM ?? double.infinity)}',
                    },
                    style: const TextStyle(fontSize: 14, color: GrowColors.text),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'The AR view shows every plot within 400 m, with critical (red) and moderate '
                  '(yellow) crop condition on the ground and as drop points. Sync while you have '
                  'signal; in the field it needs none.',
                  style: TextStyle(fontSize: 12.5, height: 1.4, color: GrowColors.mutedText),
                ),
              ],
            ),
          ),
          _StartBar(enabled: count > 0, syncing: state.syncing, onStart: onStart),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) => Container(
        color: GrowColors.primary,
        padding: EdgeInsets.fromLTRB(20, MediaQuery.paddingOf(context).top + 12, 20, 18),
        child: Row(
          children: [
            // Embedded in a host app this is a pushed page, and needs a way
            // back besides the system gesture.
            if (Navigator.of(context).canPop())
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: BackButton(color: Colors.white),
              ),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Plot Finder', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w500)),
                  SizedBox(height: 2),
                  Text(
                    'Crop condition on the ground, through the camera',
                    style: TextStyle(color: GrowColors.onPrimaryMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

class _Card extends StatelessWidget {
  const _Card({required this.icon, required this.title, required this.child, this.trailing});

  final IconData icon;
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: GrowColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: GrowColors.outline),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 22, color: GrowColors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: GrowColors.mutedText),
                  ),
                  const SizedBox(height: 4),
                  child,
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 12), trailing!],
          ],
        ),
      );
}

class _SyncCard extends StatelessWidget {
  const _SyncCard({required this.state, required this.onSync});

  final PlotListState state;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final count = state.items.length;
    final newest = state.items.isEmpty ? null : state.items.map((i) => i.plot.syncedAtMs).reduce(math.max);
    return _Card(
      icon: Icons.cloud_download_outlined,
      title: 'On this phone',
      trailing: FilledButton.tonalIcon(
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            count == 1 ? '1 plot' : '$count plots',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: GrowColors.text),
          ),
          const SizedBox(height: 2),
          Text(
            newest == null ? 'Nothing synced yet' : 'Last synced ${formatCacheAge(newest)}',
            style: const TextStyle(fontSize: 13, color: GrowColors.text),
          ),
          if (state.lastSyncMessage case final message?) ...[
            const SizedBox(height: 4),
            Text(message, style: const TextStyle(fontSize: 12, color: GrowColors.mutedText)),
          ],
        ],
      ),
    );
  }
}

class _StartBar extends StatelessWidget {
  const _StartBar({required this.enabled, required this.syncing, required this.onStart});

  final bool enabled;
  final bool syncing;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(
          color: GrowColors.surface,
          border: Border(top: BorderSide(color: GrowColors.outline)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: enabled ? onStart : null,
                icon: const Icon(Icons.view_in_ar),
                label: Text(
                  enabled
                      ? 'Start AR view'
                      : syncing
                          ? 'Syncing plots…'
                          : 'Sync plots to start',
                ),
              ),
            ),
          ),
        ),
      );
}
