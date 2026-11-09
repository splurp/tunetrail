import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../game/profile_themes.dart';
import '../app.dart';
import '../widgets/cards.dart';
import '../widgets/profile_banner.dart';
import 'player_screen.dart';
import 'report_dialogs.dart';

String _ago(int ms) {
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inMinutes < 1) return 'now';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inDays < 1) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${t.day}/${t.month}/${t.year % 100}';
}

/// Small round swatch of a player's profile theme (stands in for an avatar:
/// players can't upload pictures).
class ThemeAvatar extends StatelessWidget {
  const ThemeAvatar({super.key, required this.themeId, required this.name, this.size = 40});
  final String themeId;
  final String name;
  final double size;
  @override
  Widget build(BuildContext context) {
    final t = profileThemeById(themeId);
    final light = t.light;
    final first = name.characters.isEmpty ? '?' : name.characters.first.toUpperCase();
    return SizedBox(
      width: size,
      height: size,
      child: ProfileThemeBackground(
        theme: t,
        radius: size / 2,
        child: Center(child: Text(first, style: TextStyle(fontWeight: FontWeight.w800, fontSize: size * 0.42, color: light ? Colors.black : Colors.white))),
      ),
    );
  }
}

/// Every conversation, most recent first.
class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({super.key});
  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  Future<List<Conversation>>? _f;
  void _load() => setState(() => _f = GameScope.read(context).market.conversations());

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    _f ??= g.market.conversations();
    return Scaffold(
      appBar: AppBar(title: const Text('Messages')),
      body: ContentWidth(
        maxWidth: 760,
        child: RefreshIndicator(
          onRefresh: () async => _load(),
          child: FutureBuilder<List<Conversation>>(
            future: _f,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
              if (snap.hasError) return ListView(children: [Padding(padding: const EdgeInsets.all(24), child: Text('${snap.error}'))]);
              final list = snap.data ?? const [];
              if (list.isEmpty) {
                return ListView(children: const [
                  Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('No messages yet. Find a player in Market → Players and press Message on their profile.',
                        textAlign: TextAlign.center, style: TextStyle(color: kTextTertiary)),
                  ),
                ]);
              }
              return ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                itemBuilder: (context, i) {
                  final c = list[i];
                  final mine = c.last.from == g.profile.playerId;
                  return ListTile(
                    leading: ThemeAvatar(themeId: c.otherTheme, name: c.otherName),
                    title: Text(c.otherName, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: c.unread > 0 ? FontWeight.w800 : FontWeight.w600)),
                    subtitle: Text('${mine ? 'You: ' : ''}${c.last.text}', maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.unread > 0 ? kTextPrimary : kTextSecondary)),
                    trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(_ago(c.last.at), style: const TextStyle(fontSize: 11, color: kTextTertiary)),
                      if (c.unread > 0)
                        Container(
                          margin: const EdgeInsets.only(top: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                          decoration: BoxDecoration(color: kAccent, borderRadius: BorderRadius.circular(10)),
                          child: Text('${c.unread}', style: const TextStyle(fontSize: 11, color: Colors.black, fontWeight: FontWeight.w700)),
                        ),
                    ]),
                    onTap: () async {
                      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatScreen(otherId: c.otherId, otherName: c.otherName, otherTheme: c.otherTheme)));
                      _load();
                      unawaited(g.syncInbox());
                    },
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A conversation with one player. Messages are plain text only: no links,
/// images or formatting are ever rendered.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.otherId, required this.otherName, this.otherTheme = ''});
  final String otherId;
  final String otherName;
  final String otherTheme;
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();
  List<ChatMessage> _msgs = [];
  bool _loading = true;
  bool _sending = false;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    _poll = Timer.periodic(const Duration(seconds: 8), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _text.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final m = await GameScope.read(context).market.thread(widget.otherId);
      if (mounted) {
        setState(() {
          _msgs = m;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _send() async {
    final g = GameScope.read(context);
    final t = _text.text.trim();
    if (t.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final m = await g.market.sendMessage(widget.otherId, t);
      _text.clear();
      if (mounted) setState(() => _msgs = [..._msgs, m]);
    } catch (e) {
      g.toast('$e');
    }
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final me = g.profile.playerId;
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(tooltip: 'Report', icon: const Icon(Icons.flag_outlined), onPressed: () => showPlayerReport(context, widget.otherId, widget.otherName)),
        ],
        titleSpacing: 0,
        title: InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlayerScreen(playerId: widget.otherId))),
          child: Row(children: [
            ThemeAvatar(themeId: widget.otherTheme, name: widget.otherName, size: 32),
            const SizedBox(width: 10),
            Flexible(child: Text(widget.otherName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18))),
          ]),
        ),
      ),
      body: ContentWidth(
        maxWidth: 760,
        child: Column(children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null && _msgs.isEmpty
                    ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)))
                    : _msgs.isEmpty
                        ? const Center(child: Text('Say hi 👋', style: TextStyle(color: kTextTertiary)))
                        : ListView.builder(
                            reverse: true,
                            padding: const EdgeInsets.all(12),
                            itemCount: _msgs.length,
                            itemBuilder: (context, i) {
                              final m = _msgs[_msgs.length - 1 - i];
                              final mine = m.from == me;
                              return Align(
                                alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                                child: Container(
                                  constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.75),
                                  margin: const EdgeInsets.symmetric(vertical: 3),
                                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                                  decoration: BoxDecoration(
                                    color: mine ? kAccent.withValues(alpha: 0.85) : kSurface2,
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                                    SelectableText(m.text, style: TextStyle(color: mine ? Colors.black : kTextPrimary)),
                                    Text(_ago(m.at), style: TextStyle(fontSize: 10, color: (mine ? Colors.black : kTextTertiary).withValues(alpha: 0.6))),
                                  ]),
                                ),
                              );
                            },
                          ),
          ),
          const Divider(height: 1),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _text,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: kMaxMessageLength,
                    maxLengthEnforcement: MaxLengthEnforcement.enforced,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(hintText: 'Message', counterText: ''),
                  ),
                ),
                IconButton(
                  icon: _sending ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send_rounded, color: kAccent),
                  onPressed: _send,
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
