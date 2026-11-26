import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;

import 'backend/backend.dart';
import 'backend/route_search.dart';
import 'l10n.dart';
import 'live_buses.dart';
import 'split_line_pill.dart';

Color hexColor(String hex) => Color(int.parse('FF${hex.substring(1)}', radix: 16));

String hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Why a journey's times can't be made (see [Itinerary.missedConnection]):
/// a warning, whatever its buses. [live]: every ride has a live time, so
/// the connection is missed, not just likely to be.
class MissedWarning extends StatelessWidget {
  const MissedWarning(this.it, {super.key, required this.live});
  final Itinerary it;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final color = Theme.of(context).colorScheme.error;
    return Row(children: [
      Icon(Icons.warning_amber_rounded, size: 14, color: color),
      const SizedBox(width: 4),
      Flexible(
        child: Text(
            it.lateForFirstRide(DateTime.now())
                ? l.tooLateForFirstStop
                : live
                    ? l.missedConnectionLive
                    : l.missedConnectionWarning,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color)),
      ),
    ]);
  }
}

int minutesUntil(DateTime t) => (t.difference(DateTime.now()).inSeconds / 60).round();

/// "now" / "in 5 min".
String inMinutes(AppLocalizations l, DateTime t) {
  final m = minutesUntil(t);
  return m <= 0 ? l.now : l.inMinutes(m);
}

/// "Stop" / "Address" / "Place", shown before a search result's area.
String placeKindLabel(AppLocalizations l, PlaceKind k) => switch (k) {
      PlaceKind.stop => l.placeKindStop,
      PlaceKind.address => l.placeKindAddress,
      PlaceKind.place => l.placeKindPlace,
    };

IconData modeIcon(String mode) => switch (mode) {
      'SUBWAY' => Icons.subway_rounded,
      'TRAM' => Icons.tram_rounded,
      'RAIL' => Icons.train_rounded,
      'WALK' => Icons.directions_walk_rounded,
      _ => Icons.directions_bus_rounded,
    };

M3ETypeScale emphasized(BuildContext context) => M3ETheme.of(context).typography.emphasized;

/// Section title inside the sheet.
class SheetSectionHeader extends StatelessWidget {
  const SheetSectionHeader(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 8),
      child: Row(children: [
        Expanded(
          child: Text(title, style: emphasized(context).titleMedium.copyWith(color: cs.onSurface)),
        ),
        ?trailing,
      ]),
    );
  }
}

/// Sub-header inside the route list: "Live · 3" (green, live icon) or
/// "Scheduled · 8".
class RouteSectionLabel extends StatelessWidget {
  const RouteSectionLabel(
      {super.key, required this.live, required this.count, this.onFoot = false, this.predicted = false});
  final bool live;
  final int count;

  /// "On foot" (walking the whole way) instead of Live / Scheduled.
  final bool onFoot;

  /// "Predicted": some ride's time is our estimate (purple or red).
  final bool predicted;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l = context.l10n;
    final (icon, label, color) = onFoot
        ? (Icons.directions_walk_rounded, l.routeSectionOnFoot, cs.onSurfaceVariant)
        : predicted
            ? (certaintyIcon(Certainty.estimated)!, l.routeSectionPredicted, certaintyColor(context, Certainty.estimated))
            : live
                ? (Icons.sensors_rounded, l.routeSectionLive, liveColor(context))
                : (Icons.schedule_rounded, l.routeSectionScheduled, cs.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 12, 24, 8),
      child: Row(children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Text(label, style: emphasized(context).labelLarge.copyWith(color: color)),
        const SizedBox(width: 6),
        Text('· $count', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
      ]),
    );
  }
}

/// Centered expressive loading indicator.
class SheetLoading extends StatelessWidget {
  const SheetLoading({super.key, this.label});
  final String? label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(children: [
        const M3ELoadingIndicator(variant: M3ELoadingIndicatorVariant.contained),
        if (label != null) ...[
          const SizedBox(height: 12),
          Text(label!, style: TextStyle(color: cs.onSurfaceVariant)),
        ],
      ]),
    );
  }
}

/// Line pill: mode icon + short name on the line's color.
class LinePill extends StatelessWidget {
  const LinePill({super.key, required this.line, required this.mode, required this.color, this.textColor, this.large = false});
  final String line;
  final String mode;
  final Color color;

  /// Text and icon color; by default white or black, whichever reads better.
  final Color? textColor;
  final bool large;

  /// The pill of a line with [colors] (see line_style.dart).
  factory LinePill.of({Key? key, required String line, required String mode, required LineColors colors, bool large = false}) =>
      LinePill(key: key, line: line, mode: mode, color: hexColor(colors.color), textColor: hexColor(colors.text), large: large);

  @override
  Widget build(BuildContext context) {
    final fg = textColor ??
        (ThemeData.estimateBrightnessForColor(color) == Brightness.dark ? Colors.white : Colors.black);
    final style = (large ? emphasized(context).titleLarge : emphasized(context).labelLarge).copyWith(color: fg);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: large ? 12 : 8, vertical: large ? 6 : 4),
      decoration: ShapeDecoration(color: color, shape: const StadiumBorder()),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(modeIcon(mode), size: large ? 20 : 16, color: fg),
        const SizedBox(width: 4),
        Text(line, style: style),
      ]),
    );
  }
}

/// Big countdown used in nearby departures: "6" over "min".
class Countdown extends StatelessWidget {
  const Countdown({super.key, required this.departure, required this.certainty});
  final Departure departure;
  final Certainty certainty;

  @override
  Widget build(BuildContext context) {
    final m = minutesUntil(departure.time);
    // Timetable only: the clock time, as on a printed timetable (a countdown
    // would suggest a precision the timetable doesn't have).
    if (certainty == Certainty.scheduled) {
      return Semantics(
        label: context.l10n.atTimeScheduled(hm(departure.time)),
        excludeSemantics: true,
        child: Text(hm(departure.time),
            style: emphasized(context).headlineSmall.copyWith(color: certaintyColor(context, certainty), height: 1)),
      );
    }
    return Semantics(
      label: '${m <= 0 ? context.l10n.now : context.l10n.inMinutesLong(m)}, ${describeCertainty(context.l10n, certainty)}',
      excludeSemantics: true,
      child: LiveMinutes(
        minutes: m,
        certainty: certainty,
        style: emphasized(context).headlineLarge,
      ),
    );
  }
}

/// Big minute count with "min" below, colored by [certainty]; its icon (bus
/// on the way / not started yet) sits to the left, sized to the number and
/// centered on it.
class LiveMinutes extends StatelessWidget {
  const LiveMinutes(
      {super.key, required this.minutes, required this.certainty, required this.style, this.showIn = false});
  final int minutes;
  final Certainty certainty;
  final TextStyle style;

  /// "in" above the number ("in / 10 / min"), so it reads as a wait.
  final bool showIn;

  @override
  Widget build(BuildContext context) {
    final color = certaintyColor(context, certainty);
    final icon = certaintyIcon(certainty);
    final numberStyle = style.copyWith(color: color, height: 1);
    final iconSize = (numberStyle.fontSize ?? 32) * 0.6;
    final labelStyle = Theme.of(context).textTheme.labelMedium?.copyWith(color: color);
    return Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
      if (showIn && minutes > 0) Text(context.l10n.waitIn, style: labelStyle),
      Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
        if (icon != null) ...[
          Icon(icon, size: iconSize, color: color),
          const SizedBox(width: 4),
        ],
        Text(minutes <= 0 ? context.l10n.now : '$minutes', style: numberStyle),
      ]),
      if (minutes > 0) Text(context.l10n.min, style: labelStyle),
    ]);
  }
}

/// One nearby departure: line, direction, stop, countdown.
class NearbyDepartureRow extends StatelessWidget {
  const NearbyDepartureRow({super.key, required this.row, required this.certainty, this.showStop = true});
  final BoardRow row;
  final Certainty certainty;

  /// The "stop · distance · then …" line; off when showing a single stop.
  final bool showStop;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final firstMin = minutesUntil(row.next.first.time);
    final soon = row.next.skip(1).where((d) => minutesUntil(d.time) > firstMin).take(2);
    // Like the big number: clock times on a timetable-only row, else minutes.
    final later = (certainty == Certainty.scheduled
            ? soon.map((d) => hm(d.time))
            : soon.map((d) => '${minutesUntil(d.time)}′'))
        .join(', ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            LinePill.of(line: row.label, mode: row.mode, colors: row.colors, large: true),
            const SizedBox(height: 4),
            Row(children: [
              Icon(Icons.arrow_forward_rounded, size: 16, color: cs.onSurface),
              const SizedBox(width: 4),
              Flexible(
                child: Text(_title(row.headsign),
                    overflow: TextOverflow.ellipsis,
                    style: emphasized(context).titleSmall.copyWith(color: cs.onSurface)),
              ),
            ]),
            if (showStop) ...[
              const SizedBox(height: 2),
              Text(
                '${_title(row.stop.name)} · ${row.stop.distanceMeters} m${later.isEmpty ? '' : ' · ${context.l10n.thenLater(later)}'}',
                overflow: TextOverflow.ellipsis,
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ]),
        ),
        const SizedBox(width: 12),
        Countdown(departure: row.next.first, certainty: certainty),
      ]),
    );
  }
}

/// GTFS names in Rome are ALL CAPS; make them readable.
/// Rome's GTFS names are ALL CAPS ("TERMINI (MA-MB-FS)", "OJETTI/PRIMOLI").
/// Keep parenthesised codes as-is, title-case words (also after "/" or "."),
/// and lowercase short Italian particles.
const _particles = {'di', 'de', 'del', 'della', 'delle', 'dei', 'degli', 'da', 'e', 'a', 'al', 'alla', 'in'};
String _title(String s) {
  if (s != s.toUpperCase()) return s; // already mixed case
  var first = true;
  return s.replaceAllMapped(RegExp(r"\([^)]*\)|[A-Za-zÀ-ÿ']+"), (m) {
    final w = m[0]!;
    if (w.startsWith('(')) return w;
    final lower = w.toLowerCase();
    final keepLower = !first && _particles.contains(lower);
    first = false;
    return keepLower ? lower : '${lower[0].toUpperCase()}${lower.substring(1)}';
  });
}

String titleCase(String s) => _title(s);

/// Green used for "this time is live", harmonized with the app's palette.
Color liveColor(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  final base = cs.brightness == Brightness.dark ? const Color(0xFF6DD58C) : const Color(0xFF146C2E);
  return base.harmonizeWith(cs.primary);
}

/// Color of a time by how sure it is that the bus comes (not by how late it
/// runs: what matters is the wait): green when the bus is on its way, yellow
/// when it hasn't started its trip yet, red when a bus coming back from the
/// other direction should make it, grey for timetable only. Purple marks a
/// time the app worked out itself (bus coming back too late for the
/// timetable): a fixed violet, barely harmonized, so it never reads as the
/// app's own (wallpaper) accent.
/// Light/dark tones keep text contrast on the sheet's surfaces.
Color certaintyColor(BuildContext context, Certainty c) {
  final cs = Theme.of(context).colorScheme;
  final dark = cs.brightness == Brightness.dark;
  return switch (c) {
    Certainty.scheduled => cs.onSurfaceVariant,
    Certainty.estimated => Color.lerp(dark ? const Color(0xFFC9A7FF) : const Color(0xFF6B3FD4), cs.primary, 0.1)!,
    Certainty.returning => (dark ? const Color(0xFFFF8A80) : const Color(0xFFB3261E)).harmonizeWith(cs.primary),
    Certainty.waiting => (dark ? const Color(0xFFE9C46A) : const Color(0xFF7A5D00)).harmonizeWith(cs.primary),
    Certainty.moving => liveColor(context),
  };
}

/// Icon next to a time: live signal (bus on its way), departure board (bus +
/// clock: not left yet), U-turn (a bus coming back around), sparkles (our
/// estimate); none on plain timetable.
IconData? certaintyIcon(Certainty c) => switch (c) {
      Certainty.scheduled => null,
      Certainty.estimated => Icons.auto_awesome_rounded,
      Certainty.returning => Icons.u_turn_left_rounded,
      Certainty.waiting => Icons.departure_board_rounded,
      Certainty.moving => Icons.sensors_rounded,
    };

/// For screen readers.
String describeCertainty(AppLocalizations l, Certainty c) => switch (c) {
      Certainty.scheduled => l.certaintyScheduled,
      Certainty.estimated => l.certaintyEstimated,
      Certainty.returning => l.certaintyReturning,
      Certainty.waiting => l.certaintyWaiting,
      Certainty.moving => l.certaintyMoving,
    };

/// One itinerary in the route list.
///
/// Live state is shown through color (see [certaintyColor]):
///  * departure: by how sure the first bus is (on its way / not started);
///  * arrival, when every ride is live: by the least sure of them;
///  * otherwise neutral (scheduled).
class ItineraryRow extends StatelessWidget {
  const ItineraryRow({
    super.key,
    required this.it,
    required this.colorFor,
    this.padding = const EdgeInsets.fromLTRB(20, 16, 20, 16),
    this.lineOptions,
    required this.certaintyFor,
  });
  final Itinerary it;
  final Color Function(Itinerary, Leg) colorFor;
  final EdgeInsets padding;

  /// How sure each ride's live time is (see [certaintyOf]).
  final Certainty Function(Leg) certaintyFor;

  /// Optional lines per transit leg (in order), planned line first, e.g.
  /// ["88", "3"] when either can do the leg: shown as a split pill.
  final List<List<String>>? lineOptions;

  List<String>? _optionsFor(int legIndex) {
    final all = lineOptions;
    if (all == null) return null;
    final k = it.legs.take(legIndex).where((l) => l.transit).length;
    return k < all.length ? all[k] : null;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final legs = it.transitLegs.toList();
    // "Live" here: backed by a real bus (anything but plain timetable).
    final certainties = legs.map(certaintyFor).toList();
    final weakest = certainties.isEmpty ? Certainty.scheduled : certainties.reduce((a, b) => a.index < b.index ? a : b);
    // A missed connection makes the arrival unknown: no color for it.
    final allLive = legs.isNotEmpty && weakest != Certainty.scheduled && !it.missedConnection;
    final firstCertainty = legs.isEmpty ? Certainty.scheduled : certainties.first;
    final firstLive = firstCertainty != Certainty.scheduled;
    final grey = cs.onSurfaceVariant;
    final base = tt.bodyMedium?.copyWith(color: grey);
    final depColor = firstLive ? certaintyColor(context, firstCertainty) : grey;
    final arrColor = allLive ? certaintyColor(context, weakest) : grey;
    final depStyle = base?.copyWith(color: depColor, fontWeight: FontWeight.w600);
    final arrStyle = base?.copyWith(color: arrColor, fontWeight: FontWeight.w600);

    final times = Text.rich(TextSpan(children: [
      if (firstLive)
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(certaintyIcon(firstCertainty) ?? Icons.sensors_rounded, size: 16, color: depColor),
          ),
        ),
      TextSpan(text: hm(it.start), style: firstLive ? depStyle : base),
      TextSpan(
        text: ' – ${hm(it.end)} · ${it.duration.inMinutes} min',
        style: allLive ? arrStyle : base,
      ),
    ]));

    return Padding(
      padding: padding,
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                legs.isEmpty
                    ? context.l10n.itineraryWalk
                    // Already riding: where to get off, not when to leave.
                    : legs.first.onBoard
                        ? (staysOnBoard(it)
                            ? context.l10n.itineraryStayOn(titleCase(legs.first.toName))
                            : context.l10n.itineraryGetOff(titleCase(legs.first.toName)))
                        // Over an hour away a clock time reads better than "in 1081 min".
                        : minutesUntil(it.start) > 60
                            ? context.l10n.leaveAt(hm(it.start))
                            : context.l10n.itineraryLeave(inMinutes(context.l10n, it.start)),
                style: emphasized(context).titleMedium.copyWith(color: cs.onSurface)),
            const SizedBox(height: 2),
            times,
            if (it.missedConnection) ...[
              const SizedBox(height: 2),
              MissedWarning(it, live: certainties.every((c) => c == Certainty.moving || c == Certainty.waiting)),
            ],
            const SizedBox(height: 10),
            // Wraps inside the left column, so it never runs under the arrival time.
            Wrap(spacing: 4, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              for (var i = 0; i < it.legs.length; i++) ...[
                if (i > 0) Icon(Icons.chevron_right_rounded, size: 18, color: cs.outline),
                if (it.legs[i].transit)
                  if (_optionsFor(i) case final opts? when opts.length > 1)
                    SplitLinePill(lines: opts, icon: modeIcon(it.legs[i].mode), color: colorFor(it, it.legs[i]))
                  else
                    LinePill.of(line: it.legs[i].label, mode: it.legs[i].mode, colors: it.legs[i].colors)
                else if (it.walkOptions[i] case final buses? when buses.isNotEmpty)
                  // Walking chosen over a ride: "🚶 20 ╱ 3BUS", the buses are
                  // the swipe options for this stretch in the trip view.
                  SplitLinePill(
                    lines: ['${it.legs[i].duration.inMinutes}', ...buses.map((b) => lineName(b))],
                    icon: Icons.directions_walk_rounded,
                    color: grey,
                    outlineFirst: true,
                  )
                else
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.directions_walk_rounded, size: 18, color: grey),
                    Text('${it.legs[i].end.difference(it.legs[i].start).inMinutes}',
                        style: tt.labelMedium?.copyWith(color: grey)),
                  ]),
              ],
            ]),
          ]),
        ),
        const SizedBox(width: 16),
        Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(context.l10n.arrive, style: tt.labelMedium?.copyWith(color: arrColor)),
          Text(
            hm(it.end),
            style: emphasized(context).displaySmall.copyWith(color: allLive ? arrColor : cs.onSurface, height: 1.05),
          ),
        ]),
      ]),
    );
  }
}

/// Minutes until this vehicle reaches the boarding stop, colored by how sure
/// that is ([certaintyColor]).
class WaitIndicator extends StatelessWidget {
  const WaitIndicator({super.key, required this.minutes, required this.certainty});
  final int minutes;
  final Certainty certainty;

  @override
  Widget build(BuildContext context) => LiveMinutes(
        minutes: minutes,
        certainty: certainty,
        style: emphasized(context).headlineMedium,
        showIn: true,
      );
}

/// One leg in the trip detail. [waitMinutes] is how long until the vehicle
/// reaches the boarding stop (transit legs only).
class LegRow extends StatelessWidget {
  const LegRow(
      {super.key,
      required this.leg,
      required this.color,
      this.bus,
      this.waitMinutes,
      this.stopsLeft,
      this.certainty = Certainty.scheduled});
  final Leg leg;

  /// On the bus you're on: the stops before yours, counted from where the
  /// bus is now (else the leg's own count, from when it was planned).
  final int? stopsLeft;
  final Color color;
  final TrackedBus? bus;
  final int? waitMinutes;

  /// How sure this ride's live time is (rides only).
  final Certainty certainty;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    // On board the ride started when it was planned: what's left counts.
    final mins = leg.onBoard
        ? minutesUntil(leg.end).clamp(0, 9999)
        : leg.end.difference(leg.start).inMinutes;
    final timeStyle = emphasized(context)
        .labelLarge
        .copyWith(color: leg.transit && leg.realtime ? certaintyColor(context, certainty) : cs.onSurface);
    if (!leg.transit) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
        child: Row(children: [
          SizedBox(width: 52, child: Text(hm(leg.start), style: timeStyle)),
          Icon(Icons.directions_walk_rounded, color: cs.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(context.l10n.walkLeg(leg.distanceMeters.round(), mins, titleCase(leg.toName)),
                style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
          ),
        ]),
      );
    }
    final busAge = bus == null ? null : DateTime.now().difference(bus!.vehicle.timestamp).inSeconds;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(width: 52, child: Text(hm(leg.start), style: timeStyle)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              LinePill(line: leg.label, mode: leg.mode, color: color, textColor: hexColor(leg.colors.text), large: true),
              const SizedBox(width: 10),
              Expanded(
                child: Text(titleCase(leg.headsign ?? ''),
                    overflow: TextOverflow.ellipsis, style: emphasized(context).titleSmall.copyWith(color: cs.onSurface)),
              ),
            ]),
            const SizedBox(height: 8),
            Text(
                leg.onBoard
                    ? context.l10n.itineraryGetOff(titleCase(leg.toName))
                    : '${titleCase(leg.fromName)} → ${titleCase(leg.toName)}',
                style: tt.bodyMedium?.copyWith(color: cs.onSurface)),
            Text(
              context.l10n.legSummary(stopsLeft ?? leg.intermediateStops, mins, hm(leg.end)),
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            if (bus != null || leg.realtime) ...[
              const SizedBox(height: 4),
              Text(
                bus != null
                    ? (bus!.vehicle.started
                        ? context.l10n.busGps(bus!.vehicle.label, busAge!)
                        : context.l10n.busGpsNotDeparted(bus!.vehicle.label, busAge!))
                    : context.l10n.locatingBus,
                style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],

          ]),
        ),
        if (waitMinutes != null) ...[
          const SizedBox(width: 12),
          WaitIndicator(minutes: waitMinutes!, certainty: certainty),
        ],
      ]),
    );
  }
}

/// One line sequence in the route list: its best trip in full, small tags
/// (fastest / fewest changes / least walking). Later buses: open it and swipe.
class RouteGroupRow extends StatelessWidget {
  const RouteGroupRow({super.key, required this.group, required this.colorFor, required this.certaintyFor});
  final RouteGroup group;
  final Color Function(Itinerary, Leg) colorFor;
  final Certainty Function(Leg) certaintyFor;

  /// Per transit leg: its own line first, then the other lines that can
  /// replace it (from the planner's leg alternatives).
  static List<List<String>> _lineOptions(Itinerary it) => [
        for (final leg in it.transitLegs)
          <String>{leg.label, for (final a in leg.alternatives) a.label}.toList(),
      ];

  @override
  Widget build(BuildContext context) {
    final hasTags = group.tags.isNotEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (hasTags)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          child: Wrap(spacing: 6, runSpacing: 6, children: [for (final t in group.tags) _RouteTagChip(t)]),
        ),
      ItineraryRow(
        it: group.best,
        colorFor: colorFor,
        certaintyFor: certaintyFor,
        lineOptions: _lineOptions(group.best),
        padding: EdgeInsets.fromLTRB(20, hasTags ? 8 : 16, 20, 16),
      ),
    ]);
  }
}

class _RouteTagChip extends StatelessWidget {
  const _RouteTagChip(this.tag);
  final RouteTag tag;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (icon, label) = switch (tag) {
      RouteTag.fastest => (Icons.bolt_rounded, context.l10n.tagFastest),
      RouteTag.fewestChanges => (Icons.swap_horiz_rounded, context.l10n.tagFewestChanges),
      RouteTag.leastWalking => (Icons.directions_walk_rounded, context.l10n.tagLeastWalking),
      RouteTag.onFoot => (Icons.directions_walk_rounded, context.l10n.tagFasterOnFoot),
      RouteTag.stayOnBoard => (Icons.event_seat_rounded, context.l10n.tagStayOnBoard),
      RouteTag.leaveEarlier => (Icons.schedule_rounded, context.l10n.tagLeaveEarlier),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 3, 10, 3),
      decoration: ShapeDecoration(color: cs.secondaryContainer, shape: const StadiumBorder()),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: cs.onSecondaryContainer),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSecondaryContainer)),
      ]),
    );
  }
}

