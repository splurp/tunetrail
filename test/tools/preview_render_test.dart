// Renders the shop's 3D figure preview: flutter test test/tools/preview_render_test.dart
import 'package:flutter/rendering.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tunetrail/ui/widgets/figure_preview.dart';
import 'package:tunetrail/ui/widgets/stick_figure.dart';

void main() {
  testWidgets('render preview', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      home: RepaintBoundary(
        key: key,
        child: Container(
          color: const Color(0xFF1E1E24),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Figure3DPreview(look: FigureLook(color: Color(0xFFE9E6FF), shirt: 'shirt_hoodie', backpack: 'bag_classic', hat: 'hat_tophat'), size: 200),
            Figure3DPreview(look: FigureLook(color: Color(0xFFE9E6FF), pet: 'pet_dog', hat: 'hat_cap'), size: 200),
            Figure3DPreview(look: FigureLook(color: Color(0xFFE9E6FF), shirt: 'shirt_tux', backpack: 'bag_wings'), size: 200),
          ]),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() async {
      final img = await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage();
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File('build/preview.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  });
}
