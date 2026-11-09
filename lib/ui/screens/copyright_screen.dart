import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/ui_kit.dart';

/// Where copyright notices and opt-out requests go.
const kCopyrightEmail = 'fluorescent@gmail.com';

/// Copyright, DMCA and opt-out notice (Settings → Copyright & DMCA).
class CopyrightScreen extends StatelessWidget {
  const CopyrightScreen({super.key, this.subject});

  /// Prefills the e-mail subject (e.g. a specific song).
  final String? subject;

  static Future<void> email({String? subject}) async {
    final uri = Uri(scheme: 'mailto', path: kCopyrightEmail, query: 'subject=${Uri.encodeComponent(subject ?? 'Tunetrail copyright notice')}');
    try {
      await launchUrl(uri);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    const h = TextStyle(fontWeight: FontWeight.w800, fontSize: 16);
    const p = TextStyle(color: kTextSecondary, height: 1.45);
    Widget bullet(String t) => Padding(
          padding: const EdgeInsets.only(left: 6, bottom: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('•  ', style: p),
            Expanded(child: Text(t, style: p)),
          ]),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Copyright & DMCA')),
      body: ContentWidth(
        maxWidth: 760,
        child: ListView(padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.viewPaddingOf(context).bottom), children: [
          const Text('How music appears in Tunetrail', style: h),
          const SizedBox(height: 6),
          const Text(
            'Tunetrail does not host or sell music. Song cards show public information about songs and link to them on '
            'Apple Music and Spotify. Short previews, cover art and video clips are streamed from the services that provide '
            'them and are never stored on your device. Coins and bits buy game features and cosmetics, not songs.',
            style: p,
          ),
          const SizedBox(height: 20),
          const Text('Rights holders: notices and opt-outs', style: h),
          const SizedBox(height: 6),
          const Text(
            'If you own or represent the rights to a recording, composition, artwork or video and want it changed or removed '
            'from Tunetrail, or want an artist or catalogue opted out entirely, e-mail us. We respond to valid notices promptly '
            'and can remove content across the game remotely.',
            style: p,
          ),
          const SizedBox(height: 10),
          const Text('Please include:', style: p),
          const SizedBox(height: 4),
          bullet('The work (song, album, artwork or video) and, if you can, the artist and title as shown in the game.'),
          bullet('What you would like us to do (remove the preview, artwork or video, or opt the artist or catalogue out).'),
          bullet('Your name, organisation, address, phone number and e-mail address.'),
          bullet('A statement that you believe in good faith that the use is not authorised by the rights owner, its agent or the law.'),
          bullet('A statement that the information in your notice is accurate and, under penalty of perjury, that you are the '
              'rights owner or authorised to act on their behalf.'),
          bullet('Your physical or electronic signature.'),
          const SizedBox(height: 14),
          Center(
            child: FilledButton.icon(
              icon: const Icon(Icons.mail_outline),
              label: const Text(kCopyrightEmail),
              onPressed: () => email(subject: subject),
            ),
          ),
          const SizedBox(height: 6),
          const Center(child: SelectableText(kCopyrightEmail, style: TextStyle(color: kTextTertiary, fontSize: 12))),
          const SizedBox(height: 20),
          const Text('Counter-notices', style: h),
          const SizedBox(height: 6),
          const Text(
            'If you believe content was removed by mistake, send a counter-notice to the same address with your contact '
            'details, what was removed, and a statement under penalty of perjury that you believe it was removed in error.',
            style: p,
          ),
          const SizedBox(height: 20),
          const Text('Credits', style: h),
          const SizedBox(height: 6),
          const Text(
            'Song information, previews and artwork: Deezer and Apple. Apple Music is a trademark of Apple Inc.; Spotify is a '
            'trademark of Spotify AB. Map data © OpenStreetMap contributors (openstreetmap.org/copyright); map tiles by '
            'OpenFreeMap and VersaTiles. Artist names, song titles and artwork belong to their respective owners.',
            style: p,
          ),
        ]),
      ),
    );
  }
}
