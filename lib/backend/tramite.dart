import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';

import 'backend.dart';

/// Tramite, our realtime service: fresh operator data, buses waiting at the
/// terminus, buses that vanish near it, inferred departures. Its ids are
/// Transitous's, each with its source's prefix (`it-Lazio-Rome_71527`), so
/// the app asks Tramite about exactly the stops, trips and lines it covers
/// and Transitous about the rest (see [covers]).
///
/// Live data comes through one subscription stream ([LiveConnection]); this
/// class holds the plain requests and the JSON parsing.
class TramiteClient {
  TramiteClient({required this.baseUrl, http.Client? client}) : _client = client ?? http.Client();

  /// e.g. https://tramite.realac.ci
  String baseUrl;

  /// Talk to another Tramite server from now on (settings): what it covers
  /// is asked again.
  void switchTo(String url) {
    if (url == baseUrl) return;
    baseUrl = url;
    _prefixes = const [];
    _coverageAt = null;
    loadCoverage();
  }

  /// Whether [url] answers like a Tramite server.
  Future<bool> checkServer(String url) async {
    try {
      final res = await _client.get(Uri.parse('$url/v1/sources'), headers: kHeaders).timeout(const Duration(seconds: 10));
      return res.statusCode == 200 && res.body.trimLeft().startsWith('[');
    } catch (_) {
      return false;
    }
  }
  final http.Client _client;

  Uri uri(String path, [Map<String, dynamic>? query]) => Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Future<dynamic> _get(String path) async {
    final res = await _client.get(uri(path), headers: kHeaders).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw TramiteException(res.statusCode, utf8.decode(res.bodyBytes));
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  // ---- place search ----

  /// Suggestions for [query] from Tramite's place search, made around
  /// [near]; [session] groups one search's requests up to the place picked
  /// ([placeLocation]). Throws [TramiteException]: 501 when this server has
  /// no place search, 429/503 with [TramiteException.retryAfter].
  Future<({List<Place> places, String? attribution})> placeSuggestions(String query,
      {required LatLng near, String? lang, String? session}) async {
    final d = await _placesGet('/v1/places/autocomplete', {
      'q': query,
      'near': '${near.latitude},${near.longitude}',
      'lang': ?lang,
      'session': ?session,
    }) as Map<String, dynamic>;
    final attribution = d['attribution'] as String?;
    return (
      attribution: attribution,
      places: [
        for (final r in (d['results'] as List).cast<Map<String, dynamic>>())
          Place.unlocated(
            placeId: r['id'] as String,
            name: r['name'] as String,
            subtitle: switch (r['subtitle']) { final String s when s.isNotEmpty => s, _ => null },
            position: near,
            kind: r['kind'] == 'address' ? PlaceKind.address : PlaceKind.place,
            distanceHint: (r['distanceMeters'] as num?)?.toDouble(),
            credit: attribution,
          ),
      ],
    );
  }

  /// Where the suggestion [id] is; with its search's [session] (ends it).
  Future<LatLng> placeLocation(String id, {String? lang, String? session}) async {
    final d = await _placesGet('/v1/places/${Uri.encodeComponent(id).replaceAll('%3A', ':')}', {'lang': ?lang, 'session': ?session})
        as Map<String, dynamic>;
    return LatLng((d['lat'] as num).toDouble(), (d['lon'] as num).toDouble());
  }

  /// Like [_get], quicker to give up (search falls back on another source),
  /// and with the server's Retry-After.
  Future<dynamic> _placesGet(String path, Map<String, String> query) async {
    final res = await _client.get(uri(path, query), headers: kHeaders).timeout(const Duration(seconds: 6));
    if (res.statusCode != 200) {
      final secs = int.tryParse(res.headers['retry-after'] ?? '');
      throw TramiteException(res.statusCode, utf8.decode(res.bodyBytes),
          retryAfter: secs == null ? null : Duration(seconds: secs));
    }
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  /// Adds and removes topics of the open stream [streamId].
  Future<void> updateTopics(String streamId, {Iterable<String> add = const [], Iterable<String> remove = const []}) async {
    final res = await _client
        .post(uri('/v1/stream/$streamId/topics'),
            headers: {...kHeaders, 'Content-Type': 'application/json'},
            body: jsonEncode({'add': add.toList(), 'remove': remove.toList()}))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 204) throw TramiteException(res.statusCode, utf8.decode(res.bodyBytes));
  }

  // ---- coverage ----

  List<String> _prefixes = const [];
  DateTime? _coverageAt;
  Future<void>? _loading;

  /// Id prefixes of the sources Tramite serves, e.g. `it-Lazio-Rome`.
  List<String> get prefixes => _prefixes;

  /// Asks Tramite what it covers (once, again after a failure). Until it
  /// answers, nothing counts as covered and everything goes to Transitous.
  Future<void> loadCoverage() {
    final at = _coverageAt;
    if (_prefixes.isNotEmpty || (at != null && DateTime.now().difference(at) < const Duration(seconds: 30))) {
      return Future.value();
    }
    return _loading ??= () async {
      try {
        final list = await _get('/v1/sources') as List;
        final sources = list.cast<Map<String, dynamic>>();
        _prefixes = [for (final s in sources) ?s['idPrefix'] as String?];
        lineOverrides.set({
          for (final s in sources)
            if (s['idPrefix'] case final String p)
              p: [for (final o in (s['routes'] as List? ?? const []).cast<Map<String, dynamic>>()) RouteOverride.fromJson(o)],
        });
      } catch (_) {
        // unreachable: Transitous only, retried later
      } finally {
        _coverageAt = DateTime.now();
        _loading = null;
      }
    }();
  }

  /// The source prefix of a stop, line or trip id when Tramite covers it.
  /// Trip ids are `<date>_<HH:MM>_<prefix>_<trip>`.
  String? prefixOf(String? id) {
    if (id == null) return null;
    final trip = RegExp(r'^\d{8}_\d+:\d{2}_(.*)$').firstMatch(id);
    final rest = trip?.group(1) ?? id;
    String? best;
    for (final p in _prefixes) {
      if (rest.startsWith('${p}_') && (best == null || p.length > best.length)) best = p;
    }
    return best;
  }

  bool covers(String? id) => prefixOf(id) != null;

  // ---- topics ----

  /// A stop's departures; with [tripId], that trip's row at the stop only.
  /// [lineId] (the trip's line) lets Tramite match a trip id of another
  /// timetable version (Transitous may lag a feed that renumbers its trips).
  static String departuresTopic(String stopId, {String? tripId, String? lineId}) => tripId == null
      ? 'departures=$stopId'
      : 'departures=$stopId,trip=$tripId${lineId == null ? '' : ',line=$lineId'}';
  static String lineTopic(String lineId) => 'line=$lineId';

  /// A whole trip: its bus and its times at every stop. [lineId] and
  /// [stopId] (a stop it calls at) let Tramite match a trip id of another
  /// timetable version.
  static String tripTopic(String tripId, {String? lineId, String? stopId}) =>
      'trip=$tripId${lineId == null ? '' : ',line=$lineId'}${stopId == null ? '' : ',stop=$stopId'}';
  static String bboxTopic(LatLngBounds b) => 'bbox=${[
        b.southwest.latitude,
        b.southwest.longitude,
        b.northeast.latitude,
        b.northeast.longitude,
      ].map((x) => x.toStringAsFixed(5)).join(',')}';

  /// A line as Tramite names it: its operator's prefix and the number
  /// passengers see ("it-Lazio-Rome_85").
  static String lineId(String prefix, String number) => '${prefix}_$number';

  // ---- one-shot requests ----

  /// Live buses of a line right now (line search, the line view's directions).
  Future<List<({Vehicle vehicle, String? color})>> lineVehicles(String lineId) async {
    final list = await _get('/v1/lines/${Uri.encodeComponent(lineId)}/vehicles') as List;
    return [for (final j in list.cast<Map<String, dynamic>>()) parseVehicle(j)];
  }

  // ---- parsing ----

  static DateTime _time(String s) => DateTime.parse(s).toLocal();

  /// What passengers call a ride (a stop time, trip or vehicle): its line,
  /// with its trip number where the operator shows it (see rideLabel).
  static String? _line(Map<String, dynamic> j) {
    final line = j['routeShortName'] as String?;
    return line == null ? null : rideLabel(line, j['tripShortName'] as String?, j['tripId'] as String?);
  }

  /// A Tramite vehicle as the app's [Vehicle], with its line colour
  /// ("#RRGGBB", see line_style.dart).
  static ({Vehicle vehicle, String? color}) parseVehicle(Map<String, dynamic> j) {
    final mode = modeOfRouteType(j['routeType'] as int?);
    final line = j['routeShortName'] as String?;
    return (
      vehicle: Vehicle(
        id: j['id'] as String,
        label: j['id'] as String,
        tripId: j['gtfsTripId'] as String?,
        backendTripId: j['tripId'] as String?,
        routeShortName: _line(j),
        position: LatLng((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble()),
        timestamp: _time(j['timestamp'] as String),
        bearing: (j['bearing'] as num?)?.toDouble(),
        directionId: j['directionId'] as int?,
        stopSequence: j['currentStopSequence'] as int?,
        stopId: j['stopId'] as String?,
        mode: mode,
      ),
      color: lineColors(
              mode: mode,
              line: line,
              color: j['routeColor'] as String?,
              textColor: j['routeTextColor'] as String?,
              id: j['tripId'] as String? ?? j['routeId'] as String?)
          .color,
    );
  }

  static List<({Vehicle vehicle, String? color})> parseVehicles(Object? data) =>
      [for (final j in (data as List? ?? const []).cast<Map<String, dynamic>>()) parseVehicle(j)];

  /// A departures topic or endpoint's data as board rows for [stop].
  static List<BoardRow> parseBoard(Object? data, Stop stop) =>
      groupDepartures(stop, [for (final r in parseRows(data)) if (!r.cancelled) r.item]);

  /// Each stop time of a departures answer: as a board item, plus what a
  /// followed ride needs (where its bus is).
  static List<TramiteRow> parseRows(Object? data) => [
        for (final s in ((data as Map<String, dynamic>?)?['stopTimes'] as List? ?? const []).cast<Map<String, dynamic>>())
          _row(s),
      ];

  static TramiteRow _row(Map<String, dynamic> s) {
    final time = _time(s['departure'] as String);
    final sched = _time(s['scheduledDeparture'] as String);
    final line = _line(s) ?? '?';
    final from = s['tripFrom'] as Map<String, dynamic>?;
    final v = s['vehicle'] as Map<String, dynamic>?;
    final departure = Departure(
      time: time,
      realtime: s['realTime'] as bool? ?? false,
      delaySeconds: time.difference(sched).inSeconds,
      tripId: s['gtfsTripId'] as String?,
      backendTripId: s['tripId'] as String?,
      stopId: s['stopId'] as String?,
      origin: from == null
          ? null
          : TripOrigin(
              stopId: from['stopId'] as String,
              position: LatLng((from['lat'] as num).toDouble(), (from['lon'] as num).toDouble())),
      certainty: certaintyOf(s, time.difference(sched)),
      routeColor: s['routeColor'] as String?,
      routeTextColor: s['routeTextColor'] as String?,
    );
    Vehicle? bus;
    if (v != null && v['lat'] != null && v['timestamp'] != null) {
      bus = Vehicle(
        id: v['id'] as String,
        label: v['id'] as String,
        tripId: s['gtfsTripId'] as String?,
        backendTripId: s['tripId'] as String?,
        routeShortName: line,
        position: LatLng((v['lat'] as num).toDouble(), (v['lon'] as num).toDouble()),
        timestamp: _time(v['timestamp'] as String),
        bearing: (v['bearing'] as num?)?.toDouble(),
        directionId: s['directionId'] as int?,
        stopSequence: v['currentStopSequence'] as int?,
        mode: modeOfRouteType(s['routeType'] as int?),
      );
    }
    return TramiteRow(
      item: (line: line, mode: modeOfRouteType(s['routeType'] as int?), headsign: s['headsign'] as String? ?? '', departure: departure),
      scheduled: sched,
      inferred: s['departureTimestampReason'] == 'INFERRED',
      cancelled: s['cancelled'] == true,
      bus: bus,
    );
  }

  /// A trip topic or endpoint's data; null when it isn't a trip.
  static TramiteTrip? parseTrip(Object? data) {
    if (data is! Map<String, dynamic> || data['stopTimes'] is! List) return null;
    final v = data['vehicle'] as Map<String, dynamic>?;
    final seq = v?['currentStopSequence'] as int?;
    final stops = [
      for (final s in (data['stopTimes'] as List).cast<Map<String, dynamic>>())
        TramiteTripStop(
          stopId: s['stopId'] as String,
          name: s['name'] as String? ?? '',
          position: LatLng((s['lat'] as num).toDouble(), (s['lon'] as num).toDouble()),
          sequence: s['stopSequence'] as int,
          scheduledArrival: _time(s['scheduledArrival'] as String),
          arrival: _time(s['arrival'] as String),
          scheduledDeparture: _time(s['scheduledDeparture'] as String),
          departure: _time(s['departure'] as String),
          realtime: s['realTime'] as bool? ?? false,
          inferred: s['departureTimestampReason'] == 'INFERRED',
          cancelled: s['cancelled'] == true,
        ),
    ];
    Vehicle? bus;
    if (v != null && v['lat'] != null && v['timestamp'] != null) {
      bus = Vehicle(
        id: v['id'] as String,
        label: v['id'] as String,
        tripId: data['gtfsTripId'] as String?,
        backendTripId: data['tripId'] as String?,
        routeShortName: _line(data),
        position: LatLng((v['lat'] as num).toDouble(), (v['lon'] as num).toDouble()),
        timestamp: _time(v['timestamp'] as String),
        bearing: (v['bearing'] as num?)?.toDouble(),
        directionId: data['directionId'] as int?,
        stopSequence: seq,
        stopId: stops.where((s) => s.sequence == seq).firstOrNull?.stopId,
      );
    }
    return TramiteTrip(
      tripId: data['gtfsTripId'] as String?,
      backendTripId: data['tripId'] as String?,
      line: _line(data) ?? '?',
      cancelled: data['cancelled'] == true,
      stops: stops,
      bus: bus,
      busSequence: seq,
      started: v?['started'] as bool?,
    );
  }

  /// How sure a Tramite stop time is: inferred (on time or late), live with
  /// its bus not yet started (or no bus seen) or on its way, timetable.
  static Certainty certaintyOf(Map<String, dynamic> s, Duration delay) {
    if (s['departureTimestampReason'] == 'INFERRED') {
      return delay > Duration.zero ? Certainty.estimated : Certainty.returning;
    }
    if (s['realTime'] != true) return Certainty.scheduled;
    final v = s['vehicle'] as Map<String, dynamic>?;
    return v?['started'] == true ? Certainty.moving : Certainty.waiting;
  }
}

/// One stop time from Tramite.
class TramiteRow {
  TramiteRow({required this.item, required this.scheduled, required this.inferred, required this.cancelled, this.bus});
  final ({String line, String mode, String headsign, Departure departure}) item;
  final DateTime scheduled;

  /// No forecast, but a known bus should run it ([Departure.time] is when).
  final bool inferred;
  final bool cancelled;

  /// The bus on this trip, with its position (live buses only).
  final Vehicle? bus;

  Departure get departure => item.departure;
}

class TramiteException implements Exception {
  TramiteException(this.status, this.body, {this.retryAfter});
  final int status;
  final String body;

  /// When to ask again (Retry-After), on 429 and 503.
  final Duration? retryAfter;
  @override
  String toString() => 'Tramite $status: $body';
}

/// One stop of a [TramiteTrip], with the trip's times there.
class TramiteTripStop {
  TramiteTripStop({
    required this.stopId,
    required this.name,
    required this.position,
    required this.sequence,
    required this.scheduledArrival,
    required this.arrival,
    required this.scheduledDeparture,
    required this.departure,
    required this.realtime,
    required this.inferred,
    required this.cancelled,
  });
  final String stopId;
  final String name;
  final LatLng position;

  /// The stop's place in the trip (GTFS stop_sequence).
  final int sequence;
  final DateTime scheduledArrival;
  final DateTime arrival;
  final DateTime scheduledDeparture;
  final DateTime departure;

  /// [arrival] and [departure] are a live forecast.
  final bool realtime;

  /// No forecast, but a known bus should run the trip (its times are when).
  final bool inferred;

  /// The trip skips this stop.
  final bool cancelled;

  /// Its times can be believed: within 12 hours of the timetable. Further
  /// is a feed error (Rome's has had times on the wrong day), not a delay.
  bool get plausible =>
      arrival.difference(scheduledArrival).abs() <= const Duration(hours: 12) &&
      departure.difference(scheduledDeparture).abs() <= const Duration(hours: 12);
}

/// A whole trip from Tramite: its bus and its times at every stop.
class TramiteTrip {
  TramiteTrip({
    required this.tripId,
    required this.backendTripId,
    required this.line,
    required this.cancelled,
    required this.stops,
    this.bus,
    this.busSequence,
    this.started,
  });

  /// Raw GTFS trip_id, and the id in Transitous form.
  final String? tripId;
  final String? backendTripId;
  final String line;
  final bool cancelled;

  /// Every stop in order (a stop on the trip twice is here twice).
  final List<TramiteTripStop> stops;

  /// The bus on this trip, with its position (live buses only).
  final Vehicle? bus;

  /// The stop the bus is at or heading to ([TramiteTripStop.sequence]).
  final int? busSequence;

  /// Whether the bus has left the first stop; null without a bus on it.
  final bool? started;

  /// The bus has already gone by [stop] (it is heading to a later one).
  bool passed(TramiteTripStop stop) => busSequence != null && busSequence! > stop.sequence;

  /// Index of the visit of [stopId] whose timetable time ([arrival]: its
  /// arrival, else its departure) is nearest [scheduled], from [from] on;
  /// null when the trip doesn't call there.
  int? visit(String? stopId, DateTime scheduled, {int from = 0, bool arrival = false}) {
    int? best;
    Duration? bestGap;
    for (var i = from; i < stops.length; i++) {
      if (stops[i].stopId != stopId) continue;
      final gap = (arrival ? stops[i].scheduledArrival : stops[i].scheduledDeparture).difference(scheduled).abs();
      if (bestGap == null || gap < bestGap) {
        best = i;
        bestGap = gap;
      }
    }
    return best;
  }

  /// How sure the trip's times are: inferred (on time or late), live with
  /// its bus not yet started (or no bus seen) or on its way, timetable.
  Certainty get certainty {
    final guess = stops.where((s) => s.inferred).firstOrNull;
    if (guess != null) {
      return guess.departure.isAfter(guess.scheduledDeparture) ? Certainty.estimated : Certainty.returning;
    }
    if (!stops.any((s) => s.realtime)) return Certainty.scheduled;
    return started == true ? Certainty.moving : Certainty.waiting;
  }
}
