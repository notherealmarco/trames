import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';

import 'backend.dart';

/// MOTIS 2 API client (v6 routing endpoints, v1 geocoder).
///
/// Transitous (https://transitous.org) is a public MOTIS instance; a
/// self-hosted MOTIS uses this same class with a different [baseUrl].
class MotisClient implements TripPlanner, OnBoardPlanner, PlaceSearch, StopBoards, TripPaths, TripDetails, WalkRouter {
  MotisClient({
    this.baseUrl = 'https://api.transitous.org',
    this.language = 'it',
    this.searchRadiusMeters = 500,
    this.homeFeedId,
    this._walkingSpeedKmh,
    http.Client? client,
  }) : _client = client ?? http.Client();

  String baseUrl;

  /// Talk to another MOTIS server from now on (settings). Everything cached
  /// from the old one is dropped: its ids may mean nothing to the new one.
  void switchTo(String url) {
    if (url == baseUrl) return;
    baseUrl = url;
    _trips.clear();
    _walks.clear();
    _feeds.clear();
    _nearRide.clear();
  }

  /// Whether [url] answers like a MOTIS server.
  Future<bool> checkServer(String url) async {
    try {
      final res = await _client.get(Uri.parse('$url/api/v1/health'), headers: kHeaders).timeout(const Duration(seconds: 10));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// MOTIS feed id of the active city (see CityConfig), to look up a typed
  /// stop number there; null outside a configured city.
  String? homeFeedId;

  /// Walking pace sent to MOTIS (null = its default, ~4.3 km/h). Changing
  /// it drops the walks fetched at the old pace.
  double? get walkingSpeedKmh => _walkingSpeedKmh;
  double? _walkingSpeedKmh;
  set walkingSpeedKmh(double? kmh) {
    if (kmh == _walkingSpeedKmh) return;
    _walkingSpeedKmh = kmh;
    _walks.clear();
  }

  /// `pedestrianSpeed` in m/s, for every request that routes on foot.
  Map<String, String> get _pace =>
      walkingSpeedKmh == null ? const {} : {'pedestrianSpeed': (walkingSpeedKmh! / 3.6).toStringAsFixed(3)};
  final String language;
  final int searchRadiusMeters;
  final http.Client _client;

  Future<dynamic> _get(String path, Map<String, String> query) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    final res = await _client.get(uri, headers: kHeaders).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw Exception('MOTIS ${res.statusCode}: ${res.body}');
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  Future<dynamic> _post(String path, Map<String, String> query, Object body) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    final res = await _client
        .post(uri, headers: {...kHeaders, 'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw Exception('MOTIS ${res.statusCode}: ${res.body}');
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  static String _ll(LatLng p) => '${p.latitude},${p.longitude}';

  /// A time for MOTIS: UTC, whole seconds. With microseconds (as Dart
  /// writes DateTime.now()) Transitous misreads it, days off.
  static String motisTime(DateTime t) {
    final u = t.toUtc();
    return DateTime.utc(u.year, u.month, u.day, u.hour, u.minute, u.second).toIso8601String().replaceFirst('.000Z', 'Z');
  }
  static DateTime _time(String s) => DateTime.parse(s).toLocal();
  static LatLng _pos(Map<String, dynamic> j) => LatLng((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble());

  /// The trip's first stop (`tripFrom` on legs and stop times).
  static TripOrigin? _origin(Object? j) => switch (j) {
        {'stopId': final String id, 'lat': num _, 'lon': num _} => TripOrigin(stopId: id, position: _pos(j as Map<String, dynamic>)),
        _ => null,
      };

  /// MOTIS trip ids look like `20261112_04:45_it-Lazio-Rome_0#1054-2`
  /// (service date, departure, feed id, GTFS trip_id). Keep only the GTFS id.
  static final _tripIdPattern = RegExp(r'^\d{8}_\d+:\d{2}_[^_]+_(.+)$');
  static String? rawTripId(String? motisId) {
    if (motisId == null) return null;
    return _tripIdPattern.firstMatch(motisId)?.group(1) ?? motisId;
  }

  // ---- TripPlanner ----

  @override
  Future<List<Itinerary>> plan(LatLng from, LatLng to, {PlanOptions options = const PlanOptions()}) async {
    final o = options;
    final d = await _get('/api/v6/plan', {
      'fromPlace': _ll(from),
      'toPlace': _ll(to),
      'numItineraries': '8',
      'detailedLegs': 'true',
      'searchWindow': '${o.searchWindowMinutes * 60}',
      if (o.time != null) 'time': motisTime(o.time!),
      'arriveBy': '${o.arriveBy}',
      ..._pace,
      // MOTIS keeps only options better on departure, arrival or changes,
      // so a direct bus that ties a walk-heavy metro option is dropped
      // (e.g. the 88 Verano -> Conca d'Oro). Ask for those "overtaken"
      // direct connections too, all of them: the app ranks and filters.
      'slowDirect': 'true',
      'fastestSlowDirectFactor': '0.5', // < 1: return every slow direct one
      if (o.legAlternatives > 0) 'numLegAlternatives': '${o.legAlternatives}',
      if (o.maxTransfers != null) 'maxTransfers': '${o.maxTransfers}',
      if (o.extraTransferMinutes != null) 'additionalTransferTime': '${o.extraTransferMinutes}',
      if (o.maxWalkMinutes != null) ...{
        'maxPreTransitTime': '${o.maxWalkMinutes! * 60}',
        'maxPostTransitTime': '${o.maxWalkMinutes! * 60}',
      },
    }) as Map<String, dynamic>;
    return [
      for (final it in d['itineraries'] as List) _itinerary(it as Map<String, dynamic>),
      // Walking the whole way (offered by the planner when short enough).
      for (final it in (d['direct'] as List? ?? const []))
        if (((it as Map)['legs'] as List).every((l) => (l as Map)['mode'] == 'WALK')) _itinerary(it as Map<String, dynamic>),
    ];
  }

  Itinerary _itinerary(Map<String, dynamic> it) => Itinerary(
        start: _time(it['startTime']),
        end: _time(it['endTime']),
        transfers: it['transfers'] as int? ?? 0,
        legs: [
          for (final l in it['legs'] as List)
            if (!_sameStopWalk(l as Map<String, dynamic>)) _leg(l),
        ],
      );

  // ---- OnBoardPlanner ----

  @override
  Future<TripInfo> liveTrip(String backendTripId) async {
    final t = await _fetchTrip(backendTripId);
    _trips[backendTripId] = Future.value(t); // the line view gets the fresh times too
    return t;
  }

  /// Stops near the ones a ride still calls at, per ride and next stop (the
  /// profiles of one search ask at once).
  final _nearRide = <String, Future<List<Stop>>>{};

  Future<List<Stop>> _stopsNear(OnBoardTrip trip) {
    final key = '${trip.ride.backendTripId}@${trip.remaining.first.stopId}';
    if (_nearRide.length > 20) _nearRide.clear();
    return _nearRide[key] ??= () async {
      final pts = trip.remaining.map((s) => s.position);
      final dLat = kOnBoardWalkMeters / 111000, dLon = dLat / 0.75;
      try {
        return await stopsInArea(
          LatLngBounds(
            southwest: LatLng(pts.map((p) => p.latitude).reduce(math.min) - dLat,
                pts.map((p) => p.longitude).reduce(math.min) - dLon),
            northeast: LatLng(pts.map((p) => p.latitude).reduce(math.max) + dLat,
                pts.map((p) => p.longitude).reduce(math.max) + dLon),
          ),
          from: trip.position,
        );
      } catch (_) {
        return const <Stop>[]; // the vehicle's own stops still work
      }
    }();
  }

  /// MOTIS can't start on a vehicle: it gets the stops still ahead (and
  /// those a short walk from them) as client offsets (see on_board.dart).
  @override
  Future<List<Itinerary>> planOnBoard(OnBoardTrip trip, LatLng to, {PlanOptions options = const PlanOptions()}) async {
    if (trip.remaining.isEmpty) return const [];
    final o = options;
    final offsets = onBoardOffsets(trip, await _stopsNear(trip),
        walkSpeed: (walkingSpeedKmh ?? 4.3) / 3.6);
    final d = await _post('/api/v6/plan', {
      // Only draws the planner's fake first leg (replaced afterwards).
      'fromPlace': _ll(trip.position),
      'toPlace': _ll(to),
      'time': motisTime(trip.now),
      // You can't leave later: earliest arrival from now, not a time window.
      'timetableView': 'false',
      // No walking (or cycling) from where the vehicle is.
      'directModes': '',
      'numItineraries': '8',
      'detailedLegs': 'true',
      ..._pace,
      if (o.legAlternatives > 0) 'numLegAlternatives': '${o.legAlternatives}',
      // The ride you're on is invisible to MOTIS: one change fewer for it.
      if (o.maxTransfers != null) 'maxTransfers': '${math.max(0, o.maxTransfers! - 1)}',
      if (o.extraTransferMinutes != null) 'additionalTransferTime': '${o.extraTransferMinutes}',
      if (o.maxWalkMinutes != null) 'maxPostTransitTime': '${o.maxWalkMinutes! * 60}',
    }, {
      'fromOffsets': [
        for (final off in offsets.values) {'stopId': off.stopId, 'duration': math.max(0, off.offset.inSeconds)},
      ],
    }) as Map<String, dynamic>;
    return [
      for (final it in d['itineraries'] as List) ?fromOnBoardPlan(_itinerary(it as Map<String, dynamic>), trip, offsets),
    ];
  }

  // ---- WalkRouter ----

  final _walks = <String, Future<WalkRoute?>>{};

  @override
  Future<WalkRoute?> walk(LatLng from, LatLng to) {
    final key = walkKey(from, to);
    return _walks[key] ??= _fetchWalk(from, to)
      ..catchError((Object _) {
        _walks.remove(key);
        return null;
      });
  }

  Future<WalkRoute?> _fetchWalk(LatLng from, LatLng to) async {
    final d = await _get('/api/v6/plan', {
      'fromPlace': _ll(from),
      'toPlace': _ll(to),
      'transitModes': '', // walking only
      'directModes': 'WALK',
      'maxDirectTime': '3600', // 3 km walks exceed the 30-min default
      ..._pace,
    }) as Map<String, dynamic>;
    final direct = d['direct'] as List? ?? const [];
    if (direct.isEmpty) return null;
    final legs = ((direct.first as Map)['legs'] as List).cast<Map<String, dynamic>>();
    return WalkRoute(
      duration: Duration(seconds: ((direct.first as Map)['duration'] as num).round()),
      distanceMeters: legs.fold(0.0, (m, l) => m + ((l['distance'] as num?)?.toDouble() ?? 0)),
      points: [
        for (final l in legs)
          if (l['legGeometry'] case final Map g) ...decodePolyline(g['points'] as String, precision: g['precision'] as int? ?? 6),
      ],
    );
  }

  Leg _leg(Map<String, dynamic> j) {
    final from = j['from'] as Map<String, dynamic>;
    final to = j['to'] as Map<String, dynamic>;
    final geom = j['legGeometry'] as Map<String, dynamic>?;
    final start = _time(j['startTime']);
    final scheduled = j['scheduledStartTime'] == null ? null : _time(j['scheduledStartTime']);
    final end = _time(j['endTime']);
    final scheduledEnd = j['scheduledEndTime'] == null ? null : _time(j['scheduledEndTime']);
    final transit = j['tripId'] != null;
    return Leg(
      mode: j['mode'] as String,
      transit: transit,
      start: start,
      end: _time(j['endTime']),
      fromName: from['name'] as String? ?? '',
      toName: to['name'] as String? ?? '',
      from: _pos(from),
      to: _pos(to),
      points: geom == null
          ? [_pos(from), _pos(to)]
          : decodePolyline(geom['points'] as String, precision: geom['precision'] as int? ?? 6),
      distanceMeters: (j['distance'] as num?)?.toDouble() ?? (geom?['length'] as num?)?.toDouble() ?? 0,
      routeShortName: _line(j),
      routeColor: j['routeColor'] as String?,
      routeTextColor: j['routeTextColor'] as String?,
      headsign: j['headsign'] as String?,
      tripId: rawTripId(j['tripId'] as String?),
      backendTripId: j['tripId'] as String?,
      realtime: j['realTime'] as bool? ?? false,
      delaySeconds: transit && scheduled != null ? start.difference(scheduled).inSeconds : null,
      arrivalDelaySeconds: transit && scheduledEnd != null ? end.difference(scheduledEnd).inSeconds : null,
      intermediateStops: (j['intermediateStops'] as List?)?.length ?? 0,
      via: [
        for (final p in ((j['intermediateStops'] as List?) ?? const []).cast<Map<String, dynamic>>())
          TripStop(name: p['name'] as String? ?? '', position: _pos(p), stopId: p['stopId'] as String?),
      ],
      origin: transit ? _origin(j['tripFrom']) : null,
      fromStopId: transit ? from['stopId'] as String? : null,
      toStopId: transit ? to['stopId'] as String? : null,
      alternatives: [
        for (final alt in (j['alternatives'] as List?) ?? const []) ?_alternative(alt as List),
      ],
    );
  }

  /// A "walk" that doesn't go anywhere: MOTIS puts one between two rides
  /// from the same stop (0 m, just the minimum transfer time). Not a leg:
  /// the rides' own times still have to connect.
  static bool _sameStopWalk(Map<String, dynamic> j) {
    if (j['mode'] != 'WALK') return false;
    final from = (j['from'] as Map?)?['stopId'], to = (j['to'] as Map?)?['stopId'];
    return (from != null && from == to) || (j['distance'] as num?) == 0;
  }

  /// An alternative is `[ingress walk, transit, egress walk]`.
  LegAlternative? _alternative(List legs) {
    final parsed = [
      for (final l in legs)
        if (!_sameStopWalk(l as Map<String, dynamic>)) _leg(l),
    ];
    return parsed.any((l) => l.transit) ? LegAlternative(parsed) : null;
  }

  // ---- TripPaths / TripDetails ----

  final _trips = <String, Future<TripInfo>>{};

  @override
  Future<List<LatLng>> tripPath(Leg leg) async {
    final id = leg.backendTripId;
    if (id == null) return const [];
    try {
      return (await trip(id)).points;
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<TripInfo> trip(String backendTripId) {
    return _trips[backendTripId] ??= _fetchTrip(backendTripId)
      ..catchError((Object _) {
        _trips.remove(backendTripId); // failed: retry next time
        return TripInfo(line: '', mode: '', headsign: '', points: const [], stops: const [], realtime: false);
      });
  }

  Future<TripInfo> _fetchTrip(String id) async =>
      _parseTrip(await _get('/api/v6/trip', {'tripId': id}) as Map<String, dynamic>);

  /// What passengers call a ride (a leg or stop time): its line, with its
  /// trip number where the operator shows it ("REG 21087", see rideLabel).
  static String? _line(Map<String, dynamic> j) {
    final line = j['routeShortName'] as String? ?? j['displayName'] as String?;
    return line == null ? null : rideLabel(line, j['tripShortName'] as String?, j['tripId'] as String?);
  }

  /// A time is live unless MOTIS says it's the timetable's.
  static bool _liveReason(Object? reason) => reason is String && reason != 'NO_RT_DATA' && reason != 'SCHEDULED';

  TripInfo _parseTrip(Map<String, dynamic> d) {
    final legs = (d['legs'] as List).cast<Map<String, dynamic>>();
    final ride = legs.firstWhere((l) => l['tripId'] != null, orElse: () => legs.first);
    TripStop stop(Map<String, dynamic> p) => TripStop(
          name: p['name'] as String? ?? '',
          position: _pos(p),
          stopId: p['stopId'] as String?,
          time: switch (p['departure'] ?? p['arrival']) { final String t => _time(t), _ => null },
          scheduled: switch (p['scheduledDeparture'] ?? p['scheduledArrival']) { final String t => _time(t), _ => null },
          live: _liveReason(p['departureTimestampReason'] ?? p['arrivalTimestampReason']),
        );
    return TripInfo(
      line: _line(ride) ?? '',
      mode: ride['mode'] as String? ?? 'BUS',
      headsign: ride['headsign'] as String? ?? '',
      directionId: int.tryParse('${ride['directionId']}'),
      realtime: ride['realTime'] as bool? ?? false,
      routeColor: ride['routeColor'] as String?,
      routeTextColor: ride['routeTextColor'] as String?,
      points: [
        for (final l in legs)
          if (l['legGeometry'] case final Map g) ...decodePolyline(g['points'] as String, precision: g['precision'] as int? ?? 6),
      ],
      stops: [
        stop(ride['from'] as Map<String, dynamic>),
        for (final p in (ride['intermediateStops'] as List? ?? const [])) stop(p as Map<String, dynamic>),
        stop(ride['to'] as Map<String, dynamic>),
      ],
    );
  }

  @override
  Future<String?> sameRun(String tripId, {required String stopId, required DateTime at, String? line}) async {
    // <date>_<HH:MM>_<feed>_<trip>: the run is the first three parts.
    final parts = tripId.split('_');
    if (parts.length < 4) return null;
    final run = '${parts[0]}_${parts[1]}_${parts[2]}_';
    final d = await _get('/api/v6/stoptimes', {
      'stopId': stopId,
      'time': motisTime(at.subtract(const Duration(minutes: 5))),
      'n': '30',
      'radius': '0',
      'exactRadius': 'true',
    }) as Map<String, dynamic>;
    for (final s in (d['stopTimes'] as List).cast<Map<String, dynamic>>()) {
      final id = s['tripId'] as String?;
      final name = _line(s);
      if (id != null && id.startsWith(run) && (line == null || name?.toLowerCase() == line.toLowerCase())) return id;
    }
    return null;
  }

  // ---- PlaceSearch ----

  @override
  Future<List<Place>> search(String query, {LatLng? near}) async {
    // The geocoder doesn't know stop numbers ("71502"): look those up as a
    // stop of the local feed, in parallel, and list it first.
    final byCode = RegExp(r'^\d{3,7}$').hasMatch(query.trim()) ? _stopByCode(query.trim(), near) : null;
    final names = _geocode(query, near: near);
    final stop = await byCode;
    return [?stop, ...await names];
  }

  /// Only stops and stations: by stop number, else by name. For searches
  /// that take addresses and places from another source.
  Future<List<Place>> searchStops(String query, {LatLng? near}) async {
    final byCode = RegExp(r'^\d{3,7}$').hasMatch(query.trim()) ? _stopByCode(query.trim(), near) : null;
    final names = _geocode(query, near: near, type: 'STOP');
    final stop = await byCode;
    return [?stop, ...(await names).where((p) => p.kind == PlaceKind.stop)];
  }

  Future<Place?> _stopByCode(String code, LatLng? near) async {
    try {
      // The active city's feed, else whichever feed the stops around [near]
      // belong to (works in any city Transitous covers, no config needed).
      final feed = homeFeedId ?? (near == null ? null : await _feedNear(near));
      if (feed == null) return null;
      final d = await _get('/api/v6/stop', {'stopId': '${feed}_$code'}) as Map<String, dynamic>;
      final p = d['place'] as Map<String, dynamic>;
      final modes = ((p['modes'] as List?) ?? const []).cast<String>();
      return Place(
        name: p['name'] as String? ?? code,
        position: _pos(p),
        kind: PlaceKind.stop,
        stopId: p['stopId'] as String?,
        station: modes.any((m) => m != 'BUS' && m != 'TRAM' && m != 'COACH'),
      );
    } catch (_) {
      return null; // not a stop number here
    }
  }

  final _feeds = <String, String?>{};

  /// Feed id of the nearest stop around [p] ("it-Lazio-Rome" from
  /// "it-Lazio-Rome_71502"), cached per ~1 km cell.
  Future<String?> _feedNear(LatLng p) async {
    final cell = '${p.latitude.toStringAsFixed(2)},${p.longitude.toStringAsFixed(2)}';
    if (_feeds.containsKey(cell)) return _feeds[cell];
    String? feed;
    try {
      final stops = await nearbyStops(p);
      final id = stops.firstOrNull?.id;
      final cut = id?.lastIndexOf('_') ?? -1;
      feed = cut > 0 ? id!.substring(0, cut) : null;
    } catch (_) {}
    return _feeds[cell] = feed;
  }

  Future<List<Place>> _geocode(String query, {LatLng? near, String? type}) async {
    final d = await _get('/api/v1/geocode', {
      'text': query,
      'type': ?type,
      'language': language,
      // More than the default 10: results are re-ranked by distance in the
      // app, and local matches shouldn't be cut before that.
      'numResults': '20',
      if (near != null) 'place': _ll(near),
    }) as List;
    return [
      for (final r in d)
        Place(
          name: [r['name'], r['houseNumber']].whereType<String>().join(' '),
          subtitle: _subtitle(r as Map<String, dynamic>),
          position: _pos(r),
          kind: switch (r['type']) {
            'STOP' => PlaceKind.stop,
            'ADDRESS' => PlaceKind.address,
            _ => PlaceKind.place,
          },
          stopId: r['type'] == 'STOP' ? r['id'] as String? : null,
          // Metro / rail stations are whole stations; bus and tram stops are
          // single poles (one direction).
          station: r['type'] == 'STOP' &&
              ((r['modes'] as List?) ?? const []).any((m) => m != 'BUS' && m != 'TRAM' && m != 'COACH'),
        ),
    ];
  }

  /// The result's areas ("Roma"); the app shows its kind before it.
  static String? _subtitle(Map<String, dynamic> r) {
    final areas = (r['areas'] as List? ?? [])
        .where((a) => ((a['adminLevel'] as num?) ?? 0) >= 8)
        .map((a) => a['name'] as String)
        .toSet()
        .join(', ');
    return areas.isEmpty ? null : areas;
  }

  // ---- StopBoards ----

  @override
  Future<List<Stop>> nearbyStops(LatLng p) {
    // ~searchRadius box around p.
    final dLat = searchRadiusMeters / 111000;
    final dLon = dLat / 0.75; // cos(41.9°) ≈ 0.745
    return stopsInArea(
      LatLngBounds(
        southwest: LatLng(p.latitude - dLat, p.longitude - dLon),
        northeast: LatLng(p.latitude + dLat, p.longitude + dLon),
      ),
      from: p,
    );
  }

  @override
  Future<List<Stop>> stopsInArea(LatLngBounds area, {required LatLng from}) async {
    final d = await _get('/api/v6/map/stops', {
      'min': _ll(area.southwest),
      'max': _ll(area.northeast),
    }) as List;
    return [
      for (final s in d)
        Stop(
          id: s['stopId'] as String,
          code: s['stopCode'] as String?,
          name: s['name'] as String? ?? '',
          position: _pos(s),
          distanceMeters: distanceMeters(from, _pos(s)).round(),
        ),
    ]..sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
  }

  @override
  Future<List<BoardRow>> board(Stop stop) async {
    final d = await _get('/api/v6/stoptimes', {
      'stopId': stop.id,
      'n': '20',
      // By default MOTIS adds every stop with a similar name, e.g. the twin
      // stop across the road (other direction). Only this stop, unless it's
      // a whole station.
      if (!stop.station) ...{'radius': '0', 'exactRadius': 'true'},
    }) as Map<String, dynamic>;
    final items = <({String line, String mode, String headsign, Departure departure})>[];
    for (final s in d['stopTimes'] as List) {
      if (s['cancelled'] == true || s['tripCancelled'] == true) continue;
      if (s['pickupDropoffType'] == 'NOT_ALLOWED') continue; // arrivals at a terminus
      final place = s['place'] as Map<String, dynamic>;
      final dep = place['departure'] as String?;
      if (dep == null) continue;
      final time = _time(dep);
      final sched = place['scheduledDeparture'] == null ? null : _time(place['scheduledDeparture']);
      items.add((
        line: _line(s) ?? '?',
        mode: s['mode'] as String? ?? 'BUS',
        headsign: s['headsign'] as String? ?? '',
        departure: Departure(
          time: time,
          realtime: s['realTime'] as bool? ?? false,
          delaySeconds: sched == null ? null : time.difference(sched).inSeconds,
          tripId: rawTripId(s['tripId'] as String?),
          backendTripId: s['tripId'] as String?,
          origin: _origin(s['tripFrom']),
          stopId: place['stopId'] as String?,
          routeColor: s['routeColor'] as String?,
          routeTextColor: s['routeTextColor'] as String?,
        ),
      ));
    }
    return groupDepartures(stop, items);
  }
}
