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
      ('vapor_0', PropSet.vaporMonuments, 0.0),
      ('vapor_90', PropSet.vaporMonuments, 90.0),
      ('vapor_200', PropSet.vaporMonuments, 200.0),
      ('sakura', PropSet.sakuraTrees, 0.0),
      ('candy', PropSet.lollipops, 30.0),
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
    // Close-up of the bust.
    final cam = Camera3D()
      ..bearing = 0
      ..pitch = 12
      ..distance = 300
      ..px = 0
      ..py = 0;
    const size = Size(480, 800);
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFE9D5F3));
    PropsPainter(camera: cam, set: PropSet.vaporMonuments, fog: const Color(0xFFB9F2F0))
        .debugDraw(canvas, size, PropInstance(LowPolyMesh.fromBinary(File('assets/models/bust_hi.bin').readAsBytesSync().buffer.asByteData(), const Color(0xFFF4EEF8)), 0, 900, scale: 3.5, yaw: -(180 + 30) * 3.14159 / 180));
    final img = await rec.endRecording().toImage(480, 800);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    File('build/props_bust.png').writeAsBytesSync(png!.buffer.asUint8List());
    final rec2 = ui.PictureRecorder();
    final c2 = Canvas(rec2);
    c2.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFF6E8EE));
    for (var i = 0; i < 2; i++) {
      PropsPainter(camera: cam, set: PropSet.sakuraTrees, fog: const Color(0xFFFFF4F8))
          .debugDraw(c2, size, PropInstance(PropsPainter.treeMesh(i), -180.0 + i * 360, 1100, scale: 14, yaw: i * 1.3));
    }
    final img2 = await rec2.endRecording().toImage(480, 800);
    final rec3 = ui.PictureRecorder();
    final c3 = Canvas(rec3);
    c3.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFDE7F3));
    for (var i = 0; i < 4; i++) {
      PropsPainter(camera: cam, set: PropSet.lollipops, fog: const Color(0xFFFFF0FA))
          .debugDraw(c3, size, PropInstance(PropsPainter.lollipopMesh(i), -330.0 + i * 220, 1100, scale: 9, yaw: 0.4 + i * 0.5));
    }
    final img3 = await rec3.endRecording().toImage(480, 800);
    File('build/props_lolli.png').writeAsBytesSync((await img3.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
    File('build/props_tree.png').writeAsBytesSync((await img2.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
  });
}
