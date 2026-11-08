// Renders the low-poly props to PNGs for visual checks:
//   flutter test test/tools/props_render_test.dart
// (writes build/props_*.png)
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tunetrail/map3d/camera.dart';
import 'package:tunetrail/map3d/props3d.dart';

void main() {
  test('render props', () async {
    for (final (name, set, bearing) in [
      ('vapor_215', PropSet.vaporMonuments, 215.0),
      ('vapor_30', PropSet.vaporMonuments, 30.0),
      ('sakura', PropSet.sakuraTrees, 0.0),
    ]) {
      final cam = Camera3D()
        ..bearing = bearing
        ..px = 1000
        ..py = 1000;
      const size = Size(480, 800);
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFE9D5F3));
      PropsPainter(camera: cam, set: set, fog: const Color(0xFFB9F2F0)).paint(canvas, size);
      final img = await rec.endRecording().toImage(480, 800);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File('build/props_$name.png')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(png!.buffer.asUint8List());
    }
  });
}
