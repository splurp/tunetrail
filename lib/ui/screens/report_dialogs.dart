import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../app.dart';
import '../widgets/cards.dart';

Widget _bullet(String t) => Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('•  ', style: TextStyle(color: kTextSecondary)),
        Expanded(child: Text(t, style: const TextStyle(color: kTextSecondary, height: 1.35))),
      ]),
    );

Future<void> _reportDialog(
  BuildContext context, {
  required String title,
  required List<Widget> intro,
  required List<String> reasons,
  required Future<void> Function(String reason, String details) send,
}) async {
  final g = GameScope.read(context);
  final details = TextEditingController();
  String? reason;
  var busy = false;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
      return AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              ...intro,
              const SizedBox(height: 12),
              const Text('Reason', style: TextStyle(fontWeight: FontWeight.w700)),
              RadioGroup<String>(
                groupValue: reason,
                onChanged: (v) => setD(() => reason = v),
                child: Column(children: [
                  for (final r in reasons) RadioListTile<String>(value: r, title: Text(r), dense: true, contentPadding: EdgeInsets.zero),
                ]),
              ),
              TextField(
                controller: details,
                maxLength: 1000,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(hintText: 'What happened? (optional)'),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: reason == null || busy
                ? null
                : () async {
                    setD(() => busy = true);
                    try {
                      await send(reason!, details.text.trim());
                      if (ctx.mounted) Navigator.pop(ctx);
                      g.toast('Thanks — your report was sent');
                    } catch (e) {
                      setD(() => busy = false);
                      g.toast('$e');
                    }
                  },
            child: const Text('Send report'),
          ),
        ],
      );
    }),
  );
}

/// Report a song card (its cover art, video or anything shown on it).
Future<void> showSongReport(BuildContext context, CardPayload card) {
  final g = GameScope.read(context);
  return _reportDialog(
    context,
    title: 'Report this song',
    reasons: kSongReportReasons,
    intro: [
      Text('${card.title} — ${card.artistName}', style: const TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      const Text('Report a song card only if its artwork or video contains:', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      _bullet('Explicit sexual content (such as nudity or sexual intercourse)'),
      _bullet('Graphic violence or gore'),
      _bullet('Malicious links or advertising (e.g. crypto scams)'),
      _bullet('Other content that clearly breaks the rules above'),
      const SizedBox(height: 8),
      const Text(
        'Provocative or suggestive imagery that isn\'t explicit — such as revealing outfits or dancing — is allowed in Tunetrail and isn\'t grounds for a report. '
        'For copyright concerns, use "Report a copyright issue" on the card instead.',
        style: TextStyle(fontSize: 12, color: kTextTertiary, height: 1.4),
      ),
    ],
    send: (reason, details) => g.report(ReportKind.song, '${card.songId}', '${card.title} — ${card.artistName}', reason, details, card: card),
  );
}

/// Report another player.
Future<void> showPlayerReport(BuildContext context, String playerId, String name) {
  final g = GameScope.read(context);
  return _reportDialog(
    context,
    title: 'Report $name',
    reasons: kPlayerReportReasons,
    intro: [
      const Text('Report a player for:', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      _bullet('Cheating (e.g. hacked coins, bits or songs, or faked locations)'),
      _bullet('Harassment in messages, such as slurs, threats or targeted abuse'),
      _bullet('Spamming messages or offers'),
      _bullet('Sending malicious links (scams, phishing, malware)'),
      _bullet('Making new accounts to contact someone who blocked them'),
      const SizedBox(height: 8),
      const Text('To stop someone contacting you straight away, block them as well — reports are reviewed by a person.',
          style: TextStyle(fontSize: 12, color: kTextTertiary, height: 1.4)),
    ],
    send: (reason, details) => g.report(ReportKind.player, playerId, name, reason, details),
  );
}
