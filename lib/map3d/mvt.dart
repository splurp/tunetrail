import 'dart:convert';
import 'dart:typed_data';

/// Minimal, allocation-light Mapbox Vector Tile (MVT v2) decoder.
///
/// Only what Tunetrail needs: layer names, feature tags and geometries
/// (points, lines, polygon rings) in tile units (0..extent).
class MvtLayer {
  MvtLayer(this.name, this.extent, this.features);
  final String name;
  final int extent;
  final List<MvtFeature> features;
}

enum MvtGeomType { unknown, point, line, polygon }

class MvtFeature {
  MvtFeature(this.type, this.tags, this.geometry);
  final MvtGeomType type;
  final Map<String, Object?> tags;

  /// Parts: for points one part per point; lines one part per line; polygons
  /// one part per ring. Each part is a flat [x0, y0, x1, y1, ...] list.
  final List<Float32List> geometry;

  String? str(String k) {
    final v = tags[k];
    return v is String ? v : null;
  }

  double? number(String k) {
    final v = tags[k];
    return v is num ? v.toDouble() : null;
  }
}

class _Reader {
  _Reader(this.b, [this.pos = 0, int? end]) : end = end ?? b.length;
  final Uint8List b;
  int pos;
  final int end;

  bool get more => pos < end;

  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final byte = b[pos++];
      if (shift < 49) {
        result += (byte & 0x7F) * (1 << shift);
      }
      if (byte & 0x80 == 0) return result;
      shift += 7;
    }
  }

  (int, int) key() {
    final k = varint();
    return (k >> 3, k & 7);
  }

  _Reader sub() {
    final len = varint();
    final r = _Reader(b, pos, pos + len);
    pos += len;
    return r;
  }

  String string() {
    final len = varint();
    final s = utf8.decode(Uint8List.sublistView(b, pos, pos + len), allowMalformed: true);
    pos += len;
    return s;
  }

  double float32() {
    final v = ByteData.sublistView(b, pos, pos + 4).getFloat32(0, Endian.little);
    pos += 4;
    return v;
  }

  double float64() {
    final v = ByteData.sublistView(b, pos, pos + 8).getFloat64(0, Endian.little);
    pos += 8;
    return v;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        varint();
      case 1:
        pos += 8;
      case 2:
        pos += varint();
      case 5:
        pos += 4;
      default:
        throw const FormatException('bad wire type');
    }
  }

  List<int> packed() {
    final r = sub();
    final out = <int>[];
    while (r.more) {
      out.add(r.varint());
    }
    return out;
  }
}

/// Decodes the layers whose names are in [wanted] (null = all).
List<MvtLayer> decodeMvt(Uint8List bytes, {Set<String>? wanted}) {
  final r = _Reader(bytes);
  final layers = <MvtLayer>[];
  while (r.more) {
    final (field, wire) = r.key();
    if (field == 3 && wire == 2) {
      final l = _decodeLayer(r.sub(), wanted);
      if (l != null) layers.add(l);
    } else {
      r.skip(wire);
    }
  }
  return layers;
}

MvtLayer? _decodeLayer(_Reader r, Set<String>? wanted) {
  var name = '';
  var extent = 4096;
  final keys = <String>[];
  final values = <Object?>[];
  final rawFeatures = <_Reader>[];
  while (r.more) {
    final (field, wire) = r.key();
    switch (field) {
      case 1:
        name = r.string();
        if (wanted != null && !wanted.contains(name)) return null;
      case 2:
        rawFeatures.add(r.sub());
      case 3:
        keys.add(r.string());
      case 4:
        values.add(_decodeValue(r.sub()));
      case 5:
        extent = r.varint();
      default:
        r.skip(wire);
    }
  }
  final features = <MvtFeature>[];
  for (final fr in rawFeatures) {
    var type = MvtGeomType.unknown;
    List<int> tags = const [];
    List<int> geom = const [];
    while (fr.more) {
      final (field, wire) = fr.key();
      switch (field) {
        case 2:
          tags = fr.packed();
        case 3:
          type = MvtGeomType.values[fr.varint().clamp(0, 3)];
        case 4:
          geom = fr.packed();
        default:
          fr.skip(wire);
      }
    }
    final t = <String, Object?>{};
    for (var i = 0; i + 1 < tags.length; i += 2) {
      if (tags[i] < keys.length && tags[i + 1] < values.length) {
        t[keys[tags[i]]] = values[tags[i + 1]];
      }
    }
    features.add(MvtFeature(type, t, _decodeGeometry(geom, type)));
  }
  return MvtLayer(name, extent, features);
}

Object? _decodeValue(_Reader r) {
  Object? v;
  while (r.more) {
    final (field, wire) = r.key();
    switch (field) {
      case 1:
        v = r.string();
      case 2:
        v = r.float32();
      case 3:
        v = r.float64();
      case 4:
      case 5:
        v = r.varint();
      case 6:
        final n = r.varint();
        v = (n >> 1) ^ -(n & 1);
      case 7:
        v = r.varint() != 0;
      default:
        r.skip(wire);
    }
  }
  return v;
}

List<Float32List> _decodeGeometry(List<int> g, MvtGeomType type) {
  final parts = <Float32List>[];
  var x = 0, y = 0;
  var i = 0;
  List<double> cur = [];
  void flush() {
    if (cur.isNotEmpty) parts.add(Float32List.fromList(cur));
    cur = [];
  }

  while (i < g.length) {
    final cmd = g[i] & 7;
    final count = g[i] >> 3;
    i++;
    if (cmd == 1) {
      // MoveTo
      for (var k = 0; k < count && i + 1 < g.length; k++) {
        if (type != MvtGeomType.point) flush();
        x += _zz(g[i++]);
        y += _zz(g[i++]);
        if (type == MvtGeomType.point) {
          parts.add(Float32List.fromList([x.toDouble(), y.toDouble()]));
        } else {
          cur.add(x.toDouble());
          cur.add(y.toDouble());
        }
      }
    } else if (cmd == 2) {
      for (var k = 0; k < count && i + 1 < g.length; k++) {
        x += _zz(g[i++]);
        y += _zz(g[i++]);
        cur.add(x.toDouble());
        cur.add(y.toDouble());
      }
    } else if (cmd == 7) {
      flush();
    } else {
      break;
    }
  }
  flush();
  return parts;
}

int _zz(int n) => (n >> 1) ^ -(n & 1);

/// Signed area of a ring (positive = clockwise when y points down, which is
/// how MVT winds exterior rings).
double ringArea(Float32List r) {
  var a = 0.0;
  final n = r.length ~/ 2;
  for (var i = 0, j = n - 1; i < n; j = i++) {
    a += (r[j * 2] - r[i * 2]) * (r[j * 2 + 1] + r[i * 2 + 1]);
  }
  return a / 2;
}

/// Groups polygon rings into polygons: [exterior, hole, hole...].
List<List<Float32List>> groupRings(List<Float32List> rings) {
  final polys = <List<Float32List>>[];
  for (final r in rings) {
    if (r.length < 6) continue;
    final a = ringArea(r);
    if (a == 0) continue;
    // MVT spec: exterior rings are clockwise (y down) => positive area.
    if (a > 0 || polys.isEmpty) {
      polys.add([r]);
    } else {
      polys.last.add(r);
    }
  }
  return polys;
}
