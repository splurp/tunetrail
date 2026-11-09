// Renders the 3D figure with outfits to PNGs for visual checks:
//   flutter test test/tools/figure_render_test.dart   (writes build/fig_*.png)
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tunetrail/map3d/camera.dart';
import 'package:tunetrail/map3d/figure3d.dart';
import 'package:tunetrail/ui/widgets/stick_figure.dart';

void main() {
  test('render figure', () async {
    const size = Size(360, 420);
    final looks = [
      const FigureLook(color: Color(0xFFE9E6FF), shirt: 'shirt_tee_red', backpack: 'bag_classic', pet: 'pet_dog', hat: 'hat_cap'),
      const FigureLook(color: Color(0xFFE9E6FF), shirt: 'shirt_striped', backpack: 'bag_jetpack', pet: 'pet_cat', hat: 'hat_tophat'),
      const FigureLook(color: Color(0xFFE9E6FF), shirt: 'shirt_tux', backpack: 'bag_wings', hat: 'hat_crown'),
      const FigureLook(color: Color(0xFFE9E6FF), shirt: 'shirt_hoodie', backpack: 'bag_boombox', pet: 'pet_robot', hat: 'hat_cowboy'),
    ];
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    const facings = [0.0, 90.0, 180.0, 270.0];
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width * facings.length, size.height * looks.length), Paint()..color = const Color(0xFF2A2A30));
    for (var r = 0; r < looks.length; r++) {
      for (var c = 0; c < facings.length; c++) {
        canvas.save();
        canvas.translate(c * size.width, r * size.height);
        canvas.clipRect(Offset.zero & size);
        final cam = Camera3D()..distance = double.parse(Platform.environment["FIG_DIST"] ?? "120");
        final idle = IdleDirector(1)..walk = 1;
        Figure3DPainter(camera: cam, look: looks[r], time: 0.3, idle: idle, facing: facings[c], accent: Colors.purpleAccent, contrast: Colors.orange)
            .paint(canvas, size);
        canvas.restore();
      }
    }
    final img = await rec.endRecording().toImage((size.width * facings.length).round(), (size.height * looks.length).round());
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    File('build/fig_outfits.png')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}
