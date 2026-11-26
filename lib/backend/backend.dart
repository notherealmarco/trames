import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:maplibre_gl/maplibre_gl.dart';

import 'cities.dart';
import 'models.dart';
import 'on_board.dart';

export 'cities.dart';
export 'models.dart';
export 'on_board.dart';
export 'place_finder.dart' show PlaceLocator;
export 'line_style.dart';
export 'tramite.dart';
export 'trip_numbers.dart';

/// The app talks to transit data only through these four capabilities.
/// Each can come from a different source; [TransitBackend] bundles one of each.
///
/// To self-host later, implement (or reuse) whichever pieces you replace and
/// add a factory in `config.dart`. A self-hosted MOTIS is just
/// `MotisClient(baseUrl: ...)`; an OpenTripPlanner server would need an
/// `OtpClient implements TripPlanner, StopBoards`.

abstract interface class TripPlanner {
  /// Itineraries departing from now on, in any order. [options] are hints;
  /// a backend ignores the ones it does not support.
  Future<List<Itinerary>> plan(LatLng from, LatLng to, {PlanOptions options = const PlanOptions()});
}

/// Optional for a [TripPlanner]: plans for someone already riding a vehicle
/// (see on_board.dart).
abstract interface class OnBoardPlanner {
  /// The run [backendTripId] with its latest live times (not cached).
  Future<TripInfo> liveTrip(String backendTripId);

  /// Itineraries starting on board [trip]: each begins with an
  /// [Leg.onBoard] ride to where you get off.
  Future<List<Itinerary>> planOnBoard(OnBoardTrip trip, LatLng to, {PlanOptions options = const PlanOptions()});
}

abstract interface class PlaceSearch {
  Future<List<Place>> search(String query, {LatLng? near});
}

abstract interface class StopBoards {
  /// Stops around [p], nearest first, with distance filled in.
  Future<List<Stop>> nearbyStops(LatLng p);

  /// Stops inside [area] (the visible map), nearest to [from] first, with
  /// distance from [from] filled in.
  Future<List<Stop>> stopsInArea(LatLngBounds area, {required LatLng from});

  /// One row per line + direction with upcoming departures.
  Future<List<BoardRow>> board(Stop stop);
}

abstract interface class TripDetails {
  /// Full run of a trip by the planner's trip id.
  Future<TripInfo> trip(String backendTripId);

  /// This planner's id for the run [tripId] stands for, when [tripId] comes
  /// from another version of the operator's timetable (e.g. from Tramite,
  /// whose timetable may be newer): the trip calling at [stopId] around
  /// [at], with the same service date, start time and [line]. Null if none.
  Future<String?> sameRun(String tripId, {required String stopId, required DateTime at, String? line});
}

/// Where and when a run can be found again (see [TripDetails.sameRun]).
typedef RunHint = ({String stopId, DateTime at});

abstract interface class WalkRouter {
  /// Street walking route from [from] to [to], or null if none.
  Future<WalkRoute?> walk(LatLng from, LatLng to);
}

/// Synchronous view over walks fetched so far (shared by the route search and
/// the trip view), plus batched fetching of the missing ones.
class WalkCache {
  WalkCache(this.router);
  final WalkRouter router;
  final _known = <String, WalkRoute?>{};

  /// The route if already fetched (null if unknown or none exists).
  WalkRoute? lookup(LatLng from, LatLng to) => _known[walkKey(from, to)];
  bool has(LatLng from, LatLng to) => _known.containsKey(walkKey(from, to));

  /// Forgets every walk (e.g. fetched at another walking pace).
  void clear() => _known.clear();

  /// Fetches up to [max] of [pairs] not known yet, in parallel.
  Future<void> fetch(Iterable<(LatLng, LatLng)> pairs, {int max = 6}) async {
    final todo = <String, (LatLng, LatLng)>{};
    for (final p in pairs) {
      final k = walkKey(p.$1, p.$2);
      if (!_known.containsKey(k) && todo.length < max) todo[k] = p;
    }
    await Future.wait(todo.entries.map((e) async {
      try {
        _known[e.key] = await router.walk(e.value.$1, e.value.$2);
      } catch (_) {
        // leave unknown: retried next time
      }
    }));
  }
}

abstract interface class TripPaths {
  /// The whole path of the vehicle running [leg]'s trip, first stop to last.
  Future<List<LatLng>> tripPath(Leg leg);
}

class TransitBackend {
  const TransitBackend({
    required this.name,
    required this.planner,
    required this.places,
    required this.stops,
    this.city,
    this.paths,
    this.trips,
    this.walks,
  });

  final String name;
  final TripPlanner planner;
  final PlaceSearch places;
  final StopBoards stops;

  /// The configured city this backend serves, or null (Transitous only).
  final CityConfig? city;

  /// Optional: lets the map show where a live vehicle still has to go.
  final TripPaths? paths;

  /// Optional: line view (a trip's route, stops, and the line's live buses).
  final TripDetails? trips;

  /// Optional: street walking routes, to offer walking instead of short rides.
  final WalkRouter? walks;

}

/// Shared helpers for implementations.
const kUserAgent = 'trames/0.1';

/// Request headers. Browsers forbid setting User-Agent (and log an error if
/// you try), so web builds send none.
Map<String, String> get kHeaders => kIsWeb ? const {} : const {'User-Agent': kUserAgent};

double distanceMeters(LatLng a, LatLng b) {
  const r = 6371000.0;
  final p1 = a.latitude * math.pi / 180, p2 = b.latitude * math.pi / 180;
  final dp = p2 - p1, dl = (b.longitude - a.longitude) * math.pi / 180;
  final h = math.sin(dp / 2) * math.sin(dp / 2) + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.asin(math.sqrt(h));
}

/// Where a bus is along its trip's [stops], from the stop the feed says it
/// is at or heading to: at stop [index] ([atStop]), or on the way from the
/// stop before to [index]. Null when the feed doesn't say or the stop isn't
/// on this trip.
///
/// The feed doesn't tell "at" from "heading to", so within [atStopMeters] of
/// the stop counts as at it. Before its first stop a bus is shown at it.
/// Without [bySequence] (a bus of another trip, whose sequence numbers are
/// its own trip's), only its stop places it.
({int index, bool atStop})? busPlaceOnTrip(List<TripStop> stops, Vehicle bus,
    {double atStopMeters = 40, bool bySequence = true}) {
  int? index;
  final seqIndex = bus.stopSequence == null || !bySequence ? null : bus.stopSequence! - 1;
  if (bus.stopId case final id?) {
    // A stop can be on a trip twice (loop lines): the one nearest the
    // sequence number, else the first.
    for (var i = 0; i < stops.length; i++) {
      if (stops[i].stopId != id) continue;
      if (index == null || (seqIndex != null && (i - seqIndex).abs() < (index - seqIndex).abs())) index = i;
    }
  }
  index ??= seqIndex != null && seqIndex >= 0 && seqIndex < stops.length ? seqIndex : null;
  if (index == null) return null;
  final atStop = index == 0 || distanceMeters(bus.position, stops[index].position) <= atStopMeters;
  return (index: index, atStop: atStop);
}

/// Groups departures at one stop into one row per line + direction.
List<BoardRow> groupDepartures(
  Stop stop,
  Iterable<({String line, String mode, String headsign, Departure departure})> items,
) {
  final rows = <String, BoardRow>{};
  for (final i in items) {
    final key = '${i.line}|${i.headsign}';
    (rows[key] ??= BoardRow(stop: stop, line: i.line, mode: i.mode, headsign: i.headsign, next: []))
        .next
        .add(i.departure);
  }
  for (final r in rows.values) {
    r.next.sort((a, b) => a.time.compareTo(b.time));
  }
  return rows.values.toList();
}

/// One row per bus (instead of per line), soonest first: for a single
/// stop's board, so every live bus shows as live.
List<BoardRow> boardPerDeparture(List<BoardRow> rows) => [
      for (final r in rows)
        for (final d in r.next) BoardRow(stop: r.stop, line: r.line, mode: r.mode, headsign: r.headsign, next: [d]),
    ]..sort((a, b) => a.next.first.time.compareTo(b.next.first.time));

/// Orders search results for someone at [reference]: everything within
/// [localKm] first, in the backend's own relevance order (name match), then
/// the rest nearest first (nearby towns before far-away cities). Stable, so
/// equally near results keep their relevance order.
List<Place> rankByProximity(List<Place> places, LatLng reference, {double localKm = 25}) {
  final local = <Place>[];
  final far = <(double, int, Place)>[];
  for (var i = 0; i < places.length; i++) {
    final p = places[i];
    // A suggestion not located yet: the distance its search gave, else
    // taken as local (the search was made around [reference]).
    final d = (p.needsLocating ? p.distanceHint ?? 0 : distanceMeters(reference, p.position)) / 1000;
    if (d <= localKm) {
      local.add(places[i]);
    } else {
      far.add((d, i, places[i]));
    }
  }
  far.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  return [...local, for (final f in far) f.$3];
}
