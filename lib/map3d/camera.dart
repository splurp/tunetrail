import 'dart:math' as math;
import 'dart:ui';

/// Third-person camera orbiting the player, looking down at the ground
/// plane (Pokémon-Go style). World units are metres: x east, y north, z up.
class Camera3D {
  /// Heading the camera looks towards, degrees clockwise from north.
  double bearing = 0;

  /// Angle above the horizon, degrees.
  double pitch = 40;

  /// Distance from the camera to the player, metres.
  double distance = 230;

  Size size = Size.zero;

  /// Player position in world metres.
  double px = 0, py = 0;

  // Derived (call [update]).
  late double _cos, _sin, _b, _h, _d, focal, cx, cy;

  /// Ground points closer than this (camera-aligned forward metres, negative
  /// = behind the player) are clipped.
  late double yNear;
  double yFar = 1150;

  void update() {
    final br = bearing * math.pi / 180;
    _cos = math.cos(br);
    _sin = math.sin(br);
    final pr = pitch * math.pi / 180;
    _d = distance;
    _b = distance * math.cos(pr);
    _h = distance * math.sin(pr);
    cx = size.width / 2;
    cy = size.height * 0.64;
    // Put the horizon ~6% from the top of the screen.
    focal = (cy - size.height * 0.06) / math.tan(pr);
    yNear = -0.75 * distance;
  }

  /// World (x,y) → camera-aligned ground coords (xa right, ya forward).
  @pragma('vm:prefer-inline')
  double alignX(double x, double y) => (x - px) * _cos - (y - py) * _sin;
  @pragma('vm:prefer-inline')
  double alignY(double x, double y) => (x - px) * _sin + (y - py) * _cos;

  /// Camera-space depth for an aligned point at height z.
  @pragma('vm:prefer-inline')
  double depth(double ya, double z) => (ya * _b + _d * _d - z * _h) / _d;

  /// Screen x/y for an aligned point (xa, ya, z) with depth [zc].
  @pragma('vm:prefer-inline')
  double sx(double xa, double zc) => cx + focal * xa / zc;
  @pragma('vm:prefer-inline')
  double sy(double ya, double z, double zc) => cy - focal * ((ya * _h + z * _b) / _d) / zc;

  /// Projects a world point; returns null when behind the near plane.
  Offset? project(double x, double y, [double z = 0]) {
    final xa = alignX(x, y), ya = alignY(x, y);
    if (ya < yNear) return null;
    final zc = depth(ya, z);
    if (zc <= 1) return null;
    return Offset(sx(xa, zc), sy(ya, z, zc));
  }

  /// Pixels per world metre at the depth of a ground point (for scaling
  /// billboards).
  double scaleAt(double x, double y, [double z = 0]) {
    final ya = alignY(x, y);
    final zc = depth(ya, z);
    return zc <= 1 ? 0 : focal / zc;
  }

  /// Screen y of the horizon.
  double get horizonY => cy - focal * (_h / _b);

  /// Screen y of the ground at aligned forward distance [ya].
  double groundY(double ya) => sy(ya, 0, depth(ya, 0));

  /// Visible half-width (metres) at aligned forward distance [ya].
  double halfWidthAt(double ya) => depth(ya, 0) * (size.width / 2) / focal;

  /// Converts a screen-space joystick vector (x right, y up) to world
  /// east/north given the camera bearing.
  (double, double) screenToWorldDir(double x, double y) => (x * _cos + y * _sin, -x * _sin + y * _cos);

  /// World direction (east,north) → aligned (right, forward).
  (double, double) worldDirToAligned(double ex, double ny) => (ex * _cos - ny * _sin, ex * _sin + ny * _cos);
}
