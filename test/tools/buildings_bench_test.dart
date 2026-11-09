// Benchmark (skipped unless TT_SHIBUYA points at a folder of z14 OpenFreeMap
// tiles named 14_x_y.pbf): time to record the city-buildings layer per frame
// while the camera turns, as on the map when moving.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tunetrail/map3d/buildings3d.dart';
import 'package:tunetrail/map3d/camera.dart';
import 'package:tunetrail/map3d/ground_painter.dart';
import 'package:tunetrail/map3d/map_data.dart';
import 'package:tunetrail/map3d/palette.dart';
import 'package:tunetrail/map3d/tile_data.dart';

void main() {
  final dir = Platform.environment['TT_SHIBUYA'];
  test('buildings paint benchmark', () async {
    final tiles = <CityBuildingTile>[];
    for (final f in Directory(dir!).listSync().whereType<File>().where((f) => f.path.endsWith('.pbf'))) {
      final p = f.uri.pathSegments.last.replaceAll('.pbf', '').split('_');
      tiles.add(processBuildingTile(TileJob(14, int.parse(p[1]), int.parse(p[2]), f.readAsBytesSync(), 35.6595, 139.7005)));
    }
    for (final t in tiles) {
      final b = t.buildings.first;
      // ignore: avoid_print
      print('tile ${t.buildings.length} first at ${b.cx.round()},${b.cy.round()}');
    }
    final n = tiles.fold<int>(0, (a, t) => a + t.buildings.length);
    const size = Size(2560, 1440);
    final cam = Camera3D();
    // Warm up.
    for (var i = 0; i < 30; i++) {
      cam
        ..bearing = i * 3.0
        ..size = size
        ..update();
      final rec = ui.PictureRecorder();
      CityBuildingRenderer.paint(Canvas(rec), cam, tiles, kObsidian);
      rec.endRecording().dispose();
    }
    final sw = Stopwatch()..start();
    const frames = 200;
    for (var i = 0; i < frames; i++) {
      cam
        ..bearing = i * 1.8
        ..px = i * 0.8
        ..size = size
        ..update();
      final rec = ui.PictureRecorder();
      CityBuildingRenderer.paint(Canvas(rec), cam, tiles, kObsidian);
      rec.endRecording().dispose();
    }
    final buildingsMs = sw.elapsedMicroseconds / frames / 1000;
    // The whole ground layer (roads, land, water + buildings), if the
    // matching OSM tiles are given in TT_SHIBUYA_OSM.
    final osm = Platform.environment['TT_SHIBUYA_OSM'];
    if (osm != null) {
      final map = MapData(Directory.systemTemp.createTempSync('md'));
      for (final f in Directory(osm).listSync().whereType<File>()) {
        final p = f.uri.pathSegments.last.replaceAll('.mvt', '').split('_');
        map.tiles['14/${p[1]}/${p[2]}'] = processTile(TileJob(14, int.parse(p[1]), int.parse(p[2]), f.readAsBytesSync(), 35.6595, 139.7005));
      }
      map.buildingsEnabled = true;
      for (var i = 0; i < tiles.length; i++) {
        map.buildingTiles['b$i'] = tiles[i];
      }
      final gp = GroundPainter(camera: cam, map: map, palette: kObsidian, catchRadius: 40, repaint: ValueNotifier(0));
      for (final on in [false, true]) {
        map.buildingsEnabled = on;
        if (on) {
          for (var i = 0; i < tiles.length; i++) {
            map.buildingTiles['b$i'] = tiles[i];
          }
        }
        for (var i = 0; i < 30; i++) {
          cam.bearing = i * 3.0;
          final rec = ui.PictureRecorder();
          gp.paint(Canvas(rec), size);
          rec.endRecording().dispose();
        }
        final sw2 = Stopwatch()..start();
        for (var i = 0; i < frames; i++) {
          cam
            ..bearing = i * 1.8
            ..px = i * 0.8;
          final rec = ui.PictureRecorder();
          gp.paint(Canvas(rec), size);
          rec.endRecording().dispose();
        }
        // ignore: avoid_print
        print('BENCH ground (buildings $on): ${(sw2.elapsedMicroseconds / frames / 1000).toStringAsFixed(2)} ms/frame');
      }
    }
    // ignore: avoid_print
    print('BENCH $n buildings, ${CityBuildingRenderer.lastDrawn} drawn: ${buildingsMs.toStringAsFixed(2)} ms/frame');
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(Offset.zero & size, Paint()..color = kObsidian.ground);
    cam
      ..bearing = 40
      ..px = 0
      ..update();
    CityBuildingRenderer.paint(c, cam, tiles, kObsidian);
    final img = await rec.endRecording().toImage(1280, 720);
    File('build/shibuya.png').writeAsBytesSync((await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
  }, skip: dir == null);
}
