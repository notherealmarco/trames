import 'package:flutter_localizations/flutter_localizations.dart' show GlobalWidgetsLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;
import 'package:roma_transit/l10n/app_localizations.dart';
import 'package:roma_transit/plan_time.dart';

Widget _app(Widget child) => MaterialApp(
      locale: const Locale('it'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true),
      builder: (context, c) => M3ETheme(
        data: M3EThemeData.fromMaterial(Theme.of(context)),
        initialTheme: Brightness.light,
        child: c!,
      ),
      home: Scaffold(body: child),
    );

/// Opens the dialog from a button; [result] gets what it completes with.
Future<void> _open(WidgetTester t, PlanTime initial, void Function(PlanTime?) result) async {
  t.view.physicalSize = const Size(1080, 2400);
  t.view.devicePixelRatio = 2.75;
  addTearDown(t.view.reset);
  await t.pumpWidget(_app(Builder(
    builder: (context) => TextButton(
      onPressed: () async => result(await showPlanTimeDialog(context, initial)),
      child: const Text('open'),
    ),
  )));
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
  // Only Cupertino's "locale it not supported" warning, as in the app.
  final e = t.takeException();
  expect(e == null || '$e'.contains('not supported by all of its localization'), isTrue, reason: '$e');
}

void main() {
  test('a chosen time is "passed" once it is not ahead of now, to the minute', () {
    final now = DateTime(2026, 11, 23, 13, 0, 40);
    expect(const PlanTime().passed(now), isFalse);
    expect(PlanTime(time: DateTime(2026, 11, 23, 13, 1)).passed(now), isFalse);
    expect(PlanTime(time: DateTime(2026, 11, 23, 13, 0)).passed(now), isTrue);
    expect(PlanTime(time: DateTime(2026, 11, 23, 12, 59), arriveBy: true).passed(now), isTrue);
  });

  testWidgets('confirming the current minute is "leave now"', (t) async {
    PlanTime? got = const PlanTime(time: null, arriveBy: true);
    await _open(t, const PlanTime(), (p) => got = p);
    await t.tap(find.text('Imposta'));
    await t.pumpAndSettle();
    expect(got, isNotNull);
    expect(got!.time, isNull);
    expect(got!.arriveBy, isFalse);
  });

  testWidgets('a time already passed opens on now and confirms as "leave now"', (t) async {
    PlanTime? got;
    await _open(t, PlanTime(time: DateTime.now().subtract(const Duration(hours: 3)), arriveBy: true), (p) => got = p);
    await t.tap(find.text('Imposta'));
    await t.pumpAndSettle();
    expect(got!.time, isNull);
  });

  testWidgets('the hour wheel starts at the current hour: nothing before it', (t) async {
    await _open(t, const PlanTime(), (_) {});
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final wheels = find.byType(ListWheelScrollView);
    expect(wheels, findsNWidgets(2));
    final hours = t.widget<ListWheelScrollView>(wheels.first).controller as FixedExtentScrollController;
    expect(hours.selectedItem, 0);
    // Dragging down (towards earlier hours) stays on the current one.
    await t.drag(wheels.first, const Offset(0, 200));
    await t.pumpAndSettle();
    expect(hours.selectedItem, 0);
    expect(find.descendant(of: wheels.first, matching: find.text(two(now.hour))), findsOneWidget);
    if (now.hour > 0) {
      expect(find.descendant(of: wheels.first, matching: find.text(two(now.hour - 1))), findsNothing);
    }
  });

  testWidgets('a later hour confirms that time, as departure or arrival', (t) async {
    PlanTime? got;
    await _open(t, const PlanTime(), (p) => got = p);
    await t.tap(find.text('Arrivo'));
    await t.pumpAndSettle();
    final wheels = find.byType(ListWheelScrollView);
    final hours = t.widget<ListWheelScrollView>(wheels.first).controller as FixedExtentScrollController;
    // 24 slots on: the same hour tomorrow, whatever the time the test runs
    // at (30 would be the day after from 18:00 on).
    hours.jumpToItem(24);
    await t.pumpAndSettle();
    expect(find.text('Domani'), findsOneWidget);
    await t.tap(find.text('Imposta'));
    await t.pumpAndSettle();
    final now = DateTime.now();
    expect(got!.arriveBy, isTrue);
    expect(got!.time!.isAfter(now.add(const Duration(hours: 23))), isTrue);
  });
}
