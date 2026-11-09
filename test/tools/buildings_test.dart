// Dev check (skipped unless TT_OFM is set): decodes a real OpenFreeMap tile.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:tunetrail/map3d/camera.dart';
import 'package:tunetrail/map3d/palette.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunetrail/map3d/buildings3d.dart';
import 'package:tunetrail/map3d/tile_data.dart';

void main() {
  final path = Platform.environment['TT_OFM'];
  test('city buildings with heights', () async {
    final t = processBuildingTile(TileJob(14, 4824, 6157, File(path!).readAsBytesSync(), 40.758, -73.9855));
    final hs = [for (final b in t.buildings) b.height]..sort();
    // ignore: avoid_print
    print('${t.buildings.length} buildings, median ${hs[hs.length ~/ 2]} m, max ${hs.last} m');
    expect(t.buildings.length, greaterThan(100));
    expect(hs.last, greaterThan(200));
    const size = Size(480, 800);
    final cam = Camera3D()..bearing = 30;
    cam.size = size;
    cam.update();
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawRect(Offset.zero & size, Paint()..color = kObsidian.ground);
    CityBuildingRenderer.paint(canvas, cam, [t], kObsidian);
    final img = await rec.endRecording().toImage(480, 800);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    File('build/city.png').writeAsBytesSync(png!.buffer.asUint8List());
  }, skip: path == null);
}
