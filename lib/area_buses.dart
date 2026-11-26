import 'dart:math' as math;

import 'package:maplibre_gl/maplibre_gl.dart';

import 'backend/backend.dart';
import 'backend/live_connection.dart';
import 'live_buses.dart';

/// Every live bus around the visible map, for browsing (no journey or line
/// open). Follows one area topic, a bit larger than the view; panning out of
/// it (or zooming far out of or into it) replaces it with the new area.
class AreaBuses {
  AreaBuses({required this.connection, required this.tracker, this.defaultColor = kBusColor});

  final LiveConnection connection;

  /// Draws the buses (its own map source).
  final LiveBusTracker tracker;
  String defaultColor;

  /// Below this zoom the buses would be too many and too small: none. Two
  /// levels below the stops (kMinStopsZoom): buses stay a while longer when
  /// zooming out.
  static const minZoom = 12.0;

  /// The followed area extends this fraction of the view's size on each side.
  static const margin = 0.5;

  LatLngBounds? _area;
  LiveSubscription? _sub;

  int get count => tracker.buses.length;

  /// Follows the buses around [view] (the visible map) at [zoom]; too far
  /// out, or Tramite covering nothing: none.
  void show(LatLngBounds view, double zoom) {
    if (zoom < minZoom || connection.client.prefixes.isEmpty) {
      hide();
      return;
    }
    final area = _area;
    if (area != null && _contains(area, view) && _span(area) <= 9 * _span(view)) return;
    final next = _expand(view, margin);
    final old = _sub;
    _area = next;
    _sub = connection.subscribe(TramiteClient.bboxTopic(next), (data) {
      tracker.show({
        for (final (:vehicle, :color) in TramiteClient.parseVehicles(data)) vehicle.id: (vehicle: vehicle, color: color ?? defaultColor),
      });
    });
    old?.cancel(); // after subscribing: both changes go out together
  }

  /// Stops following and clears the buses.
  void hide() {
    _sub?.cancel();
    _sub = null;
    _area = null;
    tracker.clear();
  }

  static bool _contains(LatLngBounds outer, LatLngBounds inner) =>
      inner.southwest.latitude >= outer.southwest.latitude &&
      inner.southwest.longitude >= outer.southwest.longitude &&
      inner.northeast.latitude <= outer.northeast.latitude &&
      inner.northeast.longitude <= outer.northeast.longitude;

  static double _span(LatLngBounds b) =>
      (b.northeast.latitude - b.southwest.latitude) * (b.northeast.longitude - b.southwest.longitude);

  static LatLngBounds _expand(LatLngBounds b, double f) {
    final dLat = (b.northeast.latitude - b.southwest.latitude) * f;
    final dLon = (b.northeast.longitude - b.southwest.longitude) * f;
    return LatLngBounds(
      southwest: LatLng(math.max(-90, b.southwest.latitude - dLat), b.southwest.longitude - dLon),
      northeast: LatLng(math.min(90, b.northeast.latitude + dLat), b.northeast.longitude + dLon),
    );
  }
}
