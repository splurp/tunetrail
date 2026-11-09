import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../build_flags.dart';
import 'package:flutter/services.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../game/google_auth.dart';

import '../../game/minigames.dart';
import '../app.dart';
import '../widgets/cards.dart';
import 'favorite_artists_screen.dart';
import 'minigames_screen.dart' show MinigameFilterEditor;

/// First run: sign in with Google, pick a unique username, then (optional)
/// minigame preferences and favourite artists.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Step { signIn, username, preferences, artists }

class _OnboardingScreenState extends State<OnboardingScreen> {
  _Step? _manual;

  _Step _step(BuildContext context) {
    final p = GameScope.of(context).profile;
    if (p.authToken.isEmpty) return _Step.signIn;
    if (!p.usernameSet) return _Step.username;
    return _manual ?? _Step.preferences;
  }

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final step = _step(context);
    final page = switch (step) {
      _Step.signIn => const _SignIn(),
      _Step.username => const _Username(),
      _Step.preferences => _Preferences(onNext: () => setState(() => _manual = _Step.artists)),
      _Step.artists => FavoriteArtistsScreen(
        intro: 'Last step: add artists you love. They show on your profile, and their songs spawn 10× more often for you. You can change this any time in Profile.',
        onDone: g.finishOnboarding,
      ),
    };
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: KeyedSubtree(key: ValueKey(step), child: page),
    );
  }
}

class _StepScaffold extends StatelessWidget {
  const _StepScaffold({required this.step, required this.title, required this.children, this.bottom});
  final int step;
  final String title;
  final List<Widget> children;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    // Half the window on PCs and tablets; the full width on phones. Text
    // grows with the window so the page doesn't look lost on big screens.
    final wide = size.width >= 900;
    final width = wide ? size.width * 0.5 : math.min(size.width, 560.0);
    final scale = wide ? (size.width / 1100).clamp(1.0, 1.45) : 1.0;
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: box.maxHeight),
                child: Center(
                  child: SizedBox(
                    width: width,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24 * scale, vertical: 32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              for (var i = 0; i < 4; i++)
                                Expanded(
                                  child: Container(
                                    height: 4,
                                    margin: const EdgeInsets.symmetric(horizontal: 3),
                                    decoration: BoxDecoration(color: i <= step ? kAccent : kSurface2, borderRadius: BorderRadius.circular(2)),
                                  ),
                                ),
                            ],
                          ),
                          SizedBox(height: 28 * scale),
                          Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
                          const SizedBox(height: 10),
                          ...children,
                          if (bottom != null) ...[SizedBox(height: 24 * scale), bottom!],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ sign in
class _SignIn extends StatefulWidget {
  const _SignIn();
  @override
  State<_SignIn> createState() => _SignInState();
}

class _SignInState extends State<_SignIn> {
  bool _busy = false;
  String? _error;

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await GameScope.read(context).signInWithGoogle();
    if (mounted) {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) => _StepScaffold(
    step: 0,
    title: 'Welcome to Tunetrail',
    children: [
      Builder(
        builder: (context) => Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Icon(Icons.graphic_eq_rounded, size: 64 * MediaQuery.textScalerOf(context).scale(1), color: kAccent),
          ),
        ),
      ),
      const Text(
        'Walk around to find songs, collect them, and trade with other players.\n\n'
        'Sign in with Google to create your account. It keeps your trades, messages and username safe across devices. '
        'Other players never see your Google name, e-mail or photo — only the username you choose next.',
        style: TextStyle(color: kTextSecondary, height: 1.45),
      ),
      const SizedBox(height: 28),
      Builder(
        builder: (context) => SizedBox(
          height: 48 * MediaQuery.textScalerOf(context).scale(1),
          child: FilledButton.icon(
            // Focused from the start: Enter or Space also signs in.
            autofocus: true,
            icon: Icon(Icons.login, size: 20 * MediaQuery.textScalerOf(context).scale(1)),
            label: const Text('Sign in with Google'),
            onPressed: _busy ? null : _go,
          ),
        ),
      ),
      const Padding(
        padding: EdgeInsets.only(top: 6),
        child: Text(
          'or press Enter',
          textAlign: TextAlign.center,
          style: TextStyle(color: kTextTertiary, fontSize: 12),
        ),
      ),
      if (_busy) const _WaitingForBrowser(),
      if (kAdminBuild && GameScope.of(context).profile.debugEnabled)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: TextButton(onPressed: GameScope.read(context).skipOnboardingForNow, child: const Text('Debug: skip sign-in for now')),
        ),
      if (_error != null) ...[
        const SizedBox(height: 14),
        Text(_error!, style: const TextStyle(color: Color(0xFFE5737A))),
        if (_error != 'Sign-in cancelled') ...[
          const SizedBox(height: 4),
          const Text('Check your internet connection and try again.', style: TextStyle(color: kTextTertiary, fontSize: 12)),
        ],
      ],
    ],
  );
}

/// While a PC waits for the browser: what to do, and ways out if the
/// browser didn't open or opened behind the game.
class _WaitingForBrowser extends StatelessWidget {
  const _WaitingForBrowser();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Uri?>(
    valueListenable: GoogleAuth.pendingUrl,
    builder: (context, url, _) => Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kOutline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 10),
              Expanded(
                child: Text('Waiting for Google…', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          if (url != null) ...[
            const SizedBox(height: 8),
            const Text(
              'A Google sign-in page opened in your web browser (it may be behind this window). Finish signing in there, then come back here.',
              style: TextStyle(color: kTextSecondary, height: 1.4),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.open_in_browser, size: 18),
                  label: const Text('Open the page again'),
                  onPressed: () async {
                    if (!await GoogleAuth.openPending() && context.mounted) {
                      GameScope.read(context).toast('Couldn\'t open a browser — copy the link instead');
                    }
                  },
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy link'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: url.toString()));
                    GameScope.read(context).toast('Link copied — paste it into your browser');
                  },
                ),
                TextButton(onPressed: GoogleAuth.cancel, child: const Text('Cancel')),
              ],
            ),
          ],
        ],
      ),
    ),
  );
}

// ----------------------------------------------------------------- username
class _Username extends StatefulWidget {
  const _Username();
  @override
  State<_Username> createState() => _UsernameState();
}

class _UsernameState extends State<_Username> {
  final _c = TextEditingController();
  Timer? _debounce;
  String? _error;
  bool _available = false;
  bool _checking = false;
  bool _busy = false;
  int _seq = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _c.dispose();
    super.dispose();
  }

  void _changed(String v) {
    final name = v.trim();
    final local = name.isEmpty ? null : usernameError(name);
    setState(() {
      _error = local;
      _available = false;
      _checking = local == null && name.isNotEmpty;
    });
    _debounce?.cancel();
    if (local != null || name.isEmpty) return;
    final seq = ++_seq;
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      final err = await GameScope.read(context).checkUsername(name);
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = err;
        _available = err == null;
        _checking = false;
      });
    });
  }

  Future<void> _save() async {
    final g = GameScope.read(context);
    final name = _c.text.trim();
    final err = usernameError(name);
    if (err != null) return setState(() => _error = err);
    setState(() => _busy = true);
    try {
      await g.chooseUsername(name);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => _StepScaffold(
    step: 1,
    title: 'Choose a username',
    bottom: FilledButton(
      onPressed: _busy || !_available ? null : _save,
      child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Continue'),
    ),
    children: [
      const Text(
        'This is how other players see you on the market, in trades and in messages. It\'s yours alone — no two players can have the same name.',
        style: TextStyle(color: kTextSecondary, height: 1.45),
      ),
      const SizedBox(height: 20),
      TextField(
        controller: _c,
        autofocus: true,
        maxLength: kUsernameMax,
        onChanged: _changed,
        onSubmitted: (_) => _available ? _save() : null,
        decoration: InputDecoration(
          hintText: 'e.g. VinylHunter or 🎧beatseeker',
          errorText: _error,
          helperText: _available ? '✓ Available' : null,
          helperStyle: const TextStyle(color: Color(0xFF69F0AE)),
          suffixIcon: _checking
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : null,
        ),
      ),
      const SizedBox(height: 8),
      const Text(
        '• $kUsernameMin–$kUsernameMax characters: letters (any language), numbers, symbols and emoji\n'
        '• No spaces, and not < > & " \' ` \\ /\n'
        '• Names that only differ by capitals, accents or look-alike letters count as the same name',
        style: TextStyle(color: kTextTertiary, fontSize: 12, height: 1.5),
      ),
    ],
  );
}

// -------------------------------------------------------------- preferences
class _Preferences extends StatefulWidget {
  const _Preferences({required this.onNext});
  final VoidCallback onNext;
  @override
  State<_Preferences> createState() => _PreferencesState();
}

class _PreferencesState extends State<_Preferences> {
  late MinigameFilter _f = MinigameFilter.fromJson(GameScope.read(context).profile.minigameFilter);

  void _save(bool skip) {
    final g = GameScope.read(context);
    if (!skip) {
      g.profile.minigameFilter = _f.toJson();
      g.profile.changed();
    }
    widget.onNext();
  }

  @override
  Widget build(BuildContext context) {
    final empty = _f.languages.isEmpty || _f.genres.isEmpty;
    return _StepScaffold(
      step: 2,
      title: 'What do you listen to?',
      bottom: Row(
        children: [
          TextButton(onPressed: () => _save(true), child: const Text('Skip')),
          const Spacer(),
          FilledButton(onPressed: empty ? null : () => _save(false), child: const Text('Continue')),
        ],
      ),
      children: [
        const Text(
          'Pick the languages and genres you know. We use them to choose the artists and songs in the Artist Guesser, Song Guesser and Trivia '
          'minigames you\'ll be able to play, so the questions are about music you actually listen to. Change it any time in the Games tab.',
          style: TextStyle(color: kTextSecondary, height: 1.45),
        ),
        const SizedBox(height: 20),
        MinigameFilterEditor(filter: _f, onChanged: (f) => setState(() => _f = f)),
        if (empty)
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text('Pick at least one language and one genre — or skip.', style: TextStyle(color: kTextTertiary, fontSize: 12)),
          ),
      ],
    );
  }
}

/// Changes the player's username (same rules as at sign-up).
Future<void> showChangeUsername(BuildContext context) async {
  final g = GameScope.read(context);
  final c = TextEditingController(text: g.profile.usernameSet ? g.profile.name : '');
  String? error;
  var busy = false;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) {
        Future<void> save() async {
          final name = c.text.trim();
          final local = usernameError(name);
          if (local != null) return setD(() => error = local);
          setD(() => busy = true);
          try {
            await g.chooseUsername(name);
            if (ctx.mounted) Navigator.pop(ctx);
            g.toast('You\'re now $name');
          } catch (e) {
            setD(() => (error, busy) = ('$e', false));
          }
        }

        return AlertDialog(
          title: const Text('Change username'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: c,
                  autofocus: true,
                  maxLength: kUsernameMax,
                  onChanged: (v) => setD(() => error = v.trim().isEmpty ? null : usernameError(v.trim())),
                  onSubmitted: (_) => save(),
                  decoration: InputDecoration(errorText: error, errorMaxLines: 3),
                ),
                Text(
                  g.usernameChangeCost == 0 ? 'This change is free.' : 'This change costs ${g.usernameChangeCost} bits (you have ${g.profile.bits}).',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Letters, numbers, symbols and emoji · no spaces · not < > & " \' ` \\ /\nYour old name becomes free for others.',
                  style: TextStyle(fontSize: 12, color: kTextTertiary),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: busy ? null : save, child: const Text('Save')),
          ],
        );
      },
    ),
  );
}
