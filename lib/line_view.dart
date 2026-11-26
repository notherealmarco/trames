import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;

import 'backend/backend.dart';
import 'l10n.dart';
import 'sheet_widgets.dart';

/// What the line view shows: one line, one of its trips (a direction) with
/// path and stops, plus every live bus of the line on the map.
class LineState {
  LineState(this.name, this.mode);
  final String name;
  final String mode;

  /// The line in Tramite (e.g. "it-Lazio-Rome_85"), when it has it.
  String? lineId;

  /// The line's colours (see line_style.dart).
  LineColors get colors => lineColors(
      mode: mode, line: name, color: trip?.routeColor, textColor: trip?.routeTextColor, id: lineId ?? tripId);

  /// [name] as shown (its friendly name).
  String get label => lineName(name, id: lineId ?? tripId);

  /// Trip shown (route + stops); one per direction, see [directions].
  String? tripId;
  TripInfo? trip;

  /// Tramite's view of the shown trip, when it covers it: its times.
  TramiteTrip? live;

  /// The shown trip's stops with the times to show: Tramite's where it has
  /// a live one, else the planner's (see [stopsAtLiveTimes]).
  List<TripStop> get stops {
    final t = trip, seen = live;
    if (t == null) return const [];
    return seen == null ? t.stops : stopsAtLiveTimes(t.stops, matchTripStops(t.stops, seen), arrival: false);
  }

  bool loading = true;
  String? error;

  /// GTFS direction id -> a trip id running that way (from live vehicles).
  Map<int, String> directions = {};

  /// Every live bus of the line, both directions; the map shows the ones
  /// going the way of the shown trip.
  List<({Vehicle vehicle, String? color})> buses = const [];

  /// Where each known trip can be found again if the planner doesn't know
  /// its id (another timetable version; see TripDetails.sameRun).
  Map<String, RunHint> runHints = {};
}

/// Header + stop list for the line view.
List<Widget> lineSlivers(
  BuildContext context,
  LineState s, {
  required Color color,
  /// Live buses of the line on the map; null where the city has no Tramite.
  required int? liveBuses,
  /// How sure the shown trip's live times are (see [certaintyOf]).
  required Certainty certainty,
  required VoidCallback onBack,
  required VoidCallback? onSwitchDirection,
  required ValueChanged<TripStop> onStopTap,
  /// The bus running the shown trip, when it's live: drawn in the stop list.
  Vehicle? bus,
  /// The line's other buses on the map (the shown direction): drawn in the
  /// stop list too, where they are along the shown trip's stops.
  List<Vehicle> others = const [],
}) {
  final cs = Theme.of(context).colorScheme;
  final tt = Theme.of(context).textTheme;
  final trip = s.trip;
  final stops = s.stops;
  final places = <BusOnList>[
    if (trip != null) ...[
      if (bus != null)
        if (busPlaceOnTrip(stops, bus) case final p?) (index: p.index, atStop: p.atStop, color: _busColor(context, certainty)),
      // Another trip's bus: placed by the stop it's at or heading to, which
      // must be on the shown trip (its sequence number is its own trip's).
      for (final v in others)
        if (v.id != bus?.id)
          if (busPlaceOnTrip(stops, v, bySequence: false) case final p?)
            (index: p.index, atStop: p.atStop, color: certaintyColor(context, v.started ? Certainty.moving : Certainty.waiting)),
    ],
  ];
  return [
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 16, 12),
        child: Row(children: [
          M3EIconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: context.l10n.back,
            variant: M3EIconButtonVariant.standard,
            onPressed: onBack,
          ),
          const SizedBox(width: 4),
          LinePill.of(line: s.label, mode: s.mode, colors: s.colors, large: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (trip != null)
                Row(children: [
                  Icon(Icons.arrow_forward_rounded, size: 18, color: cs.onSurface),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(titleCase(trip.headsign),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: emphasized(context).titleMedium.copyWith(color: cs.onSurface)),
                  ),
                ]),
              Row(children: [
                if ((liveBuses ?? 0) > 0) ...[
                  Icon(Icons.sensors_rounded, size: 14, color: liveColor(context)),
                  const SizedBox(width: 4),
                ],
                Text(
                  [
                    if (liveBuses != null) context.l10n.busesLive(liveBuses),
                    if (trip != null) context.l10n.stopsCount(trip.stops.length),
                  ].join(' · '),
                  style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
              ]),
            ]),
          ),
          if (onSwitchDirection != null)
            M3EIconButton(
              icon: const Icon(Icons.swap_horiz_rounded),
              tooltip: context.l10n.otherDirection,
              variant: M3EIconButtonVariant.tonal,
              onPressed: onSwitchDirection,
            ),
        ]),
      ),
    ),
    if (s.error != null)
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(s.error!, style: TextStyle(color: cs.error)),
        ),
      )
    else if (trip == null)
      SliverToBoxAdapter(child: SheetLoading(label: context.l10n.loadingLine))
    else
      SliverToBoxAdapter(
        child: _StopList(
          stops: stops,
          color: color,
          certainty: certainty,
          buses: places,
          // With the line's live buses known, the stops behind the last of
          // them (no bus left to come) are dimmed; else those passed by time.
          dimBefore: liveBuses == null ? null : places.map((p) => p.index).fold<int?>(null, (a, b) => a == null || b < a ? b : a) ?? 0,
          onStopTap: onStopTap,
        ),
      ),
  ];
}

/// A bus drawn on the stop list: at stop [index] ([atStop]) or on the way
/// to it from the stop before, in [color].
typedef BusOnList = ({int index, bool atStop, Color color});

/// The trip's stops as a card list, with the buses on it: in place of the
/// dot when one is at a stop, else over the gap between the two cards it
/// runs between. The cards clip their content, so those are drawn on a
/// layer above the list, where the measured line of the stop left ends.
class _StopList extends StatefulWidget {
  const _StopList({
    required this.stops,
    required this.color,
    required this.certainty,
    required this.buses,
    required this.dimBefore,
    required this.onStopTap,
  });
  final List<TripStop> stops;
  final Color color;
  final Certainty certainty;
  final List<BusOnList> buses;

  /// Stops before this index are dimmed; null: those passed by time.
  final int? dimBefore;
  final ValueChanged<TripStop> onStopTap;

  @override
  State<_StopList> createState() => _StopListState();
}

class _StopListState extends State<_StopList> {
  static const _gap = M3EListCardListTheme.defaultGap;
  final _stack = GlobalKey();

  /// The timeline of each stop a bus left, by stop index.
  final _lines = <int, GlobalKey>{};

  /// Centre of each gap a bus is over, in the stack, by the left stop's index.
  Map<int, Offset> _gaps = {};

  /// Stop index -> color of the bus between it and the next one.
  Map<int, Color> get _between => {
        for (final b in widget.buses.reversed)
          if (!b.atStop && b.index > 0) b.index - 1: b.color,
      };

  void _measure() {
    if (!mounted) return;
    final stack = _stack.currentContext?.findRenderObject() as RenderBox?;
    final at = <int, Offset>{};
    for (final i in _between.keys) {
      final line = _lines[i]?.currentContext?.findRenderObject() as RenderBox?;
      if (line == null || stack == null || !line.attached || !stack.attached) continue;
      at[i] = stack.globalToLocal(line.localToGlobal(line.size.bottomCenter(Offset.zero))) + const Offset(0, _gap / 2);
    }
    final same = at.length == _gaps.length &&
        at.entries.every((e) => _gaps[e.key] != null && (e.value - _gaps[e.key]!).distance <= 0.5);
    if (!same) setState(() => _gaps = at);
  }

  @override
  Widget build(BuildContext context) {
    final stops = widget.stops;
    final between = _between;
    // The first one listed (the shown trip's bus) wins a stop it shares.
    final atStop = <int, Color>{
      for (final b in widget.buses.reversed)
        if (b.atStop) b.index: b.color,
    };
    _lines.removeWhere((i, _) => !between.containsKey(i));
    for (final i in between.keys) {
      _lines.putIfAbsent(i, GlobalKey.new);
    }
    final now = DateTime.now().subtract(const Duration(minutes: 1));
    bool dimmed(int i) => switch (widget.dimBefore) {
          final before? => i < before,
          null => stops[i].time != null && stops[i].time!.isBefore(now),
        };
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    return Stack(key: _stack, clipBehavior: Clip.none, children: [
      M3EList(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        gap: _gap,
        itemCount: stops.length,
        itemBuilder: (_, i) => _StopRow(
          stop: stops[i],
          color: widget.color,
          certainty: widget.certainty,
          first: i == 0,
          last: i == stops.length - 1,
          dimmed: dimmed(i) && !atStop.containsKey(i),
          busHere: atStop[i],
          lineKey: _lines[i],
        ),
        onTap: (i) => widget.onStopTap(stops[i]),
      ),
      for (final MapEntry(key: i, value: at) in _gaps.entries)
        if (between[i] case final c?)
          Positioned(
            left: at.dx - _BusBadge.size / 2,
            top: at.dy - _BusBadge.size / 2,
            child: IgnorePointer(child: _BusBadge(color: c)),
          ),
    ]);
  }
}

/// The bus badge's color: like its live times, live green on timetable.
Color _busColor(BuildContext context, Certainty c) =>
    certaintyColor(context, c == Certainty.scheduled ? Certainty.moving : c);

/// One stop of the trip: time (colored by how sure it is), a line with a
/// dot, the name. Stops no bus is left to reach are [dimmed]. A bus
/// ([busHere], its color) replaces the dot when it's at the stop.
/// [lineKey] marks the timeline, to place a bus between stops (see
/// [_StopList]).
class _StopRow extends StatelessWidget {
  const _StopRow({
    required this.stop,
    required this.color,
    required this.certainty,
    required this.first,
    required this.last,
    required this.dimmed,
    this.busHere,
    this.lineKey,
  });
  final TripStop stop;
  final Color color;
  final Certainty certainty;
  final bool first;
  final bool last;
  final bool dimmed;
  final Color? busHere;
  final Key? lineKey;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final passed = stop.time != null && stop.time!.isBefore(DateTime.now().subtract(const Duration(minutes: 1)));
    final timeColor =
        passed ? cs.outline : (certainty == Certainty.scheduled ? cs.onSurface : certaintyColor(context, certainty));
    final dot = Container(
      width: first || last ? 14 : 10,
      height: first || last ? 14 : 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: cs.surface,
        border: Border.all(color: color, width: 3),
      ),
    );
    return Opacity(
      opacity: dimmed ? 0.55 : 1,
      child: SizedBox(
        height: 48,
        child: Row(children: [
          const SizedBox(width: 16),
          SizedBox(
            width: 48,
            child: Text(stop.time == null ? '' : hm(stop.time!),
                style: emphasized(context).labelLarge.copyWith(color: timeColor)),
          ),
          SizedBox(
            key: lineKey,
            width: 24,
            child: Stack(alignment: Alignment.center, children: [
              Column(children: [
                Expanded(child: Container(width: 4, color: first ? Colors.transparent : color)),
                Expanded(child: Container(width: 4, color: last ? Colors.transparent : color)),
              ]),
              if (busHere case final c?) _BusBadge(color: c) else dot,
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              titleCase(stop.name),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (first || last ? emphasized(context).bodyLarge : Theme.of(context).textTheme.bodyLarge)
                  ?.copyWith(color: cs.onSurface),
            ),
          ),
          const SizedBox(width: 16),
        ]),
      ),
    );
  }
}

/// The bus on the stop list's line: a filled circle with a bus icon,
/// colored like its live times.
class _BusBadge extends StatelessWidget {
  const _BusBadge({required this.color});
  final Color color;
  static const size = 24.0;

  @override
  Widget build(BuildContext context) {
    final fg = ThemeData.estimateBrightnessForColor(color) == Brightness.dark ? Colors.white : Colors.black;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2),
      ),
      child: Icon(Icons.directions_bus_rounded, size: 14, color: fg),
    );
  }
}
