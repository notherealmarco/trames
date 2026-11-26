import 'dart:async';

import 'package:maplibre_gl/maplibre_gl.dart';

import 'backend/backend.dart';
import 'backend/heading.dart';

/// A bus on the map: animates from where it is drawn to its latest position.
class TrackedBus {
  TrackedBus(this.vehicle, this.color)
      : _from = vehicle.position,
        _to = vehicle.position,
        drawn = vehicle.position;

  Vehicle vehicle;
  String color;

  /// Which way it heads (degrees from north), for the cone; null: unknown.
  double? heading;

  /// Direction of its last real move (see [headingOfMove]).
  double? _moveHeading;
  LatLng _from;
  LatLng _to;
  LatLng drawn;
  DateTime _animStart = DateTime.now();

  void update(Vehicle v, String c) {
    _moveHeading = headingOfMove(vehicle.position, v.position) ?? _moveHeading;
    _from = drawn;
    _to = v.position;
    _animStart = DateTime.now();
    vehicle = v;
    color = c;
  }

  /// Returns true while still moving.
  bool tick(Duration animDuration) {
    final t = DateTime.now().difference(_animStart).inMilliseconds / animDuration.inMilliseconds;
    final k = t.clamp(0.0, 1.0);
    drawn = LatLng(
      _from.latitude + (_to.latitude - _from.latitude) * k,
      _from.longitude + (_to.longitude - _from.longitude) * k,
    );
    return t < 1.0;
  }
}


/// Draws a set of buses on a GeoJSON map source, animating each from where
/// it is to its newest position. Whoever follows the buses (a ride, a line,
/// the map area) pushes them with [show]; this only draws.
///
/// Buses are a map layer, not widgets over the platform view; frames are
/// pushed at [frameInterval] only while something moves.
class LiveBusTracker {
  LiveBusTracker({
    required this.onFrame,
    this.pathOf,
    this.stopPosition,
    this.animation = const Duration(seconds: 4),
    this.frameInterval = const Duration(milliseconds: 66),
  });

  final Future<void> Function(Map<String, dynamic> geojson) onFrame;

  /// The path a shown bus drives along (its trip's shape), when known: its
  /// heading is the path's direction there. Without it, or off the path,
  /// the direction it last moved in.
  final List<LatLng>? Function(String key, Vehicle vehicle)? pathOf;

  /// Where a stop is, by id, when known: a bus heads towards the stop the
  /// feed says it's going to (see [_resolveHeading]).
  final LatLng? Function(String stopId)? stopPosition;

  /// How long a bus takes to glide to a new position.
  final Duration animation;
  final Duration frameInterval;

  /// Shown buses by key (a ride's trip id, or a vehicle id).
  final Map<String, TrackedBus> buses = {};

  /// Newest position time among the shown buses.
  DateTime? lastFeed;
  Timer? _frame;
  bool _pushing = false;

  /// Shows exactly [next] (key -> bus and colour): new ones appear, known
  /// ones glide to their new position, missing ones go.
  void show(Map<String, ({Vehicle vehicle, String color})> next) {
    for (final MapEntry(:key, value: (:vehicle, :color)) in next.entries) {
      final existing = buses[key];
      if (existing == null) {
        buses[key] = TrackedBus(vehicle, color);
      } else if (existing.vehicle.timestamp != vehicle.timestamp || existing.color != color) {
        existing.update(vehicle, color);
      }
    }
    buses.removeWhere((k, _) => !next.containsKey(k));
    for (final MapEntry(:key, value: b) in buses.entries) {
      _resolveHeading(key, b);
    }
    lastFeed = buses.values.map((b) => b.vehicle.timestamp).fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
    _frame ??= Timer.periodic(frameInterval, (_) => _tick());
  }

  /// Works the headings out again (e.g. once a trip's path has loaded).
  void refreshHeadings() {
    if (buses.isEmpty) return;
    for (final MapEntry(:key, value: b) in buses.entries) {
      _resolveHeading(key, b);
    }
    _frame ??= Timer.periodic(frameInterval, (_) => _tick());
  }

  /// The feed's own bearing if it has one (Rome's doesn't), else along the
  /// path, else towards the stop it's going to, else the last move; else
  /// the one it had.
  void _resolveHeading(String key, TrackedBus b) {
    final v = b.vehicle;
    final path = pathOf?.call(key, v);
    b.heading = v.bearing ??
        (path == null ? null : headingOnPath(path, v.position, hint: b._moveHeading ?? b.heading)) ??
        _towardsNextStop(v) ??
        b._moveHeading ??
        b.heading;
  }

  /// Bearing to the stop it heads to; none when that's unknown or the bus
  /// is (almost) there, where the direction to it means nothing.
  double? _towardsNextStop(Vehicle v) {
    final id = v.stopId;
    final stop = id == null ? null : stopPosition?.call(id);
    if (stop == null || distanceMeters(v.position, stop) < 30) return null;
    return bearingDegrees(v.position, stop);
  }

  void clear() {
    _frame?.cancel();
    _frame = null;
    buses.clear();
    lastFeed = null;
    onFrame(_geojson());
  }

  Future<void> _tick() async {
    if (_pushing) return; // never queue frames behind a slow platform channel
    var moving = false;
    for (final b in buses.values) {
      moving |= b.tick(animation);
    }
    _pushing = true;
    await onFrame(_geojson());
    _pushing = false;
    if (!moving) {
      _frame?.cancel();
      _frame = null;
    }
  }

  Map<String, dynamic> _geojson() => {
        'type': 'FeatureCollection',
        'features': [
          for (final MapEntry(key: id, value: b) in buses.entries)
            {
              'type': 'Feature',
              'id': id,
              'geometry': {
                'type': 'Point',
                'coordinates': [b.drawn.longitude, b.drawn.latitude],
              },
              'properties': {
                'id': id,
                'line': lineName(b.vehicle.routeShortName ?? '', id: b.vehicle.backendTripId),
                'color': b.color,
                'text': readableOn(b.color),
                // Moving buses keep their line where badges would overlap.
                'moving': b.vehicle.started,
                'heading': ?b.heading,
              },
            },
        ],
      };
}
