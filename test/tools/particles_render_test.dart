// Renders the 3D theme particles: flutter test test/tools/particles_render_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tunetrail/map3d/camera.dart';
import 'package:tunetrail/map3d/particles3d.dart';

void main() {
  test('render particles', () async {
    const size = Size(480, 800);
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    const bgs = [Color(0xFFDCE8F0), Color(0xFF5D4037), Color(0xFF2B0A05), Color(0xFFFBE4EC)];
    for (var k = 0; k < Particle3DKind.values.length; k++) {
      canvas.save();
      canvas.translate(k * size.width, 0);
      canvas.clipRect(Offset.zero & size);
      canvas.drawRect(Offset.zero & size, Paint()..color = bgs[k]);
      final cam = Camera3D();
      final p = Particles3DPainter(camera: cam, time: 7.3, kind: Particle3DKind.values[k]);
      final sw = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        final r2 = ui.PictureRecorder();
        p.paint(Canvas(r2), size);
        r2.endRecording().dispose();
      }
      // ignore: avoid_print
      print('${Particle3DKind.values[k].name}: ${(sw.elapsedMicroseconds / 100 / 1000).toStringAsFixed(3)} ms');
      p.paint(canvas, size);
      canvas.restore();
    }
    final img = await rec.endRecording().toImage((size.width * 4).round(), size.height.round());
    File('build/particles.png').writeAsBytesSync((await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
  });
}
