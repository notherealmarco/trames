import 'package:maplibre_gl/maplibre_gl.dart';

import 'line_style.dart';

/// Backend-neutral models. Every backend maps its own JSON into these.
///
/// Trip ids are always the *raw GTFS trip_id of the operator feed*
/// (e.g. Rome's `0#4103-14`), never a backend-specific wrapper, so data from
/// different sources (planner vs. vehicle GPS feed) can be joined.

enum PlaceKind { place, address, stop }

class Place {
  const Place({
    required this.name,
    required this.position,
    this.subtitle,
    this.isMyLocation = false,
    this.kind = PlaceKind.place,
    this.stopId,
    this.station = false,
    this.onBoard,
    this.placeId,
    this.distanceHint,
    this.credit,
  }) : located = true;

  /// A search suggestion whose position is not known yet: [placeId] is
  /// what [PlaceLocator.locate] asks for, and [position] only a stand-in
  /// (where the search was made) until then.
  const Place.unlocated({
    required String this.placeId,
    required this.name,
    required this.position,
    this.subtitle,
    this.kind = PlaceKind.place,
    this.distanceHint,
    this.credit,
  })  : located = false,
        isMyLocation = false,
        stopId = null,
        station = false,
        onBoard = null;

  final String name;
  final String? subtitle;
  final LatLng position;
  final bool isMyLocation;
  final PlaceKind kind;

  /// Backend stop id when [kind] is [PlaceKind.stop] (for its timetable).
  final String? stopId;

  /// A whole station (metro / rail) rather than one stop pole: its timetable
  /// covers all its platforms and both directions.
  final bool station;

  /// Set when this origin is a vehicle you are riding, not a place: trips
  /// start on board and say where to get off.
  final OnBoardRide? onBoard;

  /// The place search's id for it (kept once located: favourites match by it).
  final String? placeId;

  /// False for a search suggestion still to be located ([Place.unlocated]).
  final bool located;

  /// How far it is from where the search was made, when the search said
  /// (for ordering suggestions that have no position yet).
  final double? distanceHint;

  /// The data's source to credit next to it ("Google Maps"), when it must be.
  final String? credit;

  bool get needsLocating => !located;

  /// This place at [at], located.
  Place locatedAt(LatLng at) =>
      Place(name: name, subtitle: subtitle, position: at, kind: kind, placeId: placeId, credit: credit);
}

/// The vehicle run you are riding (see [Place.onBoard]).
class OnBoardRide {
  const OnBoardRide({
    required this.backendTripId,
    required this.tripId,
    required this.line,
    required this.mode,
    required this.headsign,
    this.liveTripId,
  });

  /// The planner's id for the run.
  final String backendTripId;

  /// The live service's own id for the run (the bus it was picked from),
  /// when it has one: where the bus is and its times come from there.
  final String? liveTripId;

  /// Raw GTFS trip_id (see top of file).
  final String tripId;
  final String line;
  final String mode;
  final String headsign;
}

/// When a journey is planned: [time] null means "leave now".
class PlanTime {
  const PlanTime({this.time, this.arriveBy = false});

  final DateTime? time;

  /// Whether [time] is an arrival deadline instead of a departure time.
  final bool arriveBy;

  /// A chosen time that is no longer ahead of [now] (to the minute): as if
  /// it had never been set.
  bool passed(DateTime now) {
    final t = time;
    return t != null && !t.isAfter(DateTime(now.year, now.month, now.day, now.hour, now.minute));
  }

  /// When you set off at the earliest: the chosen departure, else [now]
  /// (arriving by a time, you may leave any time from now).
  DateTime leaveFrom(DateTime now) {
    final t = time;
    return !arriveBy && t != null && t.isAfter(now) ? t : now;
  }
}

/// Knobs a planner may honour. Backends map these to their own parameters
/// and ignore what they cannot do.
class PlanOptions {
  const PlanOptions({
    this.searchWindowMinutes = 30,
    this.legAlternatives = 6,
    this.maxTransfers,
    this.maxWalkMinutes,
    this.extraTransferMinutes,
    this.time,
    this.arriveBy = false,
  });

  PlanOptions copyWith({DateTime? time, bool? arriveBy}) => PlanOptions(
        searchWindowMinutes: searchWindowMinutes,
        legAlternatives: legAlternatives,
        maxTransfers: maxTransfers,
        maxWalkMinutes: maxWalkMinutes,
        extraTransferMinutes: extraTransferMinutes,
        time: time,
        arriveBy: arriveBy ?? this.arriveBy,
      );

  /// Time around which the route is planned. Null means now.
  final DateTime? time;

  /// Whether [time] is an arrival deadline instead of a departure time.
  final bool arriveBy;

  /// How far after "now" departures are searched.
  final int searchWindowMinutes;

  /// Per transit leg, how many replacement connections to return.
  final int legAlternatives;
  final int? maxTransfers;

  /// Cap on the walk to the first stop and from the last stop.
  final int? maxWalkMinutes;

  /// Extra buffer reserved for every change.
  final int? extraTransferMinutes;
}

class Itinerary {
  Itinerary({
    required this.start,
    required this.end,
    required this.legs,
    required this.transfers,
    this.base,
    this.walkSlots = const {},
    this.walkOptions = const {},
    this.rideChoices,
    this.missedConnection = false,
    this.hiddenBecause,
  });

  /// Shown only under "show more": staying on one of this journey's buses
  /// gets you there about as soon with fewer changes (see checkStayingOn).
  /// Null for journeys listed normally.
  final StayOnReason? hiddenBecause;

  /// Same journey, listed under "show more" for [reason].
  Itinerary hiddenFor(StayOnReason reason) => _copy(hiddenBecause: reason);

  final DateTime start;
  final DateTime end;
  final List<Leg> legs;
  final int transfers;

  /// When some rides were replaced by walking (see walk rules): the planner's
  /// original itinerary, so the trip view can still offer those rides.
  final Itinerary? base;

  /// Rides of [base] (by order among its transit legs) walked by default.
  final Set<int> walkSlots;

  /// For a walk leg (by index in [legs]) that replaces a ride: the lines that
  /// could do that stretch instead (swipe options), e.g. ["3BUS"].
  final Map<int, List<String>> walkOptions;

  /// Which variant each ride slot of [base] uses (see TripVariants), so the
  /// trip view opens on the same buses; null = the defaults.
  final List<int>? rideChoices;

  /// The times shown can't really be made: by the live times a ride runs
  /// late (or has already gone by) and no bus makes the connection any
  /// more, or you can't reach the first stop in time ([lateForFirstRide]).
  final bool missedConnection;

  /// Same itinerary, flagged as missing a connection.
  Itinerary withMissedConnection() => _copy(missedConnection: true);

  /// Same journey with other [legs] (e.g. alternatives trimmed).
  Itinerary withLegs(List<Leg> legs) => _copy(legs: legs);

  Itinerary _copy({List<Leg>? legs, bool? missedConnection, StayOnReason? hiddenBecause}) => Itinerary(
        start: start,
        end: end,
        legs: legs ?? this.legs,
        transfers: transfers,
        base: base,
        walkSlots: walkSlots,
        walkOptions: walkOptions,
        rideChoices: rideChoices,
        missedConnection: missedConnection ?? this.missedConnection,
        hiddenBecause: hiddenBecause ?? this.hiddenBecause,
      );

  bool get walkOnly => transitLegs.isEmpty;

  /// You can't reach the first stop in time any more: to catch the first
  /// ride you should have left more than [slack] ago, and it hasn't left
  /// yet. (Never for the ride you're already on.)
  bool lateForFirstRide(DateTime now, {Duration slack = const Duration(minutes: 1)}) {
    final first = transitLegs.firstOrNull;
    if (first == null || first.onBoard) return false;
    final limit = now.subtract(slack);
    return start.isBefore(limit) && !first.start.isBefore(limit);
  }

  Duration get duration => end.difference(start);
  Iterable<Leg> get transitLegs => legs.where((l) => l.transit);
  bool get anyRealtime => transitLegs.any((l) => l.realtime);
  /// Delay of the final arrival: that of the last ride (walks just follow it).
  int? get arrivalDelaySeconds {
    final last = transitLegs.lastOrNull;
    return last?.arrivalDelaySeconds ?? last?.delaySeconds;
  }

  int get walkMinutes => legs.where((l) => !l.transit).fold(0, (m, l) => m + l.end.difference(l.start).inMinutes);

  /// Which line sequence this is ("211 › MEB"); used to group departures of the same route.
  String get signature => transitLegs.map((l) => l.routeShortName ?? l.mode).join(' › ');
}

/// Why a journey is under "show more": staying on its bus [line] (instead
/// of changing after it) arrives at [arrival], with [changesSaved] fewer
/// changes.
class StayOnReason {
  const StayOnReason({required this.line, required this.arrival, required this.changesSaved});
  final String line;
  final DateTime arrival;
  final int changesSaved;
}

/// Another connection that can replace a transit leg without breaking the
/// rest of the journey: the walk to its stop, the ride, the walk on to where
/// the journey continues (e.g. "or the 450 from the next stop").
class LegAlternative {
  LegAlternative(this.legs);

  /// Usually `[walk, ride, walk]`; the ride is the only transit leg.
  final List<Leg> legs;

  Leg get ride => legs.firstWhere((l) => l.transit);
  String get line => ride.routeShortName ?? ride.mode;

  /// [line] as shown (its friendly name).
  String get label => ride.label;

  /// Whether the ride can still be caught leaving [now] (walking to its stop
  /// first, a minute of slack). The planner also lists earlier trips that
  /// would have made the connection: buses that may have left already.
  bool reachableFrom(DateTime now) {
    final i = legs.indexWhere((l) => l.transit);
    final walk = legs.take(i).fold(Duration.zero, (d, l) => d + l.duration);
    return !ride.start.subtract(walk).isBefore(now.subtract(const Duration(minutes: 1)));
  }
}

class Leg {
  Leg({
    required this.mode,
    required this.transit,
    required this.start,
    required this.end,
    required this.fromName,
    required this.toName,
    required this.from,
    required this.to,
    required this.points,
    required this.distanceMeters,
    this.routeShortName,
    this.routeColor,
    this.routeTextColor,
    this.headsign,
    this.tripId,
    this.backendTripId,
    this.realtime = false,
    this.delaySeconds,
    this.arrivalDelaySeconds,
    this.intermediateStops = 0,
    this.via = const [],
    this.alternatives = const [],
    this.origin,
    this.fromStopId,
    this.toStopId,
    this.onBoard = false,
    this.plannedStart,
    this.plannedEnd,
  });

  /// WALK, BUS, TRAM, SUBWAY, RAIL, ...
  final String mode;
  final bool transit;
  final DateTime start;
  final DateTime end;
  final String fromName;
  final String toName;
  final LatLng from;
  final LatLng to;
  final List<LatLng> points;
  final double distanceMeters;
  final String? routeShortName;

  /// The line's colours as the planner says (GTFS hex), when it does; see
  /// [colors] for what is shown.
  final String? routeColor;
  final String? routeTextColor;
  final String? headsign;

  /// Raw GTFS trip_id (see top of file).
  final String? tripId;

  /// The planner's own id for this trip (opaque), to ask the same backend
  /// for more about it, e.g. its full path.
  final String? backendTripId;
  final bool realtime;

  /// What the ride is shown as: its line's friendly name, else its line,
  /// else its mode.
  String get label => routeShortName == null ? mode : lineName(routeShortName!, id: backendTripId);

  /// The ride's colours (see line_style.dart).
  LineColors get colors =>
      lineColors(mode: mode, line: routeShortName, color: routeColor, textColor: routeTextColor, id: backendTripId);
  /// Departure delay at the boarding stop (live minus scheduled).
  final int? delaySeconds;

  /// Arrival delay at the alighting stop.
  final int? arrivalDelaySeconds;
  final int intermediateStops;

  /// The stops the ride passes between [from] and [to] (when the planner
  /// says), shown along its line on the map.
  final List<TripStop> via;
  final List<LegAlternative> alternatives;

  /// Where the ride's trip starts (its terminus), when the planner says.
  final TripOrigin? origin;


  /// Backend ids of the stops where the ride starts and ends (transit legs).
  final String? fromStopId;
  final String? toStopId;

  /// The ride you are already on (see [OnBoardRide]): it starts where the
  /// vehicle is now, there's nothing to catch, and it can't be swapped.
  final bool onBoard;

  /// When the planner had this ride leave and arrive, once live times moved
  /// it (see [at]); null while [start] and [end] are still the planner's.
  final DateTime? plannedStart;
  final DateTime? plannedEnd;

  /// The planner's own times, live times aside.
  DateTime get planned => plannedStart ?? start;
  DateTime get plannedArrival => plannedEnd ?? end;

  /// The planner's timetable times (its own delay taken off).
  DateTime get scheduledStart => planned.subtract(Duration(seconds: delaySeconds ?? 0));
  DateTime get scheduledEnd => plannedArrival.subtract(Duration(seconds: arrivalDelaySeconds ?? delaySeconds ?? 0));

  Duration get duration => end.difference(start);

  /// Same leg moved in time (used to re-time walks when a ride is swapped).
  Leg movedTo(DateTime newStart) => _copy(start: newStart, end: end.add(newStart.difference(start)));

  /// This ride at its live times: leaving at [liveStart] (null: when the
  /// planner said) and arriving at [liveEnd] (null: as much later than
  /// planned as it leaves). Can be applied again and again: the planner's
  /// times are remembered.
  Leg at(DateTime? liveStart, [DateTime? liveEnd]) {
    final from = liveStart ?? planned;
    var to = liveEnd ?? plannedArrival.add(from.difference(planned));
    if (to.isBefore(from)) to = from;
    if (from == start && to == end) return this;
    return _copy(start: from, end: to, plannedStart: planned, plannedEnd: plannedArrival);
  }

  /// Same leg with a different set of alternatives.
  Leg withAlternatives(List<LegAlternative> alts) => _copy(alternatives: alts);

  Leg _copy({DateTime? start, DateTime? end, List<LegAlternative>? alternatives, DateTime? plannedStart, DateTime? plannedEnd}) {
    return Leg(
      mode: mode,
      transit: transit,
      start: start ?? this.start,
      end: end ?? this.end,
      fromName: fromName,
      toName: toName,
      from: from,
      to: to,
      points: points,
      distanceMeters: distanceMeters,
      routeShortName: routeShortName,
      routeColor: routeColor,
      routeTextColor: routeTextColor,
      headsign: headsign,
      tripId: tripId,
      backendTripId: backendTripId,
      realtime: realtime,
      delaySeconds: delaySeconds,
      arrivalDelaySeconds: arrivalDelaySeconds,
      intermediateStops: intermediateStops,
      via: via,
      alternatives: alternatives ?? this.alternatives,
      origin: origin,
      fromStopId: fromStopId,
      toStopId: toStopId,
      onBoard: onBoard,
      plannedStart: plannedStart ?? this.plannedStart,
      plannedEnd: plannedEnd ?? this.plannedEnd,
    );
  }
}

class Stop {
  Stop({
    required this.id,
    required this.name,
    required this.position,
    required this.distanceMeters,
    this.station = false,
    String? code,
  }) : code = code ?? stopCodeFromId(id);

  /// Backend stop id (opaque; only passed back to the same backend).
  final String id;

  /// Public stop number shown at the pole (e.g. "71502").
  final String code;
  final String name;
  final LatLng position;
  final int distanceMeters;

  /// A whole station (e.g. a metro station from search): its departures
  /// include all its platforms / same-name stops. Otherwise the board shows
  /// this exact stop only, i.e. one direction.
  final bool station;
}

/// Public code from a backend id when no code is given: the part after the
/// feed prefix ("it-Lazio-Rome_71502" -> "71502", "roma:71502" -> "71502").
String stopCodeFromId(String id) => id.split(RegExp(r'[_:]')).last;

class Departure {
  Departure({
    required this.time,
    required this.realtime,
    this.delaySeconds,
    this.tripId,
    this.backendTripId,
    this.origin,
    this.certainty,
    this.stopId,
    this.routeColor,
    this.routeTextColor,
  });
  final DateTime time;

  /// Its line's colours as the backend says (GTFS hex), when it does.
  final String? routeColor;
  final String? routeTextColor;

  /// Backend id of the stop it leaves from (a station board mixes several).
  final String? stopId;

  /// How sure it is, when the backend says (Tramite); else worked out from
  /// [realtime] and the live buses.
  final Certainty? certainty;


  /// Where this trip starts (its terminus), when the backend says.
  final TripOrigin? origin;

  /// Same departure at another time (an estimate, see [ReturnEstimate]).
  Departure at(DateTime t) => Departure(
      time: t,
      realtime: realtime,
      delaySeconds: delaySeconds,
      tripId: tripId,
      backendTripId: backendTripId,
      origin: origin,
      certainty: certainty,
      stopId: stopId,
      routeColor: routeColor,
      routeTextColor: routeTextColor);
  final bool realtime;
  final int? delaySeconds;
  final String? tripId;

  /// The planner's id for this trip, to ask for its route and stops.
  final String? backendTripId;
}

/// One line + direction at a stop, with its next departures.
class BoardRow {
  BoardRow({required this.stop, required this.line, required this.mode, required this.headsign, required this.next});
  final Stop stop;
  final String line;
  final String mode;
  final String headsign;
  final List<Departure> next;

  /// [line] as shown (its friendly name).
  String get label => lineName(line, id: stop.id);

  /// The line's colours (see line_style.dart).
  LineColors get colors => lineColors(
      mode: mode, line: line, color: next.firstOrNull?.routeColor, textColor: next.firstOrNull?.routeTextColor, id: stop.id);
}

class Vehicle {
  Vehicle({
    required this.id,
    required this.label,
    required this.tripId,
    required this.routeShortName,
    required this.position,
    required this.timestamp,
    this.bearing,
    this.directionId,
    this.stopSequence,
    this.backendTripId,
    this.stopId,
    this.mode = 'BUS',
  });

  final String id;
  final String label;

  /// BUS, TRAM, ... (see [modeOfRouteType]).
  final String mode;

  /// The trip in Transitous form (to load its route and stops), when known.
  final String? backendTripId;

  /// The stop it is at or heading to (backend id), when known.
  final String? stopId;

  /// GTFS-RT current_stop_sequence: the stop the bus is at or heading to
  /// (1 = the first stop, the terminus). Null when the feed doesn't say.
  final int? stopSequence;

  /// Whether the bus has left the first stop of its trip. Still at (or
  /// driving to) the terminus = not yet: its times are only a forecast.
  /// Unknown position in the trip counts as started.
  bool get started => stopSequence == null || stopSequence! > 1;

  /// Direction of the trip being run (GTFS direction_id).
  final int? directionId;

  /// Raw GTFS trip_id (see top of file).
  final String? tripId;
  final String? routeShortName;
  final LatLng position;
  final DateTime timestamp;
  final double? bearing;
}

/// How sure we are that a departure will actually come, least sure first
/// (so the lowest index of several is the weakest link):
///  * [scheduled]: timetable only, no bus in sight;
///  * [estimated]: timetable only, and the bus that should run it comes back
///    from the other direction too late: its time is our estimate;
///  * [returning]: timetable only, and a bus coming back from the other
///    direction should make it in time;
///  * [waiting]: live forecast, but its bus hasn't started the trip yet
///    (parked at the terminus, or no bus on it yet);
///  * [moving]: its bus is on the way.
enum Certainty { scheduled, estimated, returning, waiting, moving }

/// Where a trip starts: its first stop (the terminus).
class TripOrigin {
  const TripOrigin({required this.stopId, required this.position});
  final String stopId;
  final LatLng position;
}

/// A timetable-only trip that a bus coming back from the other direction
/// could run ([Certainty.returning]), or run late ([Certainty.estimated]:
/// [delay] after the timetable, at every stop).
class ReturnEstimate {
  const ReturnEstimate(this.certainty, {this.delay = Duration.zero});
  final Certainty certainty;
  final Duration delay;
}

/// How sure a time is without Tramite's word on it: a live forecast counts
/// as on its way (no way to tell), else what Tramite [returns] inferred for
/// the trip, else timetable.
Certainty certaintyOf({required bool realtime, required String? tripId, Map<String, ReturnEstimate>? returns}) {
  if (realtime) return Certainty.moving;
  return (tripId == null ? null : returns?[tripId])?.certainty ?? Certainty.scheduled;
}

/// A walking route between two points, from the planner's street routing.
class WalkRoute {
  WalkRoute({required this.duration, required this.distanceMeters, required this.points});
  final Duration duration;
  final double distanceMeters;
  final List<LatLng> points;
}

/// Cache key for a walk between two points (~1 m precision).
String walkKey(LatLng a, LatLng b) =>
    '${a.latitude.toStringAsFixed(5)},${a.longitude.toStringAsFixed(5)}>${b.latitude.toStringAsFixed(5)},${b.longitude.toStringAsFixed(5)}';

/// One stop of a trip, with its (live when available) time there.
class TripStop {
  TripStop({required this.name, required this.position, this.time, this.scheduled, this.stopId, this.live = false});
  final String name;
  final LatLng position;
  final DateTime? time;
  final DateTime? scheduled;
  final String? stopId;

  /// [time] is a live prediction (else the timetable).
  final bool live;

  int? get delaySeconds => time == null || scheduled == null ? null : time!.difference(scheduled!).inSeconds;

  /// Same stop, reached at [t] when its own time is earlier.
  TripStop notBefore(DateTime t) => time == null || !time!.isBefore(t)
      ? this
      : TripStop(name: name, position: position, time: t, scheduled: scheduled, stopId: stopId, live: live);
}

/// A whole vehicle run: its line, direction, path and every stop.
class TripInfo {
  TripInfo({
    required this.line,
    required this.mode,
    required this.headsign,
    required this.points,
    required this.stops,
    required this.realtime,
    this.directionId,
    this.routeColor,
    this.routeTextColor,
  });
  final String line;
  final String mode;

  /// Its line's colours as the backend says (GTFS hex), when it does.
  final String? routeColor;
  final String? routeTextColor;
  final String headsign;
  final List<LatLng> points;
  final List<TripStop> stops;
  final bool realtime;
  final int? directionId;
}

/// Encoded polyline (Google format). OTP uses precision 5, MOTIS 6.
List<LatLng> decodePolyline(String s, {int precision = 5}) {
  final factor = precision == 5 ? 1e5 : precision == 6 ? 1e6 : 1e7;
  final out = <LatLng>[];
  int i = 0, lat = 0, lng = 0;
  while (i < s.length) {
    for (var k = 0; k < 2; k++) {
      int shift = 0, result = 0, b;
      do {
        b = s.codeUnitAt(i++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      // Zigzag decode with arithmetic, not `~`: on the web Dart bitwise ops are
      // unsigned 32-bit, so `~x` would be a huge positive number there.
      final d = (result & 1) != 0 ? -(result >> 1) - 1 : (result >> 1);
      if (k == 0) {
        lat += d;
      } else {
        lng += d;
      }
    }
    out.add(LatLng(lat / factor, lng / factor));
  }
  return out;
}

/// Part of a vehicle's path between where it is now and [stop]: starts at
/// [vehicle], follows [path] and ends at the path point nearest [stop].
/// Empty when the vehicle is already at or past the stop.
List<LatLng> approachPath(List<LatLng> path, LatLng vehicle, LatLng stop) {
  if (path.length < 2) return const [];
  double d2(LatLng a, LatLng b) {
    final dy = a.latitude - b.latitude;
    final dx = (a.longitude - b.longitude) * 0.745; // cos(42°): Rome-ish
    return dx * dx + dy * dy;
  }

  int nearest(LatLng p, int end) {
    var best = 0;
    for (var i = 1; i < end; i++) {
      if (d2(path[i], p) < d2(path[best], p)) best = i;
    }
    return best;
  }

  final j = nearest(stop, path.length);
  // Search the vehicle only before the stop: on loop routes the path passes
  // near the same place twice.
  final i = nearest(vehicle, j + 1);
  if (i >= j) return const [];
  return [vehicle, ...path.sublist(i + 1, j + 1)];
}
