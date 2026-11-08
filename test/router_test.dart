import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunetrail/map3d/map_data.dart';
import 'package:tunetrail/map3d/router.dart';
import 'package:tunetrail/map3d/tile_data.dart';

void main() {
  test('routes along crossing roads that share no vertex', () {
    // An east-west road and a north-south road crossing at (0,0), plus a
    // dead-end spur — like simplified vector-tile geometry.
    final tile = WorldTile(
      z: 14,
      x: 0,
      y: 0,
      layers: const {},
      buckets: const {},
      buildings: const [],
      roads: [
        Float32List.fromList([-300, 0, 300, 0]),
        Float32List.fromList([0, -300, 0, 300]),
        Float32List.fromList([200, 0, 200, 150]), // T-junction ending on the E-W road
      ],
      flags: Uint32List(kZoneGrid * kZoneGrid),
      counts: {for (final c in ZoneCount.values) c: Uint16List(kZoneGrid * kZoneGrid)},
      minX: -1000,
      minY: -1000,
      maxX: 1000,
      maxY: 1000,
    );
    final md = MapData(Directory.systemTemp)
      ..originLat = 0
      ..originLon = 0;
    md.tiles[tile.key] = tile;
    final r = RoadRouter(md).route(0, -250, 200, 140);
    final pts = [for (var i = 0; i < r.length; i += 2) (r[i], r[i + 1])];
    // Goes up the N-S road, through the crossing, along E-W, up the spur.
    expect(pts.any((p) => p.$1.abs() < 1 && p.$2.abs() < 1), isTrue);
    expect(pts.any((p) => (p.$1 - 200).abs() < 1 && p.$2.abs() < 1), isTrue);
    expect(pts.first, (0.0, -250.0));
    expect(pts.last, (200.0, 140.0));

    final prints = footprintsAlong(r);
    expect(prints.length, greaterThan(40));
  });
}
