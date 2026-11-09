import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Benchmarking overlay (debug menu): frames actually rendered in the last
/// second, plus average and worst build / raster times of those frames.
class FpsOverlay extends StatefulWidget {
  const FpsOverlay({super.key});
  @override
  State<FpsOverlay> createState() => _FpsOverlayState();
}

class _FpsOverlayState extends State<FpsOverlay> {
  final _frames = ListQueue<(int, double, double)>(); // (end µs, build ms, raster ms)
  String _text = '— fps';
  late final _timer = Stream<void>.periodic(const Duration(milliseconds: 500)).listen((_) => _update());

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _timer;
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _timer.cancel();
    super.dispose();
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      // (Timings arrive in small batches; stamping them on arrival is close
      // enough for a per-second rate.)
      _frames.add((DateTime.now().microsecondsSinceEpoch, t.buildDuration.inMicroseconds / 1000, t.rasterDuration.inMicroseconds / 1000));
    }
  }

  void _update() {
    if (!mounted) return;
    final now = DateTime.now().microsecondsSinceEpoch;
    while (_frames.isNotEmpty && now - _frames.first.$1 > 1000000) {
      _frames.removeFirst();
    }
    if (_frames.isEmpty) {
      setState(() => _text = '0 fps (idle)');
      return;
    }
    var b = 0.0, r = 0.0, worst = 0.0;
    for (final f in _frames) {
      b += f.$2;
      r += f.$3;
      if (f.$2 + f.$3 > worst) worst = f.$2 + f.$3;
    }
    final n = _frames.length;
    setState(() => _text = '$n fps\nbuild ${(b / n).toStringAsFixed(1)} ms\nraster ${(r / n).toStringAsFixed(1)} ms\nworst ${worst.toStringAsFixed(1)} ms');
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: Alignment.topLeft,
          child: Container(
            margin: const EdgeInsets.only(left: 6, top: 52),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(6)),
            child: Text(
              _text,
              style: const TextStyle(fontSize: 10.5, color: Color(0xFF7CFC9A), fontFeatures: [FontFeature.tabularFigures()], height: 1.25, decoration: TextDecoration.none),
            ),
          ),
        ),
      ),
    );
  }
}
