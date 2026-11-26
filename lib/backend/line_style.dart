/// How a line looks everywhere in the app (map, journeys, line view,
/// departures): its colour and the name passengers use. The same rule for
/// every backend:
///
/// 1. a route override from Tramite (its config, see [lineOverrides]);
/// 2. else the feed's own colour (GTFS route_color, from Tramite or
///    Transitous);
/// 3. else a default colour for its category (bus, tram, metro, ...).
///
/// The feed's line name stays the line's id inside the app (matching rides
/// across backends); a friendly name is only shown.
library;

import 'dart:math' as math;

/// Default colours by category, when no one says the line's colour.
const kBusColor = '#43A047';
const kTramColor = '#FB8C00';
const kMetroColor = '#1E88E5';
const kTrainColor = '#E53935';
const kFerryColor = '#00897B';

/// The default colour of a ride's category (a MOTIS mode: BUS, TRAM, ...).
/// Anything else (funicular, aerial lift, ...) gets the bus colour.
String categoryColor(String mode) => switch (mode) {
      'TRAM' || 'CABLE_CAR' => kTramColor,
      'SUBWAY' || 'METRO' => kMetroColor,
      'RAIL' ||
      'REGIONAL_RAIL' ||
      'REGIONAL_FAST_RAIL' ||
      'SUBURBAN' ||
      'HIGHSPEED_RAIL' ||
      'LONG_DISTANCE' ||
      'NIGHT_RAIL' =>
        kTrainColor,
      'FERRY' => kFerryColor,
      _ => kBusColor,
    };

/// GTFS route_type (basic or extended) as the MOTIS mode the app uses.
String modeOfRouteType(int? type) => switch (type ?? 3) {
      0 || 5 || (>= 900 && < 1000) => 'TRAM',
      1 || (>= 400 && < 500) => 'SUBWAY',
      2 || (>= 100 && < 200) => 'RAIL',
      4 || 1000 || 1200 => 'FERRY',
      _ => 'BUS',
    };

/// One of Tramite's route overrides (see its config's `routes`).
class RouteOverride {
  RouteOverride({this.line, this.routeId, this.friendlyName, this.color, this.textColor});

  factory RouteOverride.fromJson(Map<String, dynamic> j) => RouteOverride(
        line: j['line'] as String?,
        routeId: j['routeId'] as String?,
        friendlyName: j['friendlyName'] as String?,
        color: j['color'] as String?,
        textColor: j['textColor'] as String?,
      );

  /// The line's short name in the feed ("MEA"), or null for one route.
  final String? line;

  /// One route, prefixed ("it-Lazio-Rome_MEB1").
  final String? routeId;
  final String? friendlyName;

  /// GTFS hex, no "#".
  final String? color;
  final String? textColor;
}

/// Tramite's route overrides, per source prefix ("it-Lazio-Rome"). Set
/// when Tramite says what it covers; empty until then.
final lineOverrides = LineOverrides();

class LineOverrides {
  final _byPrefix = <String, List<RouteOverride>>{};

  void set(Map<String, List<RouteOverride>> byPrefix) => _byPrefix
    ..clear()
    ..addAll(byPrefix);

  /// The source prefix of a stop, route or trip id
  /// (`<date>_<HH:MM>_<prefix>_<trip>` for trips), among those with
  /// overrides.
  String? _prefixOf(String id) {
    final rest = RegExp(r'^\d{8}_\d+:\d{2}_(.*)$').firstMatch(id)?.group(1) ?? id;
    String? best;
    for (final p in _byPrefix.keys) {
      if (rest.startsWith('${p}_') && (best == null || p.length > best.length)) best = p;
    }
    return best;
  }

  /// The override for [line], from the source of [id] (a stop, trip or
  /// route id). Without [id]: from whichever source has one for that line.
  RouteOverride? find(String? line, {String? id, String? routeId}) {
    if (_byPrefix.isEmpty) return null;
    final prefix = id == null ? null : _prefixOf(id);
    if (id != null && prefix == null) return null;
    final lists = prefix == null ? _byPrefix.values : [_byPrefix[prefix]!];
    RouteOverride? byLine;
    for (final list in lists) {
      for (final o in list) {
        if (routeId != null && o.routeId == routeId) return o;
        if (line != null && o.line != null && o.line!.toLowerCase() == line.toLowerCase()) byLine ??= o;
      }
    }
    return byLine;
  }

  /// The feed's line name for [name], when it is someone's friendly name
  /// ("MA" -> "MEA"), in the source [prefix]: for searching by it.
  String? lineOfFriendlyName(String prefix, String name) {
    for (final o in _byPrefix[prefix] ?? const <RouteOverride>[]) {
      if (o.line != null && o.friendlyName?.toLowerCase() == name.toLowerCase()) return o.line;
    }
    return null;
  }
}

/// A line's colours, "#RRGGBB": [color] behind, [text] on it.
typedef LineColors = ({String color, String text});

/// The colours of [line] (a [mode] ride), given what the backend said
/// ([color], [textColor]: GTFS hex, with or without "#") and an [id] of
/// the stop, trip or route to tell its source.
LineColors lineColors({required String mode, String? line, String? color, String? textColor, String? id}) {
  final o = lineOverrides.find(line, id: id);
  String? hex(String? c) => c == null || c.isEmpty ? null : '#${c.replaceFirst('#', '').toUpperCase()}';
  final (bg, fg) = switch ((hex(o?.color), hex(color))) {
    (final String c, _) => (c, hex(o?.textColor) ?? hex(textColor)),
    (null, final String c) => (c, hex(o?.textColor) ?? hex(textColor)),
    _ => (categoryColor(mode), null),
  };
  return (color: bg, text: fg ?? readableOn(bg));
}

/// White or black, whichever reads better on [hex] ("#RRGGBB"): the same
/// threshold as Flutter's ThemeData.estimateBrightnessForColor.
String readableOn(String hex) {
  final v = int.parse(hex.substring(1), radix: 16);
  double ch(int c) {
    final s = c / 255;
    return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  final l = 0.2126 * ch(v >> 16 & 0xFF) + 0.7152 * ch(v >> 8 & 0xFF) + 0.0722 * ch(v & 0xFF);
  return (l + 0.05) * (l + 0.05) > 0.15 ? '#000000' : '#FFFFFF';
}

/// What passengers call [line]: its friendly name when there's one.
String lineName(String line, {String? id}) => lineOverrides.find(line, id: id)?.friendlyName ?? line;
