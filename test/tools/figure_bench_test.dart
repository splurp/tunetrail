// Benchmark: cost of drawing one 3D figure with a full outfit.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tunetrail/map3d/camera.dart';
import 'package:tunetrail/map3d/figure3d.dart';
import 'package:tunetrail/ui/widgets/stick_figure.dart';

void main() {
  test('figure paint cost', () {
    const looks = {
      'bare': FigureLook(color: Color(0xFFE9E6FF)),
      'full': FigureLook(color: Color(0xFFE9E6FF), shirt: 'shirt_hoodie', backpack: 'bag_wings', pet: 'pet_hamster', hat: 'hat_tophat'),
    };
    for (final e in looks.entries) {
      final cam = Camera3D()..distance = 150;
      final idle = IdleDirector(1);
      for (var i = 0; i < 50; i++) {
        final r = ui.PictureRecorder();
        Figure3DPainter(camera: cam, look: e.value, time: i * 0.016, idle: idle, facing: 200, accent: Colors.transparent, contrast: Colors.white).paint(Canvas(r), const Size(130, 160));
        r.endRecording().dispose();
      }
      final sw = Stopwatch()..start();
      for (var i = 0; i < 300; i++) {
        final r = ui.PictureRecorder();
        Figure3DPainter(camera: cam, look: e.value, time: i * 0.016, idle: idle, facing: 200, accent: Colors.transparent, contrast: Colors.white).paint(Canvas(r), const Size(130, 160));
        r.endRecording().dispose();
      }
      // ignore: avoid_print
      print('${e.key}: ${(sw.elapsedMicroseconds / 300 / 1000).toStringAsFixed(3)} ms');
    }
  });
}
