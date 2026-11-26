import 'package:flutter_test/flutter_test.dart';
import 'package:roma_transit/backend/line_style.dart';

void main() {
  tearDown(() => lineOverrides.set({}));

  test('feed colour first, else the category default', () {
    expect(lineColors(mode: 'SUBWAY', line: 'MEA', color: 'e27439').color, '#E27439');
    expect(lineColors(mode: 'BUS', line: '85').color, kBusColor);
    expect(lineColors(mode: 'TRAM', line: '8', color: '').color, kTramColor);
    expect(lineColors(mode: 'SUBWAY', line: 'X').color, kMetroColor);
    expect(lineColors(mode: 'REGIONAL_RAIL', line: 'FL1').color, kTrainColor);
    expect(lineColors(mode: 'FERRY', line: 'F').color, kFerryColor);
  });

  test('text: the feed\'s, else white or black by contrast', () {
    expect(lineColors(mode: 'BUS', color: '0570B5', textColor: 'FFFF00').text, '#FFFF00');
    expect(lineColors(mode: 'BUS').text, '#FFFFFF'); // on bus green
    expect(lineColors(mode: 'TRAM').text, '#000000'); // on orange
  });

  test('Tramite overrides win, matched by the source of an id', () {
    lineOverrides.set({
      'it-Lazio-Rome': [
        RouteOverride(line: 'MEA', friendlyName: 'MA'),
        RouteOverride(line: '8', color: '123456'),
      ],
    });
    expect(lineName('MEA', id: '20261113_14:33_it-Lazio-Rome_1#2'), 'MA');
    expect(lineName('mea', id: 'it-Lazio-Rome_71527'), 'MA');
    expect(lineName('MEA', id: 'it-Other_5'), 'MEA'); // another source
    expect(lineName('MEA'), 'MA'); // no id: any source
    expect(lineName('85', id: 'it-Lazio-Rome_1'), '85');
    expect(lineColors(mode: 'TRAM', line: '8', color: 'FFFFFF', id: 'it-Lazio-Rome_1').color, '#123456');
    expect(lineOverrides.lineOfFriendlyName('it-Lazio-Rome', 'ma'), 'MEA');
  });

  test('GTFS route types as modes', () {
    expect(modeOfRouteType(0), 'TRAM');
    expect(modeOfRouteType(1), 'SUBWAY');
    expect(modeOfRouteType(401), 'SUBWAY');
    expect(modeOfRouteType(109), 'RAIL');
    expect(modeOfRouteType(3), 'BUS');
    expect(modeOfRouteType(null), 'BUS');
  });
}
