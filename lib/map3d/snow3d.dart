import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'camera.dart';

/// Snowfall as real 3D particles in a box of air around the player, seen
/// through the map camera — so flakes have depth (near ones bigger and
/// faster across the screen) and move correctly as the camera turns, tilts
/// or the player walks.
class Snow3DPainter extends CustomPainter {
  Snow3DPainter({required this.camera, required this.time, this.count = 900});
  final Camera3D camera;
  final double time;
  final int count;

  static const _box = 520.0; // metres, horizontal extent around the player
  static const _height = 170.0;

  static double _r(int i, int salt) {
    final x = math.sin(i * 12.9898 + salt * 78.233) * 43758.5453;
    return x - x.floorToDouble();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cam = camera
      ..size = size
      ..update();
    final flake = Paint()..color = Colors.white;
    final halo = Paint()
      ..color = const Color(0x55203848)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.8);
    // Centre the box a little ahead of the player so it fills the view.
    final br = cam.bearing * math.pi / 180;
    final cx = cam.px + math.sin(br) * 120, cy = cam.py + math.cos(br) * 120;
    for (var i = 0; i < count; i++) {
      final speed = 6 + 6 * _r(i, 1);
      // World-anchored columns of air, wrapped into the box around the view.
      final wx0 = _r(i, 2) * _box * 8, wy0 = _r(i, 3) * _box * 8;
      final drift = math.sin(time * (0.6 + _r(i, 4)) + i) * 3;
      var x = (wx0 + drift - (cx - _box / 2)) % _box + (cx - _box / 2);
      var y = (wy0 + time * 2.5 - (cy - _box / 2)) % _box + (cy - _box / 2);
      final z = _height - ((_r(i, 5) * _height + time * speed) % _height);
      final p = cam.project(x, y, z);
      if (p == null || p.dx < -10 || p.dx > size.width + 10 || p.dy < -10 || p.dy > size.height + 10) continue;
      final k = cam.scaleAt(x, y, z);
      final r = (0.55 * k).clamp(0.7, 4.5) * (0.7 + 0.6 * _r(i, 6));
      canvas.drawCircle(p, r + 1.4, halo);
      canvas.drawCircle(p, r, flake);
    }
  }

  @override
  bool shouldRepaint(Snow3DPainter old) => true;
}
