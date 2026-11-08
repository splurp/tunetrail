import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:tunetrail_core/tunetrail_core.dart';

/// Network image with a persistent on-disk cache (works on every platform
/// without native plugins). Album/artist art is immutable, so cached files
/// never need revalidation.
class NetImage extends ImageProvider<NetImage> {
  const NetImage(this.url);
  final String url;

  static Directory? cacheDir;
  static final http.Client _client = http.Client();
  static int _active = 0;
  static final List<Completer<void>> _queue = [];
  static const _maxConcurrent = 8;

  @override
  Future<NetImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(NetImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _load(decode),
        scale: 1,
        debugLabel: url,
      );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await _bytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  Future<Uint8List> _bytes() async {
    final dir = cacheDir;
    final name = (hashString(url) & 0x7FFFFFFFFFFFFFFF).toRadixString(36);
    final f = dir == null ? null : File('${dir.path}/$name');
    if (f != null && await f.exists()) {
      return f.readAsBytes();
    }
    await _acquire();
    try {
      final res = await _client.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
        throw StateError('image ${res.statusCode}');
      }
      if (f != null) unawaited(f.writeAsBytes(res.bodyBytes));
      return res.bodyBytes;
    } finally {
      _release();
    }
  }

  static Future<void> _acquire() async {
    if (_active < _maxConcurrent) {
      _active++;
      return;
    }
    final c = Completer<void>();
    _queue.add(c);
    await c.future;
    _active++;
  }

  static void _release() {
    _active--;
    if (_queue.isNotEmpty) _queue.removeAt(0).complete();
  }

  @override
  bool operator ==(Object other) => other is NetImage && other.url == url;
  @override
  int get hashCode => url.hashCode;
}

/// Album art / artist picture with placeholder and size-limited decoding.
class Art extends StatelessWidget {
  const Art(this.url, {super.key, this.size = 56, this.radius = 6, this.circle = false, this.decodeSize});
  final String url;
  final double size;
  final double radius;
  final bool circle;
  final int? decodeSize;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF1E2233),
        borderRadius: circle ? null : BorderRadius.circular(radius),
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
      ),
      child: Icon(Icons.music_note, size: size * 0.45, color: Colors.white24),
    );
    if (url.isEmpty) return placeholder;
    final img = Image(
      image: ResizeImage(NetImage(url), width: decodeSize ?? (size * dpr).round(), policy: ResizeImagePolicy.fit),
      width: size,
      height: size,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      frameBuilder: (c, child, frame, sync) => frame == null && !sync ? placeholder : child,
      errorBuilder: (c, e, s) => placeholder,
    );
    return circle
        ? ClipOval(child: img)
        : ClipRRect(borderRadius: BorderRadius.circular(radius), child: img);
  }
}
