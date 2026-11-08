import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'ui/app.dart';
import 'ui/widgets/net_image.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Decoded-image memory budget (thumbnails are decoded at display size).
  PaintingBinding.instance.imageCache.maximumSizeBytes = 160 << 20;
  PaintingBinding.instance.imageCache.maximumSize = 2000;
  try {
    final cache = await getApplicationCacheDirectory();
    final dir = Directory('${cache.path}/art');
    await dir.create(recursive: true);
    NetImage.cacheDir = dir;
  } catch (_) {
    // Disk cache is optional.
  }
  runApp(const TunetrailApp());
}
