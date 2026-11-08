import 'package:flutter/material.dart';

import '../app.dart';
import 'net_image.dart';

/// Persistent "now playing" bar shown above the navigation bar.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final audio = GameScope.of(context).audio;
    return ListenableBuilder(
      listenable: audio,
      builder: (context, _) {
        final s = audio.current;
        if (s == null) return const SizedBox.shrink();
        final frac = audio.duration.inMilliseconds == 0
            ? 0.0
            : (audio.position.inMilliseconds / audio.duration.inMilliseconds).clamp(0.0, 1.0);
        return Material(
          color: const Color(0xFF141417),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            LinearProgressIndicator(value: frac, minHeight: 2, backgroundColor: Colors.transparent),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(children: [
                Art(s.cover(56), size: 38),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(
                      [s.artistName, if (audio.queueName != null) audio.queueName!, if (audio.error != null) audio.error!].join(' • '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Colors.white60),
                    ),
                  ]),
                ),
                if (audio.queue.length > 1)
                  IconButton(icon: const Icon(Icons.skip_previous), onPressed: audio.previous),
                audio.loading
                    ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                    : IconButton(icon: Icon(audio.playing ? Icons.pause_circle : Icons.play_circle, size: 32), onPressed: audio.toggle),
                if (audio.queue.length > 1) IconButton(icon: const Icon(Icons.skip_next), onPressed: audio.next),
                IconButton(icon: const Icon(Icons.close), onPressed: audio.stop),
              ]),
            ),
          ]),
        );
      },
    );
  }
}
