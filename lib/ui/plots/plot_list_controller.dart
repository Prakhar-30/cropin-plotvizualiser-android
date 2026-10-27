import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../app_container.dart';
import '../../core/geo/enu.dart';
import '../../core/heading/course_over_ground_detector.dart';
import '../../data/plot.dart';
import '../../location/location_source.dart';

/// A cached plot plus how far the agent currently is from it.
class PlotListItem {
  const PlotListItem(this.plot, this.distanceM);

  final Plot plot;
  final double? distanceM;
}

class PlotListState {
  const PlotListState({
    this.items = const [],
    this.syncing = false,
    this.lastSyncMessage,
    this.hasFix = false,
  });

  final List<PlotListItem> items;
  final bool syncing;
  final String? lastSyncMessage;
  final bool hasFix;

  PlotListState copyWith({
    List<PlotListItem>? items,
    bool? syncing,
    String? Function()? lastSyncMessage,
    bool? hasFix,
  }) =>
      PlotListState(
        items: items ?? this.items,
        syncing: syncing ?? this.syncing,
        lastSyncMessage: lastSyncMessage == null ? this.lastSyncMessage : lastSyncMessage(),
        hasFix: hasFix ?? this.hasFix,
      );
}

/// The cached plot list.
///
/// Rows come from the database and appear whether or not there is signal;
/// syncing is an explicit button, never a precondition for seeing anything.
class PlotListController extends ValueNotifier<PlotListState> {
  PlotListController(this._container)
      : _locationSource = _container.createLocationSource(),
        super(const PlotListState()) {
    _plotsSubscription = _container.plots.observePlots().listen((cached) {
      _plots = cached;
      _recompute();
    });
    _locationSource.location.addListener(_onLocation);
    _locationSource.start();
  }

  final AppContainer _container;
  final LocationSource _locationSource;
  late final StreamSubscription<List<Plot>> _plotsSubscription;

  List<Plot> _plots = const [];
  LatLng? _here;

  void _onLocation() {
    final LocationSample? sample = _locationSource.location.value;
    _here = sample?.position;
    _recompute(hasFix: sample != null);
  }

  // Plots are drawn in the web tool and only ever read here. Two places that
  // can create a boundary means two definitions of what a boundary is, and the
  // one on a phone - eyeballed, unverified, standing in the middle of the
  // field - is the one that would end up in a dispute.

  /// Pulls fresh plots around the agent, or everything if there is no fix yet.
  Future<void> sync() async {
    if (value.syncing) return;
    value = value.copyWith(syncing: true, lastSyncMessage: () => null);
    final result = await _container.plots.sync(around: _here);
    final message = switch (result) {
      SyncSuccess(widenedToEverything: true, :final plotCount) =>
        'No plots within 5 km — cached all $plotCount instead',
      SyncSuccess(:final plotCount) => 'Cached $plotCount plot(s)',
      // Offline is the expected state at a rural site, so this reads as a
      // status line rather than an error.
      SyncFailed(:final reason) => 'No connection ($reason) — showing ${_plots.length} cached plot(s)',
    };
    await _container.telemetry.syncPending();
    value = value.copyWith(syncing: false, lastSyncMessage: () => message);
  }

  /// Stops the GNSS receiver while the app is in the background; the list
  /// only needs a fix to sort by distance, and nobody is looking at it.
  void pause() => _locationSource.stop();

  void resume() => _locationSource.start();

  PlotListItem? itemFor(String plotId) {
    for (final item in value.items) {
      if (item.plot.id == plotId) return item;
    }
    return null;
  }

  /// One notification per fix or cache change, never two.
  void _recompute({bool? hasFix}) {
    final from = _here;
    final items = [
      for (final plot in _plots) PlotListItem(plot, from == null ? null : distanceM(from, plot.centroid)),
    ]..sort((a, b) => (a.distanceM ?? double.maxFinite).compareTo(b.distanceM ?? double.maxFinite));
    value = value.copyWith(items: items, hasFix: hasFix);
  }

  @override
  void dispose() {
    _plotsSubscription.cancel();
    _locationSource.location.removeListener(_onLocation);
    _locationSource.stop();
    super.dispose();
  }
}
