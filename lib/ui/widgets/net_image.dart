import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class _HttpStatus implements Exception {
  _HttpStatus(this.code);
  final int code;
  @override
  String toString() => 'image $code';
}

/// Network image, streamed: nothing is written to disk (album art is kept
/// only in Flutter's in-memory image cache while the app runs).
class NetImage extends ImageProvider<NetImage> {
  const NetImage(this.url);
  final String url;

  static http.Client _client = http.Client();
  static int _active = 0;
  static final List<Completer<void>> _queue = [];
  static const _maxConcurrent = 10;

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

  /// Slow or dropped connections (mobile data) get a few more tries.
  Future<Uint8List> _bytes() async {
    for (var attempt = 0;; attempt++) {
      try {
        return await _fetch();
      } catch (e) {
        if (attempt >= 2 || (e is _HttpStatus && e.code == 404)) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 700 * (attempt + 1)));
      }
    }
  }

  Future<Uint8List> _fetch() async {
    await _acquire();
    final client = _client;
    try {
      final res = await client.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) throw _HttpStatus(res.statusCode);
      return res.bodyBytes;
    } on TimeoutException {
      // A hung download usually means a dead pooled connection (mobile
      // networks drop idle ones silently): start over with fresh ones.
      if (identical(client, _client)) {
        _client = http.Client();
        client.close();
      }
      rethrow;
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
  }

  /// Newest requests first: those are the images on screen now (a fast
  /// scroll queues hundreds that are already out of view).
  static void _release() {
    if (_queue.isNotEmpty) {
      _queue.removeLast().complete();
    } else {
      _active--;
    }
  }

  @override
  bool operator ==(Object other) => other is NetImage && other.url == url;
  @override
  int get hashCode => url.hashCode;
}

/// Album art / artist picture with placeholder and size-limited decoding.
/// An image that fails to load tries again a little later (and again,
/// further apart) while it's on screen.
class Art extends StatefulWidget {
  const Art(this.url, {super.key, this.size = 56, this.radius = 6, this.circle = false, this.decodeSize});
  final String url;
  final double size;
  final double radius;
  final bool circle;
  final int? decodeSize;

  @override
  State<Art> createState() => _ArtState();
}

class _ArtState extends State<Art> {
  int _attempt = 0;
  Timer? _retry;

  @override
  void didUpdateWidget(Art old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _retry?.cancel();
      _attempt = 0;
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  void _failed(ImageProvider provider) {
    if (_retry?.isActive ?? false) return;
    if (_attempt >= 8) return;
    _retry = Timer(Duration(seconds: 4 * (1 << _attempt.clamp(0, 4))), () {
      if (!mounted) return;
      provider.evict();
      setState(() => _attempt++);
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF1B1B1F),
        borderRadius: widget.circle ? null : BorderRadius.circular(widget.radius),
        shape: widget.circle ? BoxShape.circle : BoxShape.rectangle,
      ),
      child: Icon(Icons.music_note, size: size * 0.45, color: Colors.white24),
    );
    if (widget.url.isEmpty) return placeholder;
    final provider = ResizeImage(NetImage(widget.url), width: widget.decodeSize ?? (size * dpr).round(), policy: ResizeImagePolicy.fit);
    final img = Image(
      key: ValueKey(_attempt),
      image: provider,
      width: size,
      height: size,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      frameBuilder: (c, child, frame, sync) => frame == null && !sync ? placeholder : child,
      errorBuilder: (c, e, s) {
        _failed(provider);
        return placeholder;
      },
    );
    return widget.circle
        ? ClipOval(child: img)
        : ClipRRect(borderRadius: BorderRadius.circular(widget.radius), child: img);
  }
}
