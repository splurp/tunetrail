// Dev check (skipped unless TT_BEAT_DIR is set): runs the beat analyser on
// raw 8 kHz float32 decodes of real previews.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunetrail/game/audio_service.dart';

void main() {
  final dir = Platform.environment['TT_BEAT_DIR'];
  test('real previews', () {
    for (final (f, bpm, truth) in [('630827252', 95.7, 0.38), ('t_630827242', 103.88, 0.055), ('t_916424', 112.3, 0.265)]) {
      final b = File('$dir/$f.f32').readAsBytesSync();
      final x = Float32List.view(b.buffer, b.offsetInBytes, b.lengthInBytes ~/ 4);
      final info = analyzeBeats((x, 8000, bpm))!;
      final period = 60 / bpm;
      var d = (info.phase - truth) % period;
      if (d > period / 2) d -= period;
      // ignore: avoid_print
      print('$f phase ${info.phase.toStringAsFixed(3)} truth $truth err ${(d * 1000).round()} ms');
      expect(d.abs(), lessThan(0.03));
    }
  }, skip: dir == null);
}
