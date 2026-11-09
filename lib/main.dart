import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:path_provider/path_provider.dart';

import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Desktop video playback (Movie editions) via libmdk; mobile uses the
  // platform players.
  fvp.registerWith(options: {
    'platforms': ['windows', 'linux', 'macos'],
  });
  // Decoded-image memory budget (thumbnails are decoded at display size).
  PaintingBinding.instance.imageCache.maximumSizeBytes = 160 << 20;
  PaintingBinding.instance.imageCache.maximumSize = 2000;
  // Previews, art and video are streamed, never stored on the device.
  // Remove anything older versions saved.
  try {
    final cache = await getApplicationCacheDirectory();
    final art = Directory('${cache.path}/art');
    if (await art.exists()) await art.delete(recursive: true);
    final samples = Directory('${Directory.systemTemp.path}/tunetrail_samples');
    if (await samples.exists()) await samples.delete(recursive: true);
  } catch (_) {}
  runApp(const TunetrailApp());
}
