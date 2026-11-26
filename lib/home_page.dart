import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb, setEquals;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;

import 'backend/backend.dart';
import 'backend/board_detector.dart';
import 'backend/config.dart';
import 'backend/live_rides.dart';
import 'backend/live_connection.dart';
import 'backend/motis.dart' show MotisClient;
import 'backend/route_search.dart';
import 'backend/trip_variants.dart';
import 'area_buses.dart';
import 'attribution.dart';
import 'bus_cone.dart';
import 'favorites.dart';
import 'l10n.dart';
import 'line_view.dart';
import 'on_board_bar.dart';
import 'live_buses.dart';
import 'route_picker.dart';
import 'settings.dart';
import 'settings_page.dart';
import 'sheet_widgets.dart';
import 'swipe_slot.dart';

/// Free vector tiles from OpenFreeMap (OSM data, no API key).
const kMapStyleLight = 'https://tiles.openfreemap.org/styles/positron';
const kMapStyleDark = 'https://tiles.openfreemap.org/styles/fiord';

const kWalkColor = '#9E9E9E';

/// Sheet peek: drag handle + destination search bar.
const kSheetPeek = 128.0;

/// The bottom sheet's widest (M3EBottomSheetTheme.maxWidth): centred, so
/// on wider screens the map shows on both sides of it.
const kSheetMaxWidth = 640.0;

/// Room the map credit (left) and the center button (right) need beside the
/// sheet to sit in the bottom corners instead of above it.
const _kCornerSpace = 140.0;

/// Below this zoom the map shows no stops and the sheet only the search bar.
const kMinStopsZoom = 14.0;

/// A stop farther than this from you offers Directions to it.
const kStopDirectionsMeters = 150.0;

/// Room a floating button takes at the bottom of the sheet (56 + margin).
const kFabRoom = 72.0;

/// From this zoom up, stop names are drawn next to the pins.
const kStopNamesZoom = 16.0;

/// Wait this long after the map stops moving before loading its stops.
const kAreaIdleDelay = Duration(milliseconds: 600);

/// At most this many stops get their departures loaded (nearest first).
const kMaxBoardStops = 8;

/// At most this many stop pins drawn at once.
const kMaxStopPins = 80;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  /// The configured city around the map / you (null: Transitous only).
  CityConfig? city = kCities.first;
  late TransitBackend backend = createBackend(city: city);

  /// Where to start without location: the city's, else the first city's.
  Place get _fallback => (city ?? kCities.first).fallbackCenter;
  final sheet = M3EBottomSheetController();

  /// The sheet's height, followed frame by frame while it moves (the
  /// controller only says when it settles), for what sits right above it.
  final _sheetTop = ValueNotifier<double>(0);
  late final Ticker _sheetTicker = createTicker(_onSheetTick);
  var _sheetStill = 0;
  var _sheetTouched = false;

  /// Asking "are you on the 341?" when you seem to ride a bus.
  final _boardDetector = BoardDetector();
  ({String id, Vehicle vehicle})? _boardQuestion;
  StreamSubscription<Position>? _positions;
  final toSearch = M3ESearchController();
  final fromSearch = M3ESearchController();
  MapLibreMapController? map;
  bool styleReady = false;
  bool locationGranted = false;
  M3EBottomSheetValue sheetValue = M3EBottomSheetValue.collapsed;

  LatLng? here;
  // Named in didChangeDependencies, once the locale is known.
  Place from = Place(name: '', position: kCities.first.fallbackCenter.position, isMyLocation: true);
  Place? to;
  DateTime? planTime;
  bool planArriveBy = false;

  // Departures for the visible map area (idle state).
  List<BoardRow> nearby = [];

  /// Tramite's view of the journeys' rides, by raw trip id: each one's
  /// whole trip (how sure it is, its bus, its times at every stop). Only
  /// for rides Tramite covers; kept in step with the shown journeys by
  /// [_syncLegTopics].
  final Map<String, TramiteTrip> _legTrips = {};
  late final LiveTopics _legTopics = LiveTopics(live);

  /// The bus you're on, followed through Tramite while on board: where it
  /// really is and its times, for planning from it (see [OnBoardTrip]).
  LiveSubscription? _rideSub;
  String? _rideTopic;
  TramiteTrip? _rideTrip;
  Completer<void>? _rideKnown;

  /// Tramite's view of [ride] now (waiting a little for the first answer);
  /// null when Tramite doesn't cover it or doesn't answer.
  Future<TramiteTrip?> _rideLive(OnBoardRide ride) async {
    final id = ride.liveTripId ?? ride.backendTripId;
    if (!tramite.covers(id)) {
      _leaveRide();
      return null;
    }
    final topic = TramiteClient.tripTopic(id);
    if (_rideTopic != topic) {
      _leaveRide();
      _rideTopic = topic;
      final known = _rideKnown = Completer<void>();
      _rideSub = live.subscribe(topic, (data) {
        if (_rideTopic != topic) return;
        _rideTrip = TramiteClient.parseTrip(data);
        if (!known.isCompleted) known.complete();
      });
    }
    await _rideKnown!.future.timeout(const Duration(seconds: 4), onTimeout: () {});
    return _rideTopic == topic ? _rideTrip : null;
  }

  void _leaveRide() {
    _rideSub?.cancel();
    _rideSub = null;
    _rideTopic = null;
    _rideTrip = null;
  }

  /// What Tramite says about a ride of a journey: its times, or that it's gone.
  /// Trips followed at once for the journeys (a Tramite stream takes 200
  /// topics, boards and map buses included).
  static const _maxLegTopics = 150;

  LiveRide? _liveOf(Leg ride) => liveRideFor(ride, _legTrips[ride.tripId]);

  /// Board rows from Transitous (stops Tramite doesn't cover), and from
  /// Tramite by stop id (pushed), to rebuild [nearby].
  List<BoardRow> _transitousRows = [];
  final Map<String, List<BoardRow>> _tramiteRows = {};
  late final LiveTopics _boardTopics = LiveTopics(live);

  /// The open line's buses.
  late final LiveTopics _lineTopics = LiveTopics(live);

  /// The trip shown in the line view, for its times at each stop.
  late final LiveTopics _lineTripTopics = LiveTopics(live);

  /// Follows the line view's trip [id] through Tramite, when it covers it:
  /// the stop list shows Tramite's times. An id the planner gave (a tapped
  /// departure) is found by its line and the stop it was seen at.
  void _followLineTrip(LineState state, String id) {
    final prefix = tramite.prefixOf(id);
    if (prefix == null) {
      _lineTripTopics.clear();
      return;
    }
    final hint = state.runHints[id]?.stopId;
    // A ride shown by its number ("REG 21087") is its line view's only one:
    // its vehicle is the one on the map, and its name is no line to match.
    final single = showsTripNumber(id);
    _lineTripTopics.sync({
      TramiteClient.tripTopic(id,
          lineId: single ? null : TramiteClient.lineId(prefix, state.name),
          stopId: tramite.covers(hint) ? hint : null): (data) {
        if (!mounted || line != state || state.tripId != id) return;
        final live = TramiteClient.parseTrip(data);
        setState(() => state.live = live);
        if (single) {
          state.buses = [if (live?.bus case final b?) (vehicle: b, color: null)];
          _showLineBuses();
        }
      },
    });
  }

  /// How sure a ride's time is: what Tramite says for rides it covers;
  /// otherwise live (counted as on its way: no way to tell) or timetable.
  Certainty _certainty(bool realtime, String? tripId) =>
      (tripId == null ? null : _legTrips[tripId])?.certainty ?? certaintyOf(realtime: realtime, tripId: tripId);

  /// How sure a ride's bus is, for choosing among buses: live (on its way
  /// or waiting to leave; the metro counts as live), estimated, timetable.
  int _sureness(Leg l) => switch (l.mode == 'SUBWAY' ? Certainty.moving : _certainty(l.realtime, l.tripId)) {
        Certainty.moving || Certainty.waiting => 2,
        Certainty.estimated || Certainty.returning => 1,
        Certainty.scheduled => 0,
      };

  Certainty _depCertainty(Departure d) => d.certainty ?? _certainty(d.realtime, d.tripId);

  /// Follows, through Tramite, the rides of the shown journeys (the
  /// selected one, else the whole list), and applies what is known of them.
  void _syncLegTopics() {
    _followLegs();
    _applyLegRows();
  }

  /// One topic per trip ridden in the shown journeys: the selected
  /// journey's, else the planner's and (a late bus can swap in another one)
  /// those of the journeys as listed. Rides Tramite doesn't cover keep
  /// Transitous's data.
  void _followLegs() {
    final rides = selected?.transitLegs.toList() ??
        [
          for (final it in _routeItineraries) ...it.transitLegs,
          for (final g in routes)
            for (final it in g.options) ...it.transitLegs,
        ];
    // And the buses each ride could swap to: an earlier one the planner
    // counts as left may still be caught, a later one is the fallback when
    // a connection breaks. After the rides themselves, as many as the
    // stream has room for.
    final legs = [
      ...rides,
      for (final it in selected == null ? _routeItineraries : [selected!.base ?? selected!])
        for (final l in it.transitLegs)
          for (final a in l.alternatives) a.ride,
    ];
    final wanted = <String, void Function(Object?)>{};
    final trips = <String>{};
    for (final l in legs) {
      final stop = l.fromStopId, trip = l.backendTripId, raw = l.tripId, prefix = tramite.prefixOf(l.backendTripId);
      if (trip == null || raw == null || prefix == null || trips.contains(raw)) continue;
      if (trips.length >= _maxLegTopics) break;
      trips.add(raw);
      final line = l.routeShortName;
      // The line and a stop of the ride: to find the run when the planner's
      // trip id is from another timetable version.
      final topic = TramiteClient.tripTopic(trip,
          lineId: line == null || showsTripNumber(trip) ? null : TramiteClient.lineId(prefix, line),
          stopId: tramite.covers(stop) ? stop : null);
      wanted[topic] = (data) {
        if (!mounted) return;
        final t = TramiteClient.parseTrip(data);
        setState(() {
          if (t == null) {
            _legTrips.remove(raw);
          } else {
            _legTrips[raw] = t;
          }
          _applyLegRows();
        });
      };
    }
    // A trip already followed keeps its topic, whichever ride asked first.
    final known = {for (final t in _legTopics.topics) t.split(',').first: t};
    _legTopics.sync({
      for (final MapEntry(key: topic, value: onData) in wanted.entries)
        if (known[topic.split(',').first] case final same? when !wanted.containsKey(same)) same: onData else topic: onData,
    });
    _legTrips.removeWhere((trip, _) => !trips.contains(trip));
  }

  /// New ride data: the journeys take Tramite's times (re-planned around
  /// them), the selected journey's buses go onto the map.
  void _applyLegRows() {
    final v = variants;
    if (selected == null || v == null) {
      if (to != null) {
        routes = _buildRoutes();
        _followLegs(); // a bus swapped in is followed too
      }
      return;
    }
    // The open journey moves with its buses, keeping the rides chosen.
    final now = applyLiveTimes(v.current, _liveOf, walks: walkCache, policy: appSettings.walkPolicy, when: _planWhen);
    if (!identical(now, v.current)) {
      variants = TripVariants(now.base!,
          walks: walkCache,
          walkSlots: now.walkSlots,
          choices: now.rideChoices,
          policy: appSettings.walkPolicy,
          when: _planWhen);
      final swapped = !_sameRides(now, selected!);
      selected = now;
      if (swapped) {
        _followLegs();
        _loadTripPaths(now);
      }
      _drawSelected(fit: false);
    }
    final it = selected!;
    // The bus you're on has moved: its ride starts where it is now.
    if (identical(now, v.current) && it.transitLegs.any((l) => l.onBoard)) _drawSelected(fit: false);
    tracker.show({
      for (final l in it.transitLegs)
        if (_legTrips[l.tripId]?.bus case final bus?) l.tripId!: (vehicle: bus, color: l.colors.color),
    });
    _drawApproach();
  }

  /// [nearby] from the fetched rows: one stop lists every bus, nearby one
  /// row per line + direction (from whichever stop has it soonest).
  List<BoardRow> _buildNearby() {
    final rows = [..._transitousRows, for (final r in _tramiteRows.values) ...r];
    if (filterStop != null) return boardPerDeparture(rows);
    final best = <String, BoardRow>{};
    for (final r in rows) {
      final k = '${r.line}|${r.headsign}';
      if (!best.containsKey(k) || r.next.first.time.isBefore(best[k]!.next.first.time)) best[k] = r;
    }
    return best.values.toList()..sort((a, b) => a.next.first.time.compareTo(b.next.first.time));
  }
  List<Stop> nearbyStops = [];
  final Map<String, Stop> stopById = {};
  bool nearbyLoading = true;

  /// The map was moved away from you: "Departures in this area".
  bool areaMode = false;

  /// Zoomed out past [kMinStopsZoom]: no stops, no departures.
  bool zoomedOut = false;

  /// Tapped stop: departures from this stop only.
  Stop? filterStop;

  /// How to bring back each view the one on screen was opened from, last
  /// on top (see [_leaving], [_goBack]).
  final List<VoidCallback> _backStack = [];

  /// The stop view's floating Directions: icon only while scrolling down
  /// the departures, label back on scrolling up or at the top.
  final _directionsFab = M3EExtendedFabController();
  bool _restoring = false;
  Timer? idleDebounce;

  /// Line view (a line's route, stops and live buses), when open.
  LineState? line;
  int _areaSeq = 0;

  // Routes.
  /// Walking routes fetched so far, shared by the route search and the trip view.
  /// Favourite stops and destinations (on the device).
  final favorites = FavoritesStore()..load();
  late final WalkCache? walkCache = backend.walks == null ? null : WalkCache(backend.walks!);
  /// Searches with the user's walking and change preferences (settings).
  RouteSearch get routeSearch => RouteSearch(
        backend.planner,
        walks: walkCache,
        policy: appSettings.walkPolicy,
        rank: appSettings.rankPolicy,
        stayOn: appSettings.routePreference.stayOn,
        trips: backend.trips,
      );
  List<RouteGroup> routes = [];

  /// The planner's itineraries behind [routes], before estimates (purple
  /// rides) are applied, to re-plan them when new estimates arrive.
  List<Itinerary> _routeItineraries = [];

  /// [routes] from [_routeItineraries] at Tramite's times ([_liveOf]): rides
  /// moved and connections re-planned, then grouped and ranked again.
  /// Journeys whose first bus has gone by are dropped; those that can't
  /// make a connection go last (in their section).
  List<RouteGroup> _buildRoutes() {
    // Each journey is grouped within its own section: a row's swipe options
    // are all as sure as the row (they move when a bus turns gray, red...).
    final groups = routeSearch.group(
      // Each journey at its live times: on an earlier bus when that pays,
      // and on the surest buses its rides can swap to (live, then
      // estimated, then timetable) when those differ; both are listed,
      // each in its section.
      liveJourneys(_routeItineraries, _liveOf,
          walks: walkCache, policy: appSettings.walkPolicy, when: _planWhen, sureness: _sureness),
      // A missed journey is a row of its own, so the next buses of its
      // lines keep theirs (and their place in the section).
      sectionOf: (it) => it.missedConnection ? '${_journeyKind(it)}|missed' : _journeyKind(it),
      when: _planWhen,
    );
    return [...groups.where((g) => !g.best.missedConnection), ...groups.where((g) => g.best.missedConnection)];
  }

  static bool _sameRides(Itinerary a, Itinerary b) =>
      a.transitLegs.map((l) => l.tripId).join(',') == b.transitLegs.map((l) => l.tripId).join(',');
  Itinerary? selected;

  /// Swappable rides of the selected trip; [selected] is its current composition.
  TripVariants? variants;

  /// Full vehicle paths of the selected trip's rides, by GTFS trip id.
  final Map<String, List<LatLng>> tripPaths = {};
  bool planning = false;
  String? error;

  Timer? refreshTimer;
  Timer? clock;

  /// Buses of the selected journey or the open line, on the map.
  late final LiveBusTracker tracker = LiveBusTracker(
    onFrame: (g) => _drawBuses('buses', g),
    pathOf: _busPath,
    stopPosition: (id) => _stopPositions[id],
  );

  /// Every bus around the map while browsing (no journey or line open).
  late final AreaBuses areaBuses = AreaBuses(
    connection: live,
    tracker: LiveBusTracker(onFrame: (g) => _drawBuses('area-buses', g), stopPosition: (id) => _stopPositions[id]),
  );

  /// Every stop seen on the map so far, by id: where buses are heading.
  final Map<String, LatLng> _stopPositions = {};

  Future<void> _drawBuses(String source, Map<String, dynamic> g) async {
    final m = map;
    if (m == null || !styleReady) return;
    await m.setGeoJsonSource(source, g);
    if (source == 'area-buses') _checkCones();
  }

  /// Browsed buses showing their badge (the rest are dots), as the map
  /// last placed them; null until known (every cone shown).
  Set<String>? _badged;
  bool _conesChecking = false, _conesCheckAgain = false;

  /// Cones only on buses showing their badge. The map decides alone which
  /// badges fit (see the area-buses-badge layer), so after it redraws or
  /// moves we ask it which are on screen. One check at a time, and none
  /// sooner than the map settles its placement: a cone can be a moment
  /// late to follow a bus turning into a dot or back.
  Future<void> _checkCones() async {
    if (_conesChecking) {
      _conesCheckAgain = true;
      return;
    }
    _conesChecking = true;
    try {
      do {
        _conesCheckAgain = false;
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final m = map;
        if (m == null || !styleReady || !mounted) return;
        // Whole map (generous: the rect may be in physical pixels).
        final size = MediaQuery.sizeOf(context) * 4;
        final hits = await m.queryRenderedFeaturesInRect(Offset.zero & size, ['area-buses-badge'], null);
        final ids = <String>{
          for (final f in hits)
            if ((f as Map)['properties']?['id'] ?? f['id'] case final Object id) '$id',
        };
        if (setEquals(ids, _badged)) continue;
        _badged = ids;
        await m.setLayerFilter('area-buses-cone', [
          'all',
          ['has', 'heading'],
          if (ids.isEmpty) ['==', ['get', 'id'], ''] else ['match', ['get', 'id'], ids.toList(), true, false],
        ]);
      } while (_conesCheckAgain);
    } catch (_) {
      // try again on the next redraw
    } finally {
      _conesChecking = false;
    }
  }

  /// The path a bus of the open line or the selected journey drives along:
  /// the shown trip's (the line view shows one direction's buses), or the
  /// ride's whole path.
  List<LatLng>? _busPath(String key, Vehicle v) => line != null ? line!.trip?.points : tripPaths[key];

  /// The live stream is closed while the app is in the background.
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onHide: live.pause,
    onShow: () {
      live.resume();
      _updateAreaBuses();
    },
  );

  /// Leaving the browsing view (journeys or a line open): no more area
  /// buses or stop boards followed.
  void _leaveBrowsing() {
    areaBuses.hide();
    _boardTopics.clear();
    _tramiteRows.clear();
  }

  /// Shows the buses around the visible map when browsing, hides them when
  /// a route or a line is open (those show their own buses).
  Future<void> _updateAreaBuses() async {
    final m = map;
    if (m == null || !styleReady) return;
    if (to != null || line != null || selected != null) {
      areaBuses.hide();
      return;
    }
    try {
      final view = await m.getVisibleRegion();
      if (!mounted || to != null || line != null) return;
      areaBuses.show(view, m.cameraPosition?.zoom ?? 15);
    } catch (_) {}
  }

  /// The "My location" origin at [p], named in the current language.
  Place _myLocation(LatLng p) => Place(name: context.l10n.myLocation, position: p, isMyLocation: true);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Name "My location" in the current language (also after a change).
    if (from.isMyLocation && from.name != context.l10n.myLocation) {
      final shown = fromSearch.text.isEmpty || fromSearch.text == from.name;
      from = _myLocation(from.position);
      if (shown) fromSearch.text = from.name;
    }
  }

  @override
  void initState() {
    super.initState();
    _lifecycle;
    sheet.addListener(_followSheet);
    appSettings.addListener(_onSettingsChanged);
    // What Tramite covers decides, per stop and ride, where live data comes
    // from; until it answers, Transitous.
    tramite.loadCoverage().then((_) {
      if (mounted) _refreshArea(silent: true);
    });
    _initLocation();
    // Nearby boards every 30 s while idle; routes every 60 s while listing.
    refreshTimer = Timer.periodic(const Duration(seconds: 30), (t) {
      tramite.loadCoverage(); // no-op once known; retries while unreachable
      if (_expirePlanTime() && to != null && selected == null && !planning) {
        _plan(silent: true);
        return;
      }
      if (line != null) {
        // the line's buses are pushed
      } else if (to == null) {
        _refreshArea(silent: true);
      } else if (selected == null && !planning && t.tick.isEven) {
        _plan(silent: true);
      }
    });
    clock = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted) return;
      _checkBoarding(); // buses move even when you don't get a new fix
      setState(() {});
    });
  }

  @override
  void dispose() {
    _directionsFab.dispose();
    refreshTimer?.cancel();
    clock?.cancel();
    _positions?.cancel();
    sheet.removeListener(_followSheet);
    appSettings.removeListener(_onSettingsChanged);
    _sheetTicker.dispose();
    _sheetTop.dispose();
    idleDebounce?.cancel();
    _lifecycle.dispose();
    _leaveBrowsing();
    _legTopics.clear();
    _leaveRide();
    _lineTopics.clear();
    _lineTripTopics.clear();
    toSearch.dispose();
    fromSearch.dispose();
    favorites.dispose();
    sheet.dispose();
    super.dispose();
  }

  Future<void> _initLocation() async {
    try {
      if (await Geolocator.isLocationServiceEnabled()) {
        var p = await Geolocator.checkPermission();
        if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
        if (p != LocationPermission.denied && p != LocationPermission.deniedForever) {
          setState(() => locationGranted = true);
          final pos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(timeLimit: Duration(seconds: 10)),
          );
          here = LatLng(pos.latitude, pos.longitude);
          _showWebPuck(pos);
          _switchCityFor(here!);
          from = _myLocation(here!);
          map?.animateCamera(CameraUpdate.newLatLngZoom(here!, 15.5));
          _followLocation();
        }
      }
    } catch (_) {
      // Fall back to Termini (also handy when testing from outside Rome).
    }
    if (here == null) {
      from = _fallback;
      fromSearch.text = from.name;
    }
    _refreshArea();
  }

  Position? _lastFix;

  /// On web the map draws our own fixes (see [MapLibreMap.locationSource]).
  void _showWebPuck(Position pos) {
    if (!kIsWeb) return;
    _lastFix = pos;
    map?.updateManualLocation(
      ManualLocationUpdate(
        target: LatLng(pos.latitude, pos.longitude),
        horizontalAccuracy: pos.accuracy,
        timestamp: pos.timestamp,
      ),
    );
  }

  /// Keeps [here] current (and "My location" with it), for the center
  /// button and to notice you riding a bus.
  void _followLocation() {
    _positions ??= Geolocator.getPositionStream(locationSettings: const LocationSettings(distanceFilter: 10)).listen(
      (pos) {
        if (!mounted) return;
        setState(() {
          here = LatLng(pos.latitude, pos.longitude);
          if (from.isMyLocation) from = _myLocation(here!);
        });
        _showWebPuck(pos);
        _checkBoarding();
        appSettings.observeWalking(
          WalkFix(
            position: LatLng(pos.latitude, pos.longitude),
            time: pos.timestamp,
            accuracy: pos.accuracy,
            // Android/iOS report 0 (or less) when they don't know the speed.
            speed: pos.speed > 0 ? pos.speed : null,
          ),
          riding: from.onBoard != null,
        );
      },
      onError: (Object _) {},
    );
  }

  /// A bus has stayed near you while you moved: ask whether you're on it.
  void _checkBoarding() {
    final p = here;
    if (p == null || from.onBoard != null || _boardQuestion != null) return;
    final all = {...areaBuses.tracker.buses, ...tracker.buses};
    final id = _boardDetector.update(p, {for (final e in all.entries) e.key: e.value.drawn}, DateTime.now());
    final v = id == null ? null : all[id]?.vehicle;
    if (v == null || v.routeShortName == null || v.backendTripId == null) return;
    HapticFeedback.mediumImpact();
    setState(() => _boardQuestion = (id: id!, vehicle: v));
  }

  void _answerBoarding(bool yes) {
    final q = _boardQuestion;
    if (q == null) return;
    setState(() => _boardQuestion = null);
    if (yes) {
      _board(q.vehicle);
    } else {
      _boardDetector.dismiss(q.id, DateTime.now()); // other buses may still be asked about
    }
  }

  /// Preferences or servers changed: the routes shown were made with the
  /// old ones.
  void _onSettingsChanged() {
    if (!mounted) return;
    if (to != null && selected == null) {
      _plan(silent: true);
    } else {
      _refreshArea(silent: true);
    }
  }

  void _openSettings() {
    HapticFeedback.selectionClick();
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
  }

  /// Follows the sheet's height until it has stopped moving.
  void _followSheet() {
    _sheetStill = 0;
    if (!_sheetTicker.isActive) _sheetTicker.start();
  }

  void _onSheetTick(Duration _) {
    final e = sheet.extent;
    if ((e - _sheetTop.value).abs() > 0.5) {
      _sheetTop.value = e;
      _sheetStill = 0;
    } else if (!_sheetTouched && ++_sheetStill > 10) {
      _sheetTicker.stop();
    }
  }

  /// The map is centred on you (nothing for the center button to do).
  bool get _centeredOnMe {
    final p = here, c = map?.cameraPosition?.target;
    return p == null || (c != null && distanceMeters(p, c) < 40);
  }

  // ---------- data ----------

  /// Map stopped moving: after [kAreaIdleDelay] load what's in view.
  void _onCameraIdle() {
    setState(() {}); // the center button shows only when away from you
    _checkCones();
    _updateAreaBuses();
    if (to != null || line != null) return; // the area list isn't shown
    idleDebounce?.cancel();
    idleDebounce = Timer(kAreaIdleDelay, _refreshArea);
  }

  /// Loads stops in the visible map area (pins) and departures from the
  /// nearest of them, or from [filterStop] only when one is selected.
  Future<void> _refreshArea({bool silent = false}) async {
    _updateAreaBuses();
    final m = map;
    if (m == null || !styleReady || to != null || line != null) return;
    final seq = ++_areaSeq;
    final camera = m.cameraPosition;
    final zoom = camera?.zoom ?? 15;

    final far = zoom < kMinStopsZoom;
    if (far && filterStop == null) {
      // Only the search bar is left: drop the sheet to its lowest height
      // (dragging is disabled while in this state, see build()).
      if (!zoomedOut) sheet.animateTo(M3EBottomSheetValue.preview);
      _boardTopics.clear();
      setState(() {
        zoomedOut = true;
        nearbyStops = [];
        nearby = [];
        _tramiteRows.clear();
        _transitousRows = [];
        nearbyLoading = false;
      });
      _drawNearbyStops();
      return;
    }

    final center = camera?.target ?? here ?? _fallback.position;
    _switchCityFor(center);
    final home = here ?? _fallback.position;
    if (zoomedOut) sheet.animateTo(M3EBottomSheetValue.collapsed); // content is back
    setState(() {
      zoomedOut = false;
      // "near you" while the view is still around your position.
      areaMode = distanceMeters(center, home) > 250;
      if (!silent) nearbyLoading = true;
    });

    try {
      final area = await _visibleArea(m);
      final reference = areaMode ? center : home;
      // Zoomed out on a stop: just its departures, no pins for the area.
      final stops = far ? <Stop>[] : await backend.stops.stopsInArea(area, from: reference);
      if (seq != _areaSeq || !mounted) return;
      final pins = stops.take(kMaxStopPins).toList();
      final boardStops = filterStop != null ? [filterStop!] : pins.take(kMaxBoardStops).toList();
      // Stops Tramite covers are followed there (pushed, all colours); the
      // rest are asked to Transitous on each refresh. A station mixes
      // operators: its departures from stops Tramite covers come from
      // Tramite too, listed under the station.
      final followed = <String, Stop>{}; // Tramite stop id -> stop its rows show under
      final asked = <Stop>[];
      for (final s in boardStops) {
        if (!s.station && tramite.covers(s.id)) {
          followed[s.id] = s;
        } else {
          asked.add(s);
        }
      }
      final boards = await Future.wait(asked.map((s) => backend.stops.board(s).catchError((_) => <BoardRow>[])));
      if (seq != _areaSeq || !mounted) return;
      final rows = <BoardRow>[];
      for (final (i, s) in asked.indexed) {
        for (final r in boards[i]) {
          final next = <Departure>[];
          for (final d in r.next) {
            final id = d.stopId;
            if (s.station && id != null && tramite.covers(id)) {
              followed[id] = s;
            } else {
              next.add(d);
            }
          }
          if (next.isNotEmpty) rows.add(BoardRow(stop: r.stop, line: r.line, mode: r.mode, headsign: r.headsign, next: next));
        }
      }
      for (final s in pins) {
        _stopPositions[s.id] = s.position;
      }
      areaBuses.tracker.refreshHeadings(); // buses can now point at these stops
      setState(() {
        nearbyStops = pins;
        stopById
          ..clear()
          ..addEntries(pins.map((s) => MapEntry(s.id, s)));
        _transitousRows = rows;
        _tramiteRows.removeWhere((id, _) => !followed.containsKey(id));
        nearby = _buildNearby();
        error = null;
      });
      _boardTopics.sync({
        for (final MapEntry(key: id, value: stop) in followed.entries)
          TramiteClient.departuresTopic(id): (data) {
            if (!mounted) return;
            setState(() {
              _tramiteRows[id] = TramiteClient.parseBoard(data, stop);
              nearby = _buildNearby();
            });
          },
      });
      _drawNearbyStops();
    } catch (e) {
      if (mounted && !silent && seq == _areaSeq) setState(() => error = '$e');
    } finally {
      if (mounted && seq == _areaSeq) setState(() => nearbyLoading = false);
    }
  }

  /// The part of the map you can actually see: the visible region minus the
  /// strip hidden under the sheet (bottom content inset).
  Future<LatLngBounds> _visibleArea(MapLibreMapController m) async {
    final h = MediaQuery.sizeOf(context).height;
    final hidden = (_mapInsets().bottom / h).clamp(0.0, 0.8);
    final r = await m.getVisibleRegion();
    final latSpan = r.northeast.latitude - r.southwest.latitude;
    return LatLngBounds(
      southwest: LatLng(r.southwest.latitude + latSpan * hidden, r.southwest.longitude),
      northeast: r.northeast,
    );
  }

  /// The stop view: [stop]'s departures, the search bar out of the way.
  /// Opened the same way from the map, a line or search; back returns to
  /// where it was opened from (see [_goBack]).
  void _openStop(Stop stop, {bool moveCamera = false}) {
    _leaving(_View.stop);
    HapticFeedback.selectionClick();
    _directionsFab.expand();
    setState(() {
      filterStop = stop;
      nearby = [];
    });
    if (line != null) _closeLine();
    if (to != null) _clearDestination();
    if (sheetValue == M3EBottomSheetValue.preview) sheet.animateTo(M3EBottomSheetValue.collapsed);
    _drawNearbyStops();
    // Moving there triggers the area reload, which honours the stop; load
    // right away too in case the camera is already there (no move, no idle).
    if (moveCamera) map?.animateCamera(CameraUpdate.newLatLngZoom(stop.position, 17));
    _refreshArea();
  }

  _View get _view => line != null
      ? _View.line
      : to != null
          ? _View.journeys
          : filterStop != null
              ? _View.stop
              : _View.browse;

  /// About to open a [next] view: remember how to bring back the one on
  /// screen, for [_goBack]. From the plain map there's nothing to remember
  /// (back closes to it anyway), so the history starts over there.
  void _leaving(_View next) {
    if (_restoring) return;
    final now = _view;
    if (now == next) return; // a view replacing one of its kind
    switch (now) {
      case _View.browse:
        _backStack.clear();
      case _View.stop:
        final stop = filterStop!;
        _backStack.add(() => _openStop(stop, moveCamera: true));
      case _View.journeys:
        final dest = to!;
        _backStack.add(() => _setDestination(dest));
      case _View.line:
        final l = line!;
        final name = l.name, mode = l.mode, tripId = l.tripId, lineId = l.lineId;
        final hint = tripId == null ? null : l.runHints[tripId];
        _backStack.add(() => _openLine(name: name, mode: mode, tripId: tripId, lineId: lineId, hint: hint));
    }
  }

  /// Back (arrow or gesture): a journey's details go back to the list;
  /// any other view closes and the one it was opened from comes back.
  void _goBack() {
    if (selected != null) return _deselect();
    final restore = _backStack.isEmpty ? null : _backStack.removeLast();
    _restoring = true;
    try {
      if (line != null) _closeLine();
      if (to != null) _clearDestination();
      if (filterStop != null) _clearFilter();
      restore?.call();
    } finally {
      _restoring = false;
    }
  }

  void _clearFilter() {
    setState(() {
      filterStop = null;
      nearby = [];
    });
    _drawNearbyStops();
    _refreshArea();
  }

  /// Minutes [it] sets off before the departure time chosen, or null
  /// (leaving now, arriving by a time, or within the minute of slack every
  /// bus gets, see [LegAlternative.reachableFrom]).
  int? _leavesEarly(Itinerary it) {
    final t = planTime;
    if (t == null || planArriveBy) return null;
    final minutes = t.difference(it.start).inMinutes;
    return minutes > 1 ? minutes : null;
  }

  /// When the journeys are planned for (the time chosen, or leave now).
  PlanTime get _planWhen => PlanTime(time: planTime, arriveBy: planArriveBy);

  /// A chosen time that has come: back to "leave now", as if never set.
  /// True when it changed.
  bool _expirePlanTime() {
    if (!PlanTime(time: planTime, arriveBy: planArriveBy).passed(DateTime.now())) return false;
    setState(() {
      planTime = null;
      planArriveBy = false;
    });
    return true;
  }

  Future<void> _plan({bool silent = false}) async {
    final dest = to;
    if (dest == null) return;
    _expirePlanTime();
    // The walking pace (setting or newly learned) applies from this search.
    if (useWalkingSpeed(appSettings.walkingSpeedKmh)) walkCache?.clear();
    _leaveBrowsing();
    setState(() {
      planning = true;
      error = null;
      if (!silent) routes = [];
    });
    try {
      // Several planner profiles merged and grouped by line sequence,
      // groups ordered by earliest arrival (see RouteSearch).
      // On a bus: every route starts on board (see on_board.dart).
      final ride = from.onBoard;
      if (ride == null) _leaveRide();
      final list = ride != null
          ? await routeSearch.searchOnBoard(ride, dest.position, toName: dest.name, live: await _rideLive(ride))
          : await routeSearch.search(from.position, dest.position, toName: dest.name, when: _planWhen);
      if (!mounted || to != dest) return;
      setState(() {
        _routeItineraries = [for (final g in list) ...g.options];
        // Then Tramite's view of the rides it covers, pushed as it changes:
        // colours, and inferred times (re-planned around). Rides still
        // listed keep what is known until then (no flicker).
        _syncLegTopics();
        routes = _buildRoutes();
      });
    } on OnBoardTripOver {
      if (mounted) setState(() => error = context.l10n.onBoardTripOver);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => planning = false);
    }
  }

  // ---------- map ----------

  /// Fetch the full path of each ride (cached per trip by the backend).
  void _loadTripPaths(Itinerary it) {
    final paths = backend.paths;
    if (paths == null) return;
    for (final leg in it.transitLegs) {
      final id = leg.tripId;
      if (id == null || tripPaths.containsKey(id)) continue;
      paths.tripPath(leg).then((p) {
        if (!mounted || p.isEmpty) return;
        tripPaths[id] = p;
        tracker.refreshHeadings();
        _drawApproach();
      });
    }
  }

  /// Dotted line from each tracked vehicle to the stop where you board it,
  /// only while it hasn't reached that stop yet. Not for the bus you're on.
  Future<void> _drawApproach() async {
    if (!styleReady) return;
    final it = selected;
    final features = <Map<String, dynamic>>[];
    if (it != null) {
      for (final leg in it.transitLegs) {
        if (leg.onBoard) continue; // you're on it: its ride starts at the bus
        final path = tripPaths[leg.tripId];
        final bus = tracker.buses[leg.tripId];
        if (path == null || bus == null) continue;
        final seg = approachPath(path, bus.vehicle.position, leg.from);
        if (seg.length < 2) continue;
        features.add({
          'type': 'Feature',
          'geometry': {
            'type': 'LineString',
            'coordinates': [for (final p in seg) [p.longitude, p.latitude]],
          },
          'properties': {'color': _colorHexFor(it, leg)},
        });
      }
    }
    await map!.setGeoJsonSource('approach', _collection(features));
  }

  // ---------- line view ----------


  /// Opens the line view for [name]. [tripId] (a tapped departure, in
  /// Transitous form) picks the direction to show; otherwise the first
  /// direction with a live bus. [lineId] is the line in Tramite (e.g.
  /// "it-Lazio-Rome_85"), known from line search; else derived from [tripId].
  /// Without Tramite for the line: its route only, no live buses.
  Future<void> _openLine({required String name, required String mode, String? tripId, String? lineId, RunHint? hint}) async {
    final trips = backend.trips;
    if (trips == null) return;
    _leaving(_View.line);
    HapticFeedback.selectionClick();
    if (selected != null) _deselect();
    if (to != null) _clearDestination();
    final state = LineState(name, mode)..tripId = tripId;
    if (tripId != null && hint != null) state.runHints[tripId] = hint;
    setState(() {
      line = state;
      filterStop = null;
      nearby = [];
    });
    if (sheetValue == M3EBottomSheetValue.preview) sheet.animateTo(M3EBottomSheetValue.collapsed);
    _drawNearbyStops();
    _leaveBrowsing();
    if (tripId != null) _loadLineTrip(tripId);
    // Rides told apart by number (trains): that one ride, not every vehicle
    // of a "line" like REG (see kTripNumberFeeds).
    if (showsTripNumber(tripId)) return;

    final prefix = lineId == null ? tramite.prefixOf(tripId) : null;
    final id = state.lineId = lineId ?? (prefix == null ? null : TramiteClient.lineId(prefix, name));
    if (id == null) {
      if (tripId == null) setState(() => state.error = context.l10n.errorNoLiveBusesForLine);
      return;
    }
    // The line's buses, pushed: drawn, and one trip per direction for the
    // direction switch (the first one shown if no departure picked one).
    _lineTopics.sync({
      TramiteClient.lineTopic(id): (data) {
        if (!mounted || line != state) return;
        final buses = state.buses = TramiteClient.parseVehicles(data);
        for (final b in buses) {
          final t = b.vehicle.backendTripId, stop = b.vehicle.stopId;
          if (t == null) continue;
          state.directions.putIfAbsent(b.vehicle.directionId ?? 0, () => t);
          // The stop it heads to, now: where the planner can find the run.
          if (stop != null) state.runHints[t] = (stopId: stop, at: DateTime.now());
        }
        _showLineBuses();
        if (state.tripId == null) {
          final first = state.directions.values.firstOrNull;
          if (first != null) {
            _loadLineTrip(first);
          } else {
            setState(() => state.error = context.l10n.errorNoBusRunning(name));
          }
        } else {
          setState(() {});
        }
        _drawApproach();
      },
    });
  }

  Future<void> _loadLineTrip(String id) async {
    final state = line;
    final trips = backend.trips;
    if (state == null || trips == null) return;
    setState(() {
      state.tripId = id;
      state.trip = null;
      state.live = null;
      state.error = null;
    });
    _followLineTrip(state, id);
    _showLineBuses();
    try {
      final t = await _tripOrSameRun(trips, id, state);
      if (line != state) return;
      setState(() => state.trip = t);
      _showLineBuses();
      _drawLine();
      _fitTo(t.points);
    } catch (e) {
      if (line == state) setState(() => state.error = context.l10n.errorLoadLine('$e'));
    }
  }

  /// The trip from the planner; if it doesn't know the id (it came from
  /// Tramite, whose timetable can be a newer version), the same run under
  /// the planner's id, found where the hint says it passes.
  Future<TripInfo> _tripOrSameRun(TripDetails trips, String id, LineState state) async {
    try {
      return await trips.trip(id);
    } catch (_) {
      final hint = state.runHints[id];
      if (hint == null) rethrow;
      final same = await trips.sameRun(id, stopId: hint.stopId, at: hint.at, line: state.name);
      if (same == null || same == id) rethrow;
      return trips.trip(same);
    }
  }

  /// A bus tapped on the map while browsing: its trip in the line view, as
  /// when tapping a departure. Its next stop, now, is where the planner can
  /// find the run if the trip id is from another timetable version.
  void _openBus(String vehicleId) {
    final v = areaBuses.tracker.buses[vehicleId]?.vehicle;
    final name = v?.routeShortName;
    if (v == null || name == null) return;
    final stop = v.stopId;
    _openLine(
      name: name,
      mode: v.mode,
      tripId: v.backendTripId,
      hint: stop == null ? null : (stopId: stop, at: DateTime.now()),
    );
  }

  /// A map long press: on a bus, you're riding it ([_board]); elsewhere,
  /// a dropped pin to go to.
  Future<void> _onMapLongPress(math.Point<double> point, LatLng ll) async {
    final m = map;
    if (m != null && styleReady) {
      try {
        // A finger is bigger than a bus dot: a box around the press.
        final hits = await m.queryRenderedFeaturesInRect(
            Rect.fromCenter(center: Offset(point.x, point.y), width: 36, height: 36),
            ['area-buses-badge', 'area-buses-dot', 'buses-circle'],
            null);
        for (final f in hits) {
          final id = '${(f as Map)['properties']?['id'] ?? f['id']}';
          final v = areaBuses.tracker.buses[id]?.vehicle ?? tracker.buses[id]?.vehicle;
          if (v != null) {
            _board(v);
            return;
          }
        }
      } catch (_) {
        // can't tell: treat it as a pin
      }
    }
    if (mounted) _setDestination(Place(name: context.l10n.droppedPin, position: ll));
  }

  /// You're riding [v]: journeys start on board from now on, the toolbar at
  /// the top says so (its ✕ goes back to your location). Its run is looked up in
  /// the planner, under another id if it came from another timetable
  /// version (see TripDetails.sameRun).
  Future<void> _board(Vehicle v) async {
    final trips = backend.trips;
    final id = v.backendTripId, name = v.routeShortName;
    if (trips == null || id == null || name == null) return;
    HapticFeedback.heavyImpact();
    if (_boardQuestion != null) setState(() => _boardQuestion = null);
    String? plannerId = id;
    TripInfo? info;
    try {
      info = await trips.trip(id);
    } catch (_) {
      try {
        final stop = v.stopId;
        plannerId = stop == null ? null : await trips.sameRun(id, stopId: stop, at: DateTime.now(), line: name);
        if (plannerId != null) info = await trips.trip(plannerId);
      } catch (_) {}
    }
    if (!mounted) return;
    if (plannerId == null || info == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.errorLoadLine(name))));
      return;
    }
    final place = Place(
      name: context.l10n.onBoardOrigin(name, titleCase(info.headsign)),
      position: v.position,
      onBoard: OnBoardRide(
        backendTripId: plannerId,
        tripId: MotisClient.rawTripId(plannerId) ?? plannerId,
        liveTripId: id,
        line: name,
        mode: info.mode,
        headsign: info.headsign,
      ),
    );
    if (line != null) _closeLine();
    await _setOrigin(place);
    if (mounted && to == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(context.l10n.onBoardPickDestination(name))));
    }
  }

  /// Off the bus: journeys start from your location again.
  void _leaveBoard() => _setOrigin(here != null ? _myLocation(here!) : _fallback);

  /// The open line's buses going the shown trip's way (the direction
  /// switch shows the others). Its direction: the loaded trip's, else that
  /// of the bus running it; unknown, every bus.
  void _showLineBuses() {
    final state = line;
    if (state == null) return;
    final dir = state.trip?.directionId ??
        state.buses.where((b) => b.vehicle.backendTripId == state.tripId).firstOrNull?.vehicle.directionId;
    tracker.show({
      for (final b in state.buses)
        if (dir == null || b.vehicle.directionId == null || b.vehicle.directionId == dir || b.vehicle.backendTripId == state.tripId)
          b.vehicle.tripId ?? b.vehicle.id: (vehicle: b.vehicle, color: state.colors.color),
    });
    tracker.refreshHeadings(); // the shown trip's path may be new
    _drawApproach();
  }

  /// Trip id of the other direction, if a live bus is running it.
  String? _otherDirection() {
    final state = line;
    final dir = state?.trip?.directionId;
    if (state == null || state.directions.length < 2) return null;
    return state.directions.entries.where((e) => e.key != dir).map((e) => e.value).firstOrNull;
  }

  void _closeLine() {
    if (line == null) return;
    setState(() => line = null);
    _lineTopics.clear();
    _lineTripTopics.clear();
    tracker.clear();
    _drawLine();
    _drawNearbyStops();
    _refreshArea();
  }

  Future<void> _drawLine() async {
    if (!styleReady) return;
    final t = line?.trip;
    final color = line?.colors.color;
    await map!.setGeoJsonSource(
        'line',
        _collection([
          if (t != null)
            {
              'type': 'Feature',
              'geometry': {
                'type': 'LineString',
                'coordinates': [for (final p in t.points) [p.longitude, p.latitude]],
              },
              'properties': {'color': color},
            },
        ]));
    await map!.setGeoJsonSource(
        'line-stops',
        _collection([
          if (t != null)
            for (final (i, st) in t.stops.indexed)
              {..._point(st.position, {'color': color, 'name': titleCase(st.name)}), 'id': '$i'},
        ]));
  }

  /// A stop of the line on screen, tapped on the map or in the sheet: its
  /// departures. One the backend gave no id for can only be shown.
  void _openLineStop(TripStop stop) {
    final id = stop.stopId;
    if (id == null) {
      map?.animateCamera(CameraUpdate.newLatLngZoom(stop.position, 16.5));
      return;
    }
    _openStop(
      Stop(
        id: id,
        name: titleCase(stop.name),
        position: stop.position,
        distanceMeters: here == null ? 0 : distanceMeters(here!, stop.position).round(),
      ),
      moveCamera: true,
    );
  }

  /// Search result "timetable" button: show that stop's departures, like
  /// tapping its pin.
  void _openStopTimetable(Place p) {
    _openStop(
      Stop(
        id: p.stopId!,
        name: p.name,
        position: p.position,
        distanceMeters: here == null ? 0 : distanceMeters(here!, p.position).round(),
        // Metro / rail stations show all platforms (Termini: A + B); a bus or
        // tram stop shows just this pole, i.e. one direction.
        station: p.station,
      ),
      moveCamera: true,
    );
  }

  /// Picks the configured city around [p] (or none: Transitous only) and
  /// rebuilds the city-specific backend parts. Caches and favourites stay.
  void _switchCityFor(LatLng p) {
    final next = cityAt(p);
    if (next?.id == city?.id) return;
    setState(() {
      city = next;
      backend = createBackend(city: next);
    });
  }

  Future<void> _onStyleLoaded() async {
    final m = map!;
    final primary = _hex(Theme.of(context).colorScheme.primary);
    const empty = {'type': 'FeatureCollection', 'features': []};
    final labelColor = _hex(Theme.of(context).colorScheme.onSurface);
    final haloColor = _hex(Theme.of(context).colorScheme.surface);
    // One badge and one cone image for every bus, tinted per bus by the
    // map. Added here, before any bus: images added while the map draws
    // can come out with other images' pixels on Android.
    await m.addImage(kBusBadgeImage, await busBadgeSdf(), true, 3);
    await m.addImage(kBusConeImage, await busConeSdf(), true, 3);
    await m.addGeoJsonSource('nearby', empty, promoteId: 'id');
    for (final id in ['line', 'line-stops', 'approach', 'route', 'via', 'stops', 'endpoints', 'buses']) {
      await m.addGeoJsonSource(id, empty);
    }
    // Feature id = vehicle id: a tapped bus opens its trip.
    await m.addSource('area-buses', const GeojsonSourceProperties(data: empty, promoteId: 'id'));
    // Stop pins: tappable (filters departures to that stop); the selected one
    // is bigger.
    await m.addCircleLayer('nearby', 'nearby-circle',
        CircleLayerProperties(
          circleRadius: ['case', ['get', 'selected'], 10, 6],
          circleColor: primary,
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: ['case', ['get', 'selected'], 3, 2],
        ),
        minzoom: kMinStopsZoom);
    m.onFeatureTapped.add((_, latLng, id, layerId, _) {
      if (layerId == 'area-buses-badge' || layerId == 'area-buses-dot') {
        _openBus(id);
        return;
      }
      if (layerId == 'line-stops-circle' || layerId == 'line-stops-label') {
        final stops = line?.trip?.stops;
        final i = int.tryParse(id);
        if (stops != null && i != null && i < stops.length) _openLineStop(stops[i]);
        return;
      }
      if (layerId != 'nearby-circle' && layerId != 'nearby-label') return;
      final stop = stopById[id];
      if (stop != null) _openStop(stop);
    });
    await m.addLineLayer('route', 'route-casing',
        const LineLayerProperties(lineColor: '#FFFFFF', lineWidth: 10, lineCap: 'round', lineJoin: 'round'),
        filter: ['==', ['get', 'walk'], false], enableInteraction: false);
    await m.addLineLayer('route', 'route-line',
        const LineLayerProperties(lineColor: ['get', 'color'], lineWidth: 6, lineCap: 'round', lineJoin: 'round'),
        filter: ['==', ['get', 'walk'], false], enableInteraction: false);
    await m.addLineLayer('route', 'route-walk',
        const LineLayerProperties(lineColor: kWalkColor, lineWidth: 4, lineDasharray: [0.5, 2], lineCap: 'round'),
        filter: ['==', ['get', 'walk'], true], enableInteraction: false);
    // Where a live vehicle still has to travel before reaching your stop:
    // dotted, in the leg's color, under the route itself.
    await m.addLineLayer('approach', 'approach-line',
        const LineLayerProperties(
            lineColor: ['get', 'color'], lineWidth: 4, lineOpacity: 0.85, lineDasharray: [0.1, 2], lineCap: 'round'),
        belowLayerId: 'route-casing', enableInteraction: false);
    // Line view: the whole route and its stops (names when zoomed in).
    await m.addLineLayer('line', 'line-path',
        const LineLayerProperties(lineColor: ['get', 'color'], lineWidth: 5, lineCap: 'round', lineJoin: 'round'),
        belowLayerId: 'approach-line', enableInteraction: false);
    await m.addCircleLayer('line-stops', 'line-stops-circle',
        const CircleLayerProperties(
            circleRadius: 4, circleColor: '#FFFFFF', circleStrokeColor: ['get', 'color'], circleStrokeWidth: 2.5));
    await m.addSymbolLayer('line-stops', 'line-stops-label',
        SymbolLayerProperties(
          textField: ['get', 'name'],
          textFont: ['Noto Sans Regular'],
          textSize: 11,
          textColor: labelColor,
          textHaloColor: haloColor,
          textHaloWidth: 1.5,
          textAnchor: 'left',
          textOffset: [0.8, 0],
          textOptional: true,
        ),
        minzoom: 15);
    // A route's rides: the stops they pass on the way (names when zoomed in),
    // smaller than where you get on and off.
    await m.addCircleLayer('via', 'via-circle',
        const CircleLayerProperties(
            circleRadius: 3.5, circleColor: '#FFFFFF', circleStrokeColor: ['get', 'color'], circleStrokeWidth: 2),
        minzoom: 12,
        enableInteraction: false);
    await m.addSymbolLayer('via', 'via-label',
        SymbolLayerProperties(
          textField: ['get', 'name'],
          textFont: ['Noto Sans Regular'],
          textSize: 11,
          textColor: labelColor,
          textHaloColor: haloColor,
          textHaloWidth: 1.5,
          textAnchor: 'left',
          textOffset: [0.8, 0],
          textOptional: true,
        ),
        minzoom: 15,
        enableInteraction: false);
    await m.addCircleLayer('stops', 'stops-circle',
        const CircleLayerProperties(
            circleRadius: 6, circleColor: '#FFFFFF', circleStrokeColor: ['get', 'color'], circleStrokeWidth: 3),
        enableInteraction: false);
    await m.addCircleLayer('endpoints', 'endpoints-circle',
        const CircleLayerProperties(
            circleRadius: 9, circleColor: ['get', 'color'], circleStrokeColor: '#FFFFFF', circleStrokeWidth: 3),
        enableInteraction: false);
    // Heading cones, under the bus circles: see-through wedges in the bus
    // color fading towards the tip, with soft sides, turned with the map. Only buses whose heading
    // is known have one.
    for (final (source, size) in [('area-buses', 0.9), ('buses', 1.2)]) {
      await m.addSymbolLayer(source, '$source-cone',
          SymbolLayerProperties(
            iconImage: kBusConeImage,
            // Only the halo is drawn: with this width and blur it turns
            // the image into the fade (see busConeSdf). The fill would
            // be a solid wedge on top.
            iconColor: 'rgba(0, 0, 0, 0)',
            iconHaloColor: ['get', 'color'],
            iconHaloWidth: coneHaloWidth(size),
            iconHaloBlur: coneHaloBlur(size),
            iconOpacity: kConeOpacity,
            iconRotate: ['get', 'heading'],
            iconRotationAlignment: 'map',
            iconPitchAlignment: 'map',
            iconSize: size,
            iconAllowOverlap: true,
            iconIgnorePlacement: true,
          ),
          filter: ['has', 'heading'],
          minzoom: source == 'area-buses' ? AreaBuses.minZoom : null,
          enableInteraction: false);
    }
    // Browsing: every bus around, smaller than a route's or line's own.
    // Each is a small dot in its color, and on it a badge with its line
    // where there's room: a badge that would overlap one already shown is
    // hidden (moving buses go first), leaving just the dot.
    await m.addCircleLayer('area-buses', 'area-buses-dot',
        const CircleLayerProperties(
            circleRadius: 3.5, circleColor: ['get', 'color'], circleStrokeColor: '#FFFFFF', circleStrokeWidth: 1),
        minzoom: AreaBuses.minZoom);
    await m.addSymbolLayer('area-buses', 'area-buses-badge',
        const SymbolLayerProperties(
          iconImage: kBusBadgeImage,
          iconColor: ['get', 'color'],
          // The white ring.
          iconHaloColor: '#FFFFFF',
          iconHaloWidth: kBusBadgeRing,
          iconPadding: 0,
          symbolSortKey: ['case', ['get', 'moving'], 0, 1],
          textField: ['get', 'line'],
          textFont: ['Noto Sans Bold'],
          textSize: 9,
          textColor: ['get', 'text'],
          // The badge decides: the line on it goes wherever it goes.
          textAllowOverlap: true,
          textIgnorePlacement: true,
        ),
        minzoom: AreaBuses.minZoom);
    // Stop names once zoomed in enough. Above the browsed buses: placed
    // first, so a bus badge that would cover a name is left as its dot.
    await m.addSymbolLayer('nearby', 'nearby-label',
        SymbolLayerProperties(
          textField: ['get', 'name'],
          textFont: ['Noto Sans Regular'],
          textSize: 12,
          textColor: labelColor,
          textHaloColor: haloColor,
          textHaloWidth: 1.5,
          textAnchor: 'top',
          textOffset: [0, 0.9],
          textOptional: true,
        ),
        minzoom: kStopNamesZoom);
    await m.addCircleLayer('buses', 'buses-circle',
        const CircleLayerProperties(
            circleRadius: 15, circleColor: ['get', 'color'], circleStrokeColor: '#FFFFFF', circleStrokeWidth: 3),
        enableInteraction: false);
    await m.addSymbolLayer('buses', 'buses-label',
        const SymbolLayerProperties(
          textField: ['get', 'line'],
          textFont: ['Noto Sans Bold'],
          textSize: 11,
          textColor: ['get', 'text'],
          textAllowOverlap: true,
          textIgnorePlacement: true,
        ),
        enableInteraction: false);
    styleReady = true;
    await m.updateContentInsets(_mapInsets());
    _drawNearbyStops();
    _drawEndpoints();
    _drawSelected();
    _refreshArea();
  }

  static String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  Map<String, dynamic> _point(LatLng p, Map<String, dynamic> props) => {
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [p.longitude, p.latitude]},
        'properties': props,
      };

  Map<String, dynamic> _collection(List<Map<String, dynamic>> f) => {'type': 'FeatureCollection', 'features': f};

  Future<void> _drawNearbyStops() async {
    if (!styleReady) return;
    await map!.setGeoJsonSource(
        'nearby',
        _collection([
          if (to == null && line == null)
            for (final s in nearbyStops)
              {
                ..._point(s.position, {'id': s.id, 'name': titleCase(s.name), 'selected': s.id == filterStop?.id}),
                'id': s.id,
              },
        ]));
  }

  Future<void> _drawEndpoints() async {
    if (!styleReady) return;
    await map!.setGeoJsonSource(
        'endpoints',
        _collection([
          // (On board the origin moves with the bus: no fixed dot.)
          if (to != null && !from.isMyLocation && from.onBoard == null) _point(from.position, {'color': '#43A047'}),
          if (to != null) _point(to!.position, {'color': '#E53935'}),
        ]));
  }

  /// A leg's color: its line's (see line_style.dart), grey for walking.
  String _colorHexFor(Itinerary it, Leg leg) => leg.transit ? leg.colors.color : kWalkColor;

  Color _colorFor(Itinerary it, Leg leg) => hexColor(_colorHexFor(it, leg));

  /// A leg's line on the map. The ride you're on starts at its bus, as
  /// last seen: what is left of it, shorter as the bus moves on.
  List<LatLng> _legPoints(Leg l) {
    final bus = l.onBoard ? _legTrips[l.tripId]?.bus : null;
    if (bus == null) return l.points;
    final left = approachPath(tripPaths[l.tripId] ?? l.points, bus.position, l.to);
    return left.length < 2 ? [bus.position, l.to] : left;
  }

  /// The stops a ride still passes: on the bus you're on, those it hasn't
  /// gone by yet.
  List<TripStop> _viaStops(Leg l) {
    final bus = l.onBoard ? _legTrips[l.tripId]?.bus : null;
    if (bus == null) return l.via;
    final path = tripPaths[l.tripId] ?? l.points;
    return [for (final s in l.via) if (approachPath(path, bus.position, s.position).isNotEmpty) s];
  }

  Future<void> _drawSelected({bool fit = true}) async {
    if (!styleReady) return;
    final it = selected;
    if (it == null) {
      await map!.setGeoJsonSource('route', _collection([]));
      await map!.setGeoJsonSource('via', _collection([]));
      await map!.setGeoJsonSource('stops', _collection([]));
      return;
    }
    await map!.setGeoJsonSource(
        'route',
        _collection([
          for (final l in it.legs)
            {
              'type': 'Feature',
              'geometry': {
                'type': 'LineString',
                'coordinates': [for (final p in _legPoints(l)) [p.longitude, p.latitude]],
              },
              'properties': {'walk': !l.transit, 'color': _colorHexFor(it, l)},
            },
        ]));
    await map!.setGeoJsonSource(
        'via',
        _collection([
          for (final l in it.transitLegs)
            for (final st in _viaStops(l)) _point(st.position, {'color': _colorHexFor(it, l), 'name': titleCase(st.name)}),
        ]));
    await map!.setGeoJsonSource(
        'stops',
        _collection([
          for (final l in it.transitLegs) ...[
            if (!l.onBoard) _point(l.from, {'color': _colorHexFor(it, l)}), // on board: the bus itself
            _point(l.to, {'color': _colorHexFor(it, l)}),
          ],
        ]));
    if (fit) _fitTo([for (final l in it.legs) ...l.points]);
  }

  /// Map area hidden by overlays. The bottom is the sheet's resting height, so
  /// every camera move (fit, center on a leg, recenter) targets the part of the
  /// map you can actually see.
  EdgeInsets _mapInsets() {
    final mq = MediaQuery.of(context);
    // When the sheet covers (almost) everything, keep framing for the
    // half-height sheet: the map is about to be revealed at that size anyway.
    final h = sheet.extent > 0 ? sheet.extent : mq.size.height * 0.5;
    final bottom = math.min(h, mq.size.height * 0.62);
    return EdgeInsets.only(top: mq.padding.top + 64, bottom: bottom);
  }

  /// Whatever the current screen shows on the map.
  List<LatLng> _visibleContent() {
    final it = selected;
    if (it != null) return [for (final l in it.legs) ...l.points];
    if (line?.trip case final t?) return t.points;
    if (to != null) return [from.position, to!.position];
    // Browsing stops: keep the camera where the user put it.
    return const [];
  }

  /// Called when the sheet comes to rest: update the map's insets and reframe.
  Future<void> _onSheetSettled() async {
    final m = map;
    if (m == null || !styleReady) return;
    if (sheetValue == M3EBottomSheetValue.expanded || sheetValue == M3EBottomSheetValue.fullScreen) return;
    // Glide to the new visible area instead of jumping (the inset change
    // itself moves the map's centre)...
    await m.updateContentInsets(_mapInsets(), true);
    final pts = _visibleContent();
    if (pts.isEmpty) return;
    // ...then reframe once that glide is done: starting a camera animation
    // right away would cancel it and bring the jump back.
    await Future<void>.delayed(const Duration(milliseconds: 320));
    if (!mounted) return;
    if (pts.length > 1) {
      _fitTo(pts);
    } else if (pts.length == 1) {
      m.animateCamera(CameraUpdate.newLatLng(pts.first), duration: const Duration(milliseconds: 450));
    }
  }

  void _fitTo(List<LatLng> pts) {
    if (map == null || pts.isEmpty) return;
    var s = pts.first.latitude, n = s, w = pts.first.longitude, e = w;
    for (final p in pts) {
      s = math.min(s, p.latitude);
      n = math.max(n, p.latitude);
      w = math.min(w, p.longitude);
      e = math.max(e, p.longitude);
    }
    // Sheet and status bar are already content insets; this is just breathing room.
    map!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(southwest: LatLng(s, w), northeast: LatLng(n, e)),
        left: 48,
        right: 48,
        top: 32,
        bottom: 32,
      ),
      duration: const Duration(milliseconds: 600),
    );
  }

  // ---------- actions ----------

  void _setDestination(Place p) {
    _leaving(_View.journeys);
    HapticFeedback.mediumImpact();
    // Routes need room: lift the sheet if it was lowered to just the search bar.
    if (sheetValue == M3EBottomSheetValue.preview) sheet.animateTo(M3EBottomSheetValue.collapsed);
    // A line on screen would hide the journeys: leave it.
    if (line != null) _closeLine();
    _deselect();
    setState(() {
      to = p;
      filterStop = null;
    });
    toSearch.text = p.name;
    _drawNearbyStops();
    _drawEndpoints();
    _fitTo([from.position, p.position]);
    _plan();
  }

  Future<void> _setOrigin(Place p) async {
    if (p.isMyLocation) {
      if (here == null) return;
      p = _myLocation(here!);
    }
    _deselect();
    setState(() {
      from = p;
      // On a bus you leave now: a chosen time doesn't apply.
      if (p.onBoard != null) {
        planTime = null;
        planArriveBy = false;
      }
    });
    fromSearch.text = p.name;
    _drawEndpoints();
    if (to != null) _plan();
  }

  void _clearDestination() {
    _deselect();
    setState(() {
      to = null;
      routes = [];
      _routeItineraries = [];
      error = null;
    });
    _syncLegTopics(); // nothing left to follow
    toSearch.clear();
    _drawNearbyStops();
    _drawEndpoints();
    _refreshArea(silent: true);
  }

  void _select(Itinerary it) {
    HapticFeedback.selectionClick();
    // A maximized sheet would hide the trip: bring it down so map and legs share the screen.
    if (sheetValue == M3EBottomSheetValue.expanded || sheetValue == M3EBottomSheetValue.fullScreen) {
      sheet.animateTo(M3EBottomSheetValue.collapsed);
    }
    // Rebuild the swipeable trip from the planner's original, with the rides
    // the walk rules replaced still walked by default.
    final v = TripVariants(it.base ?? it,
        walks: walkCache,
        walkSlots: it.walkSlots,
        choices: it.rideChoices,
        policy: appSettings.walkPolicy,
        when: _planWhen);
    setState(() {
      variants = v;
      selected = v.current;
    });
    _syncLegTopics();
    _loadTripPaths(v.current);
    _drawSelected();
    _fetchTripWalks(v, all: true);
  }

  /// Fetches walking routes the trip shows estimated, and (with [all]) every
  /// leg's walk option for the swipe; then recomposes with real routes.
  Future<void> _fetchTripWalks(TripVariants v, {bool all = false}) async {
    final cache = walkCache;
    if (cache == null) return;
    await cache.fetch([
      ...v.missingWalks,
      if (all)
        for (var s = 0; s < v.slotCount; s++)
          if (v.walkIndex(s) != null) v.slotSpan(s),
    ], max: 8);
    if (!mounted || selected == null) return;
    // Live times may have rebuilt the journey meanwhile: the one open now.
    v = variants ?? v;
    final missed = selected!.missedConnection;
    v.refresh();
    // The real walk turned out too long to make a connection: back to rides
    // (unless the live times already break it: nothing to go back to).
    if (!v.feasible && !missed) v.restore(v.defaults);
    setState(() => selected = missed && !v.feasible ? v.current.withMissedConnection() : v.current);
    _syncLegTopics();
    _drawSelected(fit: false);
  }

  /// User swiped a leg to another ride: recompose the trip, keep the camera.
  void _swapRide(int slot, int variant) {
    final v = variants;
    if (v == null) return;
    final kept = v.choose(slot, variant);
    setState(() => selected = v.current);
    _syncLegTopics();
    _loadTripPaths(v.current);
    _drawSelected(fit: false);
    // A new walk (e.g. two walked legs merged) may need its street route.
    if (v.missingWalks.isNotEmpty) _fetchTripWalks(v);
    if (!kept) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(context.l10n.connectionResetSnack)));
    }
  }

  void _deselect() {
    if (selected == null) return;
    setState(() {
      selected = null;
      variants = null;
    });
    tracker.clear();
    _syncLegTopics(); // back to following the whole list
    tripPaths.clear();
    _drawApproach();
    _drawSelected();
  }

  void _recenter() {
    final p = here;
    if (p != null) map?.animateCamera(CameraUpdate.newLatLngZoom(p, 15.5));
  }

  // ---------- search ----------

  /// A search result or favourite: icon by kind, timetable button for stops,
  /// star to (un)favourite; tap sets it as origin / destination.
  Widget _placeTile(M3ESearchController c, Place p, {required bool isFrom}) {
    final cs = Theme.of(context).colorScheme;
    final isStop = p.kind == PlaceKind.stop;
    return ListTile(
      leading: isStop
          ? Icon(Icons.directions_bus_filled_rounded, color: cs.primary)
          : Icon(p.kind == PlaceKind.address ? Icons.home_outlined : Icons.place_outlined, color: cs.onSurfaceVariant),
      title: Text(p.name),
      subtitle: Text(
        [
          if (isStop && p.stopId != null) stopCodeFromId(p.stopId!),
          placeKindLabel(context.l10n, p.kind),
          ?p.subtitle,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (isStop && p.stopId != null)
          M3EIconButton(
            icon: const Icon(Icons.departure_board_rounded),
            tooltip: context.l10n.departuresFromThisStop,
            variant: M3EIconButtonVariant.tonal,
            onPressed: () {
              c.closeView(isFrom ? from.name : (to?.name ?? ''));
              _openStopTimetable(p);
            },
          ),
        ListenableBuilder(
          listenable: favorites,
          builder: (context, _) {
            final fav = favorites.isFavorite(p);
            return M3EIconButton(
              icon: Icon(fav ? Icons.star_rounded : Icons.star_outline_rounded, color: fav ? cs.primary : null),
              tooltip: fav ? context.l10n.removeFavourite : context.l10n.addFavourite,
              variant: M3EIconButtonVariant.standard,
              onPressed: () async {
                HapticFeedback.selectionClick();
                final place = await _located(p);
                if (place != null) favorites.toggle(place);
              },
            );
          },
        ),
      ]),
      onTap: () async {
        c.closeView(p.name);
        final place = await _located(p);
        if (place == null || !mounted) return;
        isFrom ? _setOrigin(place) : _setDestination(place);
      },
    );
  }

  /// [p] with its position: a search suggestion is located first. Null
  /// (and a message) when that fails.
  Future<Place?> _located(Place p) async {
    if (!p.needsLocating) return p;
    if (backend.places case final PlaceLocator locator) {
      final l = context.l10n;
      final messenger = ScaffoldMessenger.of(context);
      try {
        return await locator.locate(p);
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text(l.searchFailed('$e'))));
        return null;
      }
    }
    return p;
  }

  /// The geocoder returns one result per stop *name*; the pole across the
  /// road (other direction) has the same name and is left out. For the first
  /// few bus/tram stop results, look up same-name stops within ~150 m (one
  /// small area request each, in parallel) and list each right after it.
  Future<List<Place>> _withTwinStops(List<Place> results) async {
    final candidates = results.where((p) => p.kind == PlaceKind.stop && !p.station && p.stopId != null).take(5).toList();
    final twins = <String, List<Place>>{};
    await Future.wait(candidates.map((p) async {
      try {
        const dLat = 0.0014, dLon = 0.0019; // ~150 m
        final near = await backend.stops.stopsInArea(
          LatLngBounds(
            southwest: LatLng(p.position.latitude - dLat, p.position.longitude - dLon),
            northeast: LatLng(p.position.latitude + dLat, p.position.longitude + dLon),
          ),
          from: p.position,
        );
        twins[p.stopId!] = [
          for (final s in near)
            if (s.id != p.stopId && s.name.toUpperCase() == p.name.toUpperCase())
              Place(name: s.name, subtitle: p.subtitle, position: s.position, kind: PlaceKind.stop, stopId: s.id),
        ];
      } catch (_) {
        // no twins: the single result stays
      }
    }));
    return [
      for (final p in results) ...[p, ...?twins[p.stopId]],
    ];
  }

  Future<Iterable<Widget>> _suggestions(M3ESearchController c, {required bool isFrom}) async {
    final q = c.text.trim();
    final cs = Theme.of(context).colorScheme;
    final l = context.l10n; // also after the awaits below
    final items = <Widget>[
      if (isFrom && here != null)
        ListTile(
          leading: Icon(Icons.my_location_rounded, color: cs.primary),
          title: Text(context.l10n.myLocation),
          onTap: () {
            c.closeView(context.l10n.myLocation);
            _setOrigin(_myLocation(here ?? _fallback.position));
          },
        ),
    ];
    // Nothing typed yet (empty, or still the field's current value):
    // favourites, as Stops and Destinations.
    if (q.isEmpty || q == context.l10n.myLocation || q == to?.name || (isFrom && q == from.name)) {
      for (final (title, list) in [
        (context.l10n.favouriteStops, favorites.stops),
        (context.l10n.favouriteDestinations, favorites.destinations),
      ]) {
        if (list.isEmpty) continue;
        items.add(_SuggestionHeader(title));
        items.addAll(list.map((p) => _placeTile(c, p, isFrom: isFrom)));
      }
      return items;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (c.text.trim() != q) return items; // a newer query is on its way
    // A line with buses running right now ("492", "n6"): open the line
    // view. Asked to Tramite, exact number, for each source it covers.
    if (!isFrom && q.length <= 6 && !q.contains(' ') && backend.trips != null && tramite.prefixes.isNotEmpty) {
      final found = await Future.wait([
        for (final p in tramite.prefixes)
          // A friendly name ("MA") finds its line ("MEA").
          if (TramiteClient.lineId(p, lineOverrides.lineOfFriendlyName(p, q) ?? q) case final id)
            tramite.lineVehicles(id).then((buses) => (id: id, buses: buses))
              .catchError((Object _) => (id: '', buses: <({Vehicle vehicle, String? color})>[])),
      ]);
      if (c.text.trim() != q) return items;
      for (final (:id, :buses) in found) {
        if (buses.isEmpty) continue;
        final first = buses.first.vehicle;
        final name = first.routeShortName ?? q;
        final colors = lineColors(mode: first.mode, line: name, id: id, color: buses.first.color);
        items.add(ListTile(
          leading: LinePill.of(line: lineName(name, id: id), mode: first.mode, colors: colors),
          title: Text(l.lineName(lineName(name, id: id))),
          subtitle: Text(l.busesLive(buses.length)),
          onTap: () {
            c.closeView('');
            _openLine(name: name, mode: first.mode, lineId: id);
          },
        ));
      }
    }
    if (q.length < 2) return items;
    try {
      final reference = here ?? map?.cameraPosition?.target ?? _fallback.position;
      final ranked = rankByProximity(await backend.places.search(q, near: reference), reference);
      // A typed stop number means that exact pole: no twins then.
      final results = RegExp(r'^\d+$').hasMatch(q) ? ranked : await _withTwinStops(ranked);
      if (c.text.trim() != q) return items;
      // Stops are distinct by stop id (each pole is one direction); other
      // results drop exact duplicates (same name and label).
      final seen = <String>{};
      // A list: walked twice (tiles, credits), and the filter adds to [seen].
      final unique = results.where((p) => seen.add(p.stopId ?? '${p.name}|${p.subtitle}')).toList();
      // Stop names come in capitals; addresses and places as written.
      items.addAll(unique.map((p) => _placeTile(
            c,
            p.kind != PlaceKind.stop
                ? p
                : Place(
                    name: titleCase(p.name),
                    subtitle: p.subtitle,
                    position: p.position,
                    kind: p.kind,
                    stopId: p.stopId,
                    station: p.station,
                  ),
            isFrom: isFrom,
          )));
      // Credit the place search where its data is shown, as it requires.
      for (final credit in {for (final p in unique) ?p.credit}) {
        items.add(_SearchCredit(credit));
      }
    } catch (e) {
      items.add(ListTile(title: Text(l.searchFailed('$e'))));
    }
    return items;
  }

  Widget _searchArea() {
    final expanded = sheetValue == M3EBottomSheetValue.expanded || sheetValue == M3EBottomSheetValue.fullScreen;
    return RoutePicker(
      expanded: expanded,
      fromSearch: fromSearch,
      toSearch: toSearch,
      fromLabel: from.name,
      toLabel: to?.name,
      fromIsMyLocation: from.isMyLocation,
      fromSuggestions: (_, c) => _suggestions(c, isFrom: true),
      toSuggestions: (_, c) => _suggestions(c, isFrom: false),
      planTime: _planWhen,
      timeLocked: from.onBoard != null,
      onTimeLocked: () => ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(context.l10n.timeUnavailableOnBoard))),
      onOpen: () => sheet.animateTo(M3EBottomSheetValue.expanded),
      onPlanTimeChanged: (p) {
        setState(() {
          planTime = p.time;
          planArriveBy = p.arriveBy;
        });
        _plan();
      },
      onClear: _clearDestination,
      onSwap: _swap,
    );
  }

  void _swap() {
    final dest = to;
    // A bus you're on can't be where you go.
    if (dest == null || from.onBoard != null) return;
    final origin = from;
    _deselect();
    setState(() {
      from = dest;
      to = origin;
    });
    fromSearch.text = dest.name;
    toSearch.text = origin.name;
    _drawEndpoints();
    _plan();
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    // Content changes can change the sheet's height too.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _followSheet();
    });
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: selected == null && to == null && line == null && filterStop == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
            .copyWith(statusBarColor: Colors.transparent, systemNavigationBarColor: Colors.transparent),
        child: Scaffold(
          backgroundColor: cs.surface,
          body: Stack(children: [
            MapLibreMap(
              key: ValueKey(isDark),
              styleString: isDark ? kMapStyleDark : kMapStyleLight,
              initialCameraPosition: CameraPosition(target: here ?? _fallback.position, zoom: 15.5),
              onMapCreated: (c) {
                map = c;
                if (_lastFix case final f?) _showWebPuck(f); // a new map (e.g. dark mode)
                styleReady = false;
                _badged = null; // nor a cone filter
              },
              onStyleLoadedCallback: _onStyleLoaded,
              onCameraIdle: _onCameraIdle,
              // Zooming changes which buses are dots: their cones follow.
              onCameraMove: (_) => _checkCones(),
              // Keeps controller.cameraPosition (centre, zoom) current; the
              // area logic reads it after every move.
              trackCameraPosition: true,
              onMapLongClick: _onMapLongPress,
              myLocationEnabled: locationGranted,
              // Which way the phone faces: MapLibre's own heading marker on
              // the location dot (Android, iOS; nothing on web).
              myLocationRenderMode: locationGranted && !kIsWeb ? MyLocationRenderMode.compass : MyLocationRenderMode.normal,
              // On web the platform source is MapLibre's GeolocateControl, which
              // brings its own button; feed it Geolocator's fixes instead.
              locationSource: kIsWeb ? const ManualLocationSource() : const PlatformLocationSource(),
              compassEnabled: false,
              attributionEnabled: false, // replaced by MapCredit
            ),
            // Credit and center button: in the bottom corners when the sheet
            // leaves room beside it (wide screens), else right above it.
            ValueListenableBuilder<double>(
              valueListenable: _sheetTop,
              builder: (context, top, child) {
                final size = MediaQuery.sizeOf(context);
                if ((size.width - math.min(size.width, kSheetMaxWidth)) / 2 >= _kCornerSpace) {
                  return Positioned(left: 0, right: 0, bottom: MediaQuery.paddingOf(context).bottom, child: child!);
                }
                return top > size.height * 0.6
                    ? const SizedBox.shrink() // sheet up: nothing to sit on
                    : Positioned(left: 0, right: 0, bottom: top, child: child!);
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 12, 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  const MapCredit(),
                  const Spacer(),
                  if (here != null)
                    AnimatedScale(
                      scale: _centeredOnMe ? 0 : 1,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutBack,
                      child: _PointerShield(
                        child: M3EIconButton(
                          icon: const Icon(Icons.my_location_rounded),
                          tooltip: context.l10n.myLocation,
                          variant: M3EIconButtonVariant.tonal,
                          size: M3EIconButtonSize.md,
                          onPressed: _centeredOnMe ? null : _recenter,
                        ),
                      ),
                    ),
                ]),
              ),
            ),
            // Settings, top left; not while the on-board toolbar is up there.
            if (from.onBoard == null && _boardQuestion == null)
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 0, 0),
                  child: _PointerShield(
                    child: M3EIconButton(
                      icon: const Icon(Icons.person_rounded),
                      tooltip: context.l10n.settingsTitle,
                      variant: M3EIconButtonVariant.tonal,
                      size: M3EIconButtonSize.md,
                      onPressed: _openSettings,
                    ),
                  ),
                ),
              ),
            // On board (or asked whether you are): floating toolbar on top.
            if (from.onBoard case final ride?)
              Positioned.fill(
                // (The toolbar's own safeArea flag leaves it under the status bar.)
                child: SafeArea(
                  child: OnBoardBar(line: lineName(ride.line), mode: ride.mode, headsign: ride.headsign, onLeave: _leaveBoard),
                ),
              )
            else if (_boardQuestion case final q?)
              Positioned.fill(
                child: SafeArea(
                  child: BoardQuestionBar(
                  line: lineName(q.vehicle.routeShortName ?? '', id: q.vehicle.backendTripId),
                  mode: q.vehicle.mode,
                  onYes: () => _answerBoarding(true),
                  onNo: () => _answerBoarding(false),
                  ),
                ),
              ),
            // Web: the map is a DOM element under Flutter's canvas and would
            // also get the pointer events meant for the sheet (dragging it
            // panned the map). An empty element over the map, where the sheet
            // is, takes them instead; they still reach Flutter.
            if (kIsWeb)
              ValueListenableBuilder<double>(
                valueListenable: _sheetTop,
                builder: (context, top, _) {
                  final w = MediaQuery.sizeOf(context).width;
                  return Positioned(
                    left: (w - math.min(w, kSheetMaxWidth)) / 2,
                    width: math.min(w, kSheetMaxWidth),
                    bottom: 0,
                    height: top,
                    child: const _PointerShield(),
                  );
                },
              ),
            Positioned.fill(
              // Touching the sheet may drag it: follow its height meanwhile.
              child: Listener(
                onPointerDown: (_) {
                  _sheetTouched = true;
                  _followSheet();
                },
                onPointerUp: (_) => _sheetTouched = false,
                onPointerCancel: (_) => _sheetTouched = false,
                child: M3EBottomSheet.standard(
                  controller: sheet,
                  // Nothing to reveal when only the search bar is shown.
                  enableDrag: !_onlySearchBar,
                  previewHeight: kSheetPeek + MediaQuery.paddingOf(context).bottom,
                  initialValue: M3EBottomSheetValue.collapsed,
                  onValueChanged: (v) {
                    setState(() => sheetValue = v);
                    _onSheetSettled();
                  },
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.depth != 0) return false;
                      _directionsFab.handleScrollNotification(n);
                      if (n is ScrollEndNotification && n.metrics.pixels <= n.metrics.minScrollExtent) {
                        _directionsFab.expand(); // back at the top: label again
                      }
                      return false;
                    },
                    child: CustomScrollView(slivers: [
                      if (selected == null && line == null && filterStop == null) SliverToBoxAdapter(child: _searchArea()),
                      ..._content(),
                      // The floating Directions button must not hide the last row.
                      SliverToBoxAdapter(
                        child: SizedBox(
                            height: 24 + MediaQuery.paddingOf(context).bottom + (_stopDirections != null ? kFabRoom : 0)),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
            // Stop view: Directions to the stop, floating at the bottom
            // right of the sheet. Not at the sheet's lowest height, where
            // it would sit on the stop's name.
            if (_stopDirections case final dest? when sheetValue != M3EBottomSheetValue.preview)
              Positioned(
                right: (MediaQuery.sizeOf(context).width - math.min(MediaQuery.sizeOf(context).width, kSheetMaxWidth)) / 2 + 16,
                bottom: MediaQuery.paddingOf(context).bottom + 16,
                child: M3EExtendedFab(
                  label: context.l10n.directions,
                  icon: const Icon(Icons.directions_rounded),
                  controller: _directionsFab,
                  appear: true,
                  onPressed: () => _setDestination(dest),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  /// Which section a route goes in, by how sure each ride's time is:
  ///  * live: every ride is on its way or waiting to start (green, yellow);
  ///    the metro counts as live (no feed, but frequent and reliable);
  ///  * predicted: some ride's time is our estimate (red, purple);
  ///  * scheduled: the rest (some ride is timetable only).
  /// A journey that misses a connection stays where its rides put it (the
  /// section says how sure the times are, not whether they can be made).
  String _routeKind(RouteGroup g) => _journeyKind(g.best);

  String _journeyKind(Itinerary it) {
    if (it.walkOnly) return 'walk';
    final sure = [
      for (final l in it.transitLegs) l.mode == 'SUBWAY' ? Certainty.moving : _certainty(l.realtime, l.tripId),
    ];
    if (sure.every((c) => c == Certainty.moving || c == Certainty.waiting)) return 'live';
    if (sure.any((c) => c == Certainty.estimated || c == Certainty.returning)) return 'predicted';
    return 'scheduled';
  }

  /// Like [_certainty], also from the buses on the map (the line view's,
  /// whose trips aren't rides of a journey): live with its bus seen is on
  /// its way, or waiting while the bus hasn't started.
  Certainty _trackedCertainty(bool realtime, String? tripId) {
    final bus = tripId == null ? null : tracker.buses[tripId]?.vehicle;
    if (realtime && bus != null && _legTrips[tripId] == null) return bus.started ? Certainty.moving : Certainty.waiting;
    return _certainty(realtime, tripId);
  }

  /// Zoomed out on the stops view: the sheet holds just the search bar.
  bool get _onlySearchBar => selected == null && to == null && line == null && filterStop == null && zoomedOut;

  List<Widget> _content() {
    if (line case final l?) {
      return lineSlivers(
        context,
        l,
        color: hexColor(l.colors.color),
        liveBuses: _lineTopics.topics.isEmpty ? null : tracker.buses.length,
        certainty: l.live?.certainty ?? _trackedCertainty(l.trip?.realtime ?? false, MotisClient.rawTripId(l.tripId)),
        onBack: _goBack,
        onSwitchDirection: _otherDirection() == null ? null : () => _loadLineTrip(_otherDirection()!),
        onStopTap: _openLineStop,
        bus: tracker.buses[MotisClient.rawTripId(l.tripId)]?.vehicle,
        others: [for (final b in tracker.buses.values) b.vehicle],
      );
    }
    if (selected != null) return _tripSlivers(selected!);
    if (to != null) return _routeSlivers();
    if (zoomedOut && filterStop == null) return const []; // only the search bar
    return _nearbySlivers();
  }

  Widget _errorBox(String e) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(e, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      );

  /// Top of the stop view: back to the view it was opened from, the stop's
  /// name, number and distance, and its star. Directions float at the
  /// bottom of the sheet (see [_stopDirections]).
  Widget _stopHeader(Stop stop) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final away = here == null ? null : distanceMeters(here!, stop.position);
    final place = Place(name: titleCase(stop.name), position: stop.position, kind: PlaceKind.stop, stopId: stop.id);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          M3EIconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: context.l10n.back,
            variant: M3EIconButtonVariant.standard,
            onPressed: _goBack,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(titleCase(stop.name),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: emphasized(context).titleMedium.copyWith(color: cs.onSurface)),
              Text(
                [context.l10n.stopNumber(stop.code), if (away != null) _distanceLabel(away)].join(' · '),
                style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            ]),
          ),
          if (nearbyLoading && nearby.isNotEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(width: 24, height: 24, child: M3ELoadingIndicator(size: 24)),
            ),
          // Favourite this exact stop (same store as the stars in search).
          ListenableBuilder(
            listenable: favorites,
            builder: (context, _) {
              final fav = favorites.isFavorite(place);
              return M3EIconButton(
                icon: Icon(fav ? Icons.star_rounded : Icons.star_outline_rounded, color: fav ? cs.primary : null),
                tooltip: fav ? context.l10n.removeFavourite : context.l10n.addFavourite,
                variant: M3EIconButtonVariant.standard,
                onPressed: () {
                  HapticFeedback.selectionClick();
                  favorites.toggle(place);
                },
              );
            },
          ),
        ]),
      ]),
    );
  }

  /// Where the floating Directions button of the stop view goes: the stop,
  /// when it's not where you are; else null (no button).
  Place? get _stopDirections {
    final stop = filterStop, me = here;
    if (stop == null || line != null || to != null || me == null) return null;
    if (distanceMeters(me, stop.position) <= kStopDirectionsMeters) return null;
    return Place(name: titleCase(stop.name), position: stop.position, kind: PlaceKind.stop, stopId: stop.id);
  }

  /// "650 m", "1.2 km" (in the app's language).
  String _distanceLabel(double meters) => meters < 1000
      ? context.l10n.distanceMeters(meters.round())
      : context.l10n.distanceKm((meters / 1000).toStringAsFixed(1).replaceAll('.', context.l10n.decimalSeparator));

  List<Widget> _nearbySlivers() {
    return [
      if (filterStop case final stop?)
        SliverToBoxAdapter(child: _stopHeader(stop))
      else
        SliverToBoxAdapter(
          child: SheetSectionHeader(
            areaMode
                ? context.l10n.departuresInArea
                : here == null
                    ? context.l10n.departuresNearTermini
                    : context.l10n.departuresNearYou,
            trailing: nearbyLoading && nearby.isNotEmpty
                ? const SizedBox(width: 24, height: 24, child: M3ELoadingIndicator(size: 24))
                : null,
          ),
        ),
      if (error != null) _errorBox(error!),
      if (nearbyLoading && nearby.isEmpty)
        SliverToBoxAdapter(child: SheetLoading(label: filterStop != null ? context.l10n.loadingDepartures : context.l10n.findingStops))
      else if (nearby.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(filterStop != null
                ? context.l10n.noDeparturesFromStop
                : nearbyStops.isEmpty
                    ? context.l10n.noStopsInArea
                    : context.l10n.noDeparturesHere),
          ),
        )
      else ...[
        // Live first (backed by a real bus: on its way, parked, or coming
        // back around), then timetable-only; each keeps the soonest-first
        // order.
        for (final (live, list) in [
          (true, nearby.where((r) => _depCertainty(r.next.first) != Certainty.scheduled).toList()),
          (false, nearby.where((r) => _depCertainty(r.next.first) == Certainty.scheduled).toList()),
        ])
          if (list.isNotEmpty) ...[
            SliverToBoxAdapter(child: RouteSectionLabel(live: live, count: list.length)),
            M3EList.sliver(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: list.length,
              itemBuilder: (_, i) =>
                  NearbyDepartureRow(
                    row: list[i],
                    certainty: _depCertainty(list[i].next.first),
                    showStop: filterStop == null,
                  ),
              onTap: (i) {
                final d = list[i].next.first;
                _openLine(
                  name: list[i].line,
                  mode: list[i].mode,
                  tripId: d.backendTripId,
                  hint: d.stopId == null ? null : (stopId: d.stopId!, at: d.time),
                );
              },
            ),
          ],
      ],
    ];
  }

  List<Widget> _routeSlivers() {
    return [
      SliverToBoxAdapter(
        child: SheetSectionHeader(
          context.l10n.routesByArrival(routes.where((g) => g.hiddenBecause == null).length),
          trailing: planning && routes.isNotEmpty
              ? const SizedBox(width: 24, height: 24, child: M3ELoadingIndicator(size: 24))
              : M3EIconButton(
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: context.l10n.refresh,
                  variant: M3EIconButtonVariant.standard,
                  onPressed: planning ? null : () => _plan(),
                ),
        ),
      ),
      if (error != null) _errorBox(error!),
      if (planning && routes.isEmpty)
        SliverToBoxAdapter(child: SheetLoading(label: context.l10n.comparingRoutes))
      else ...[
        // Walking suggested ("Faster on foot") first, then live, predicted,
        // timetable-only, then walking when it isn't competitive; each list
        // keeps the ranking order.
        for (final (label, list) in [
          (null, routes.where((g) => g.tags.contains(RouteTag.onFoot)).toList()),
          ('live', _shown('live')),
          ('predicted', _shown('predicted')),
          ('scheduled', _shown('scheduled')),
          ('walk', routes.where((g) => g.isWalk && !g.tags.contains(RouteTag.onFoot)).toList()),
        ])
          if (list.isNotEmpty || _hidden(label).isNotEmpty) ...[
            if (label != null)
              SliverToBoxAdapter(
                child: RouteSectionLabel(
                    live: label == 'live', predicted: label == 'predicted', onFoot: label == 'walk', count: list.length),
              )
            else
              const SliverToBoxAdapter(child: SizedBox(height: 4)),
            _routeList(list, _hidden(label)),
          ],
      ],
    ];
  }

  /// Journeys listed normally in a section (live, predicted, scheduled).
  List<RouteGroup> _shown(String kind) =>
      routes.where((g) => !g.isWalk && g.hiddenBecause == null && _routeKind(g) == kind).toList();

  /// Journeys of a section under "show more" (see checkStayingOn).
  List<RouteGroup> _hidden(String? kind) => kind == null || kind == 'walk'
      ? const []
      : routes.where((g) => !g.isWalk && g.hiddenBecause != null && _routeKind(g) == kind).toList();

  /// A section's journeys; those staying on a bus would beat end in one
  /// expandable "N more journeys" item, each saying which line already
  /// takes you there.
  Widget _routeList(List<RouteGroup> list, List<RouteGroup> hidden) {
    Widget row(RouteGroup g) => RouteGroupRow(
          group: g,
          colorFor: _colorFor,
          certaintyFor: (l) => _certainty(l.realtime, l.tripId),
        );
    return M3EList.sliver(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: list.length + (hidden.isEmpty ? 0 : 1),
      itemBuilder: (context, i) {
        if (i < list.length) return row(list[i]);
        final cs = Theme.of(context).colorScheme;
        return M3EListItem(
          headline: context.l10n.moreJourneys(hidden.length),
          leading: const Icon(Icons.unfold_more_rounded),
          expanded: M3EExpandableExpanded.list(
            M3EList(
              embedded: true,
              itemCount: hidden.length,
              itemBuilder: (context, j) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                  child: Row(children: [
                    Icon(Icons.event_seat_rounded, size: 16, color: cs.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        context.l10n.hiddenJourneyReason(lineName(hidden[j].hiddenBecause!.line),
                            hm(hidden[j].hiddenBecause!.arrival), hidden[j].hiddenBecause!.changesSaved),
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ),
                  ]),
                ),
                row(hidden[j]),
              ]),
              onTap: (j) => _select(hidden[j].best),
            ),
          ),
        );
      },
      onTap: (i) {
        if (i < list.length) _select(list[i].best);
      },
    );
  }

  /// The line under a selected journey's header: how many of its rides
  /// have their bus on the map.
  String _tripStatus(Itinerary it, int? feedAge) {
    final l = context.l10n;
    if (it.transitLegs.isEmpty) return l.tripWalkingOnly;
    final covered = it.transitLegs.where((leg) => tramite.covers(leg.backendTripId)).length;
    if (covered == 0) return l.tripNoLivePositions;
    if (!live.connected.value) return l.tripLivePositionsUnavailable;
    return [l.tripTracking(tracker.buses.length, covered), if (feedAge != null) l.tripPositionsAge(feedAge)].join(' · ');
  }

  /// On the bus you're on: how many stops before the one you get off at,
  /// by where Tramite sees the bus now. Null otherwise (the leg's own count).
  int? _stopsLeft(Leg l) {
    final trip = l.onBoard ? _legTrips[l.tripId] : null;
    final seq = trip?.busSequence;
    if (trip == null || seq == null) return null;
    final ahead = trip.stops.indexWhere((s) => s.sequence >= seq);
    final off = ahead < 0 ? null : trip.visit(l.toStopId, l.scheduledEnd, from: ahead, arrival: true);
    return off == null ? null : off - ahead;
  }

  List<Widget> _tripSlivers(Itinerary it) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final feedAge = tracker.lastFeed == null ? null : DateTime.now().difference(tracker.lastFeed!).inSeconds;
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 24, 8),
          child: Row(children: [
            M3EIconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              tooltip: context.l10n.backToRoutes,
              variant: M3EIconButtonVariant.standard,
              onPressed: _deselect,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Semantics(
                  label: context.l10n.fromToSemantics(hm(it.start), hm(it.end)),
                  excludeSemantics: true,
                  child: Row(children: [
                    Text(hm(it.start), style: emphasized(context).headlineSmall.copyWith(color: cs.onSurface)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(Icons.arrow_forward_rounded, size: 22, color: cs.onSurfaceVariant),
                    ),
                    Text(hm(it.end), style: emphasized(context).headlineSmall.copyWith(color: cs.onSurface)),
                  ]),
                ),
                Text(
                  context.l10n.tripSummary(it.duration.inMinutes, it.transfers, to?.name ?? ''),
                  overflow: TextOverflow.ellipsis,
                  style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
              ]),
            ),
          ]),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              _tripStatus(it, feedAge),
              style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            // Its times can't be made any more (a missed connection, or the
            // first stop out of reach): the next bus is a swipe away.
            if (it.missedConnection || it.lateForFirstRide(DateTime.now())) ...[
              const SizedBox(height: 4),
              MissedWarning(it, live: _journeyKind(it) == 'live'),
            ],
                      // A bus swiped to that leaves before the time chosen: say so.
            if (_leavesEarly(it) case final minutes?) ...[
              const SizedBox(height: 4),
              Row(children: [
                Icon(Icons.schedule_rounded, size: 16, color: cs.tertiary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    context.l10n.leaveEarlierNote(hm(it.start), minutes),
                    style: tt.labelLarge?.copyWith(color: cs.tertiary),
                  ),
                ),
              ]),
            ],
          ]),
        ),
      ),
      M3EList.sliver(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: it.legs.length,
        itemBuilder: (_, i) {
          final l = it.legs[i];
          // Minutes until this vehicle reaches its boarding stop. (The gap
          // between arriving on foot and boarding is ~0 by construction: the
          // planner times walks to end when the bus comes.)
          final wait = l.transit && !l.onBoard ? minutesUntil(l.start) : null; // nothing to catch on board
          final row = LegRow(
            leg: l,
            stopsLeft: _stopsLeft(l),
            color: _colorFor(it, l),
            bus: tracker.buses[l.tripId],
            waitMinutes: wait,
            certainty: _trackedCertainty(l.realtime, l.tripId),
          );
          final v = variants;
          final slot = v?.slotOfLeg(i);
          if (v == null || slot == null || v.variantCount(slot) < 2) return row;
          return SwipeSlot(
            index: v.choiceOf(slot),
            count: v.variantCount(slot),
            labels: [
              for (var k = 0; k < v.variantCount(slot); k++)
                v.isWalk(slot, k)
                    ? context.l10n.swipeWalk(v.walkDurationOf(slot).inMinutes)
                    : '${v.rideOf(slot, k).label} ${hm(v.rideOf(slot, k).start)}',
            ],
            onChanged: (k) => _swapRide(slot, k),
            child: row,
          );
        },
        onTap: (i) {
          final l = it.legs[i];
          final bus = tracker.buses[l.tripId];
          map?.animateCamera(CameraUpdate.newLatLngZoom(bus?.drawn ?? l.from, 16));
        },
      ),
    ];
  }
}

/// Section title in the search view ("Stops", "Destinations").
/// The place search's credit under its results ("Google Maps"), as it
/// asks: not translated, not wrapped.
class _SearchCredit extends StatelessWidget {
  const _SearchCredit(this.credit);
  final String credit;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Align(
        alignment: Alignment.centerRight,
        child: Text(credit, style: t, maxLines: 1, softWrap: false),
      ),
    );
  }
}

class _SuggestionHeader extends StatelessWidget {
  const _SuggestionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
        child: Text(title, style: emphasized(context).labelLarge.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}

/// Web only: an invisible DOM element, behind [child] (or alone, filling its
/// space), that keeps pointer events from reaching the map element beneath
/// it; Flutter still gets them. Otherwise the map handles them too: a tap on
/// a button over it stops the camera move the button just started.
class _PointerShield extends StatelessWidget {
  const _PointerShield({this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return child ?? const SizedBox.shrink();
    final shield = HtmlElementView.fromTagName(tagName: 'div', isVisible: false);
    final c = child;
    if (c == null) return shield;
    return Stack(children: [Positioned.fill(child: shield), c]);
  }
}

/// What the sheet shows: the plain map's departures, one stop's, the
/// journeys to a destination, or a line.
enum _View { browse, stop, journeys, line }
