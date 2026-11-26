import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;


/// Map image name of the heading cone (see [busConeSdf]).
const kBusConeImage = 'bus-cone';

/// Length of the cone from the bus, in logical pixels (before the layer's
/// icon size).
const kConeLength = 32.0;

/// How the cone's halo reads [busConeSdf]: MapLibre draws an SDF icon's
/// halo where the image's alpha is around its buffer, fading over ±its
/// gamma. With [coneHaloWidth] and [coneHaloBlur] for the layer's icon
/// size that range is [kConeAlphaLow, kConeAlphaHigh], and the image's
/// alpha is chosen in it to give each pixel the opacity it should have.
const kConeAlphaLow = 0.05, kConeAlphaHigh = 0.95;

/// Strongest opacity of a cone, next to the bus (as the old picture cones).
const kConeOpacity = 0.55;

/// The halo width that puts the halo's buffer at the middle of
/// [kConeAlphaLow]..[kConeAlphaHigh] for an icon drawn at [iconSize]:
/// MapLibre's buffer is (6 - width / size) / 8.
double coneHaloWidth(double iconSize) => (6 - 8 * (kConeAlphaLow + kConeAlphaHigh) / 2) * iconSize;

/// The halo blur that spreads the halo's fade over the whole of
/// [kConeAlphaLow]..[kConeAlphaHigh] for an icon drawn at [iconSize]:
/// MapLibre's gamma is (blur * 1.19 / 8 + 0.105 / pixel ratio) / size.
/// The pixel ratio is taken as 3, a phone's; on others the fade only
/// shifts slightly.
double coneHaloBlur(double iconSize) =>
    (((kConeAlphaHigh - kConeAlphaLow) / 2) * iconSize - 0.105 / 3) * 8 / 1.19;

/// A bus's heading cone, pointing up (north; the map turns it): a wedge
/// from the centre fading out towards its tip, with soft sides, as an
/// image the map tints with each bus's color. It is drawn only by the
/// layer's halo (see [kConeAlphaLow]): the alpha isn't a distance but the
/// halo's input for the wanted opacity, from 1 at the bus to 0 at the tip
/// (times the layer's opacity). One image for every bus, added once with
/// the map: images added while the map draws can come out with other
/// images' pixels on Android (the cones of other colors, grey squares,
/// bits of map).
Future<Uint8List> busConeSdf({double pixelRatio = 3}) async {
  const r = kConeLength, halfAngle = 34 * math.pi / 180, margin = 2.0, half = r + margin;
  // Softness of the sides, in logical pixels: they fade over this.
  const soft = 2.0;
  return _alphaPng(2 * half, pixelRatio, (x, y) {
    x -= half;
    y -= half;
    final d = math.sqrt(x * x + y * y);
    if (d >= r) return 0;
    final angle = math.atan2(x, -y); // from straight up, clockwise
    // Distance inside from the nearer side (negative outside).
    final inside = d * math.sin(halfAngle - angle.abs());
    final sides = ((inside + soft / 2) / soft).clamp(0.0, 1.0);
    final opacity = (1 - d / r) * sides;
    if (opacity <= 0) return 0;
    // The halo's smoothstep, undone: alpha t in the range gives t²(3-2t).
    final t = 0.5 - math.sin(math.asin(1 - 2 * opacity) / 3);
    return kConeAlphaLow + (kConeAlphaHigh - kConeAlphaLow) * t;
  });
}

/// Map image name of the browsed buses' badge (see [busBadgeSdf]).
const kBusBadgeImage = 'bus-badge';

/// Radius of a browsed bus's colored disc, and the white ring around it
/// (drawn by the map as the icon's halo), in logical pixels.
const kBusBadgeRadius = 11.0, kBusBadgeRing = 2.0;

/// The browsed buses' badge, a disc, as a signed distance field: one
/// image the map tints with each bus's color (icon-color) and rings in
/// white (icon-halo). Alpha is 0.75 on the disc's edge and changes by 1/8
/// per logical pixel, as MapLibre reads SDF icons; the margin holds the
/// ring and its antialiasing.
Future<Uint8List> busBadgeSdf({double pixelRatio = 3}) async {
  const margin = kBusBadgeRing + 1, half = kBusBadgeRadius + margin;
  return _sdfPng(2 * half, pixelRatio, (x, y) {
    final dx = x - half, dy = y - half;
    return math.sqrt(dx * dx + dy * dy) - kBusBadgeRadius;
  });
}

/// A white square PNG of [size] logical pixels whose alpha is the distance
/// field of a shape, the way MapLibre reads SDF icons: 0.75 on the shape's
/// edge, changing by 1/8 per logical pixel. [outside] gives, for a point
/// in logical pixels from the top left, its distance from the edge
/// (negative inside).
Future<Uint8List> _sdfPng(double size, double pixelRatio, double Function(double x, double y) outside) =>
    _alphaPng(size, pixelRatio, (x, y) => 0.75 - outside(x, y) / 8);

/// A white square PNG of [size] logical pixels with the given [alpha]
/// (0 to 1) for each point, in logical pixels from the top left.
Future<Uint8List> _alphaPng(double size, double pixelRatio, double Function(double x, double y) alpha) async {
  final px = (size * pixelRatio).round();
  final rgba = Uint8List(px * px * 4);
  for (var y = 0; y < px; y++) {
    for (var x = 0; x < px; x++) {
      final v = alpha((x + 0.5) / pixelRatio, (y + 0.5) / pixelRatio).clamp(0.0, 1.0);
      final i = (y * px + x) * 4;
      rgba[i] = rgba[i + 1] = rgba[i + 2] = 255;
      rgba[i + 3] = (v * 255).round();
    }
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  final descriptor = ui.ImageDescriptor.raw(buffer, width: px, height: px, pixelFormat: ui.PixelFormat.rgba8888);
  final codec = await descriptor.instantiateCodec();
  final image = (await codec.getNextFrame()).image;
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return png!.buffer.asUint8List();
}
