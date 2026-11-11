part of 'game.dart';

/// The game's side of the server economy: once a player's progress is on
/// the server, balances, items and cards are what the server says, and
/// every action that earns or spends is a request to it.
class EconomyClient {
  EconomyClient(this.g, this.market);
  final Game g;
  final RemoteMarket market;

  PlayerProfile get _p => g.profile;

  /// A request; the `acct` in the answer updates balances and cards.
  Future<Map<String, dynamic>> call(String method, String path, {Object? body, Map<String, String>? q, CardSource source = CardSource.market}) async {
    final j = await market.send(method, path, body: body, q: q, headers: {'x-econ-rev': '${_p.econRev}'});
    final map = j is Map<String, dynamic> ? j : <String, dynamic>{};
    final acct = map['acct'];
    if (acct is Map<String, dynamic>) await apply(acct, source: source);
    return map;
  }

  /// Fetches the account (after market trades and inbox items).
  Future<void> sync() async {
    try {
      await call('GET', '/me/account');
    } catch (_) {}
  }

  Future<void>? _full;

  /// Applies the server's account: balances, items, counters and card
  /// changes (or a full reload of the cards).
  Future<void> apply(Map<String, dynamic> a, {CardSource source = CardSource.market}) async {
    final rev = (a['rev'] as num?)?.toInt() ?? 0;
    // An answer older than one already applied (requests can overlap).
    if (rev < _p.econRev && a['full'] != true) return;
    _p
      ..coins = (a['coins'] as num?)?.toInt() ?? _p.coins
      ..bits = (a['bits'] as num?)?.toInt() ?? _p.bits
      ..xp = (a['xp'] as num?)?.toInt() ?? _p.xp
      ..usernameChanges = (a['unc'] as num?)?.toInt() ?? _p.usernameChanges;
    if (a['bonuses'] is Map<String, dynamic>) _p.bonuses = Bonuses.fromJson(a['bonuses'] as Map<String, dynamic>);
    if (a.containsKey('treasure')) _p.treasure = a['treasure'] as Map<String, dynamic>?;
    if (a['onMap'] is bool) _p.showOnMap = a['onMap'] as bool;
    if (a['perfect'] is bool) _p.perfectRing = a['perfect'] as bool;
    // An admin moved this player: go there (once).
    final tp = a['teleport'];
    if (tp is Map<String, dynamic>) {
      final at = (tp['at'] as num?)?.toInt() ?? 0;
      if (at > _p.teleportDoneAt) {
        _p.teleportDoneAt = at;
        g.location.pinTo(LatLng((tp['lat'] as num).toDouble(), (tp['lng'] as num).toDouble()));
        g.toast('An admin moved you to where they are');
      }
    }
    final owned = a['owned'];
    if (owned is List) {
      _p.owned
        ..clear()
        ..addAll([for (final o in owned) '$o'])
        ..addAll([for (final i in kShopItems) if (i.free) i.id]);
    }
    final st = a['stats'];
    if (st is Map<String, dynamic>) {
      int v(String k, int fallback) => (st[k] as num?)?.toInt() ?? fallback;
      _p
        ..totalCaught = v('caught', _p.totalCaught)
        ..shinyCaught = v('shinies', _p.shinyCaught)
        ..packsOpened = v('packs', _p.packsOpened)
        ..cardsScrapped = v('scrapped', _p.cardsScrapped);
      _p.minigameBits = v('minigameBits', _p.minigameBits);
      final m = (st['meters'] as num?)?.toDouble();
      if (m != null && m > _p.metersWalked) _p.metersWalked = m;
    }
    if (a['full'] == true) {
      await (_full ??= _reload().whenComplete(() => _full = null));
    } else {
      var changed = false;
      for (final u in (a['del'] as List? ?? const [])) {
        final uid = (u as num).toInt();
        if (g.collection.contains(uid)) {
          g._removeFromPlaylists(uid);
          g.collection.remove(uid);
          changed = true;
        }
      }
      for (final c in (a['add'] as List? ?? const [])) {
        final p = CardPayload.fromJson(c as Map<String, dynamic>);
        if (g.collection.contains(p.uid)) continue;
        _addCard(p, source);
        changed = true;
      }
      if (changed) g.collection.commit();
      if (rev > _p.econRev) _p.econRev = rev;
    }
    _p.changed();
    g._econChanged();
  }

  void _addCard(CardPayload p, CardSource source) {
    g.catalog.ensureFromPayload(p);
    g.catalog.adoptGenre(p.songId, p.genreId);
    g.collection.add(
      p.songId,
      p.rarity,
      p.shiny,
      source,
      uid: p.uid,
      at: p.acquiredAt > 0 ? DateTime.fromMillisecondsSinceEpoch(p.acquiredAt) : null,
      notify: false,
      edition: p.edition,
      serial: p.serial,
    );
  }

  /// Replaces the collection with the server's (keeping favourites, card
  /// sources and playlists of cards that are still there).
  Future<void> _reload() async {
    final j = await market.send('GET', '/me/cards', timeout: const Duration(seconds: 60)) as Map<String, dynamic>;
    final col = g.collection;
    final favs = <int>{}, sources = <int, CardSource>{};
    for (var i = 0; i < col.length; i++) {
      final c = col.at(i);
      if (c.favorite) favs.add(c.uid);
      sources[c.uid] = c.source;
    }
    col.clear();
    for (final c in (j['cards'] as List)) {
      final p = CardPayload.fromJson(c as Map<String, dynamic>);
      _addCard(p, sources[p.uid] ?? CardSource.market);
    }
    for (final u in favs) {
      if (col.contains(u)) col.setFavorite(u, true);
    }
    for (final pl in _p.playlists) {
      pl.cardUids.removeWhere((u) => !col.contains(u));
    }
    _p.showcaseCards.removeWhere((u) => !col.contains(u));
    _p.editionShowcase.removeWhere((u) => !col.contains(u));
    _p.econRev = (j['rev'] as num).toInt();
    col.commit();
  }

  /// Whether this device has progress of its own (beyond a new player's).
  bool get hasLocalProgress => g.collection.length > 0 || _p.bits > 0 || _p.coins > 500;

  /// Adds this device's progress to an account already on the server
  /// (progress from a device that never moved its own over).
  Future<void> mergeProgress() async {
    final body = _progress()..['coins'] = (_p.coins - 500).clamp(0, 1 << 40);
    await market.send('POST', '/me/merge', body: body, timeout: const Duration(seconds: 90));
    _p.econImported = true;
    _p.econRev = -1;
    await sync();
  }

  Map<String, dynamic> _progress() {
    final col = g.collection;
    return {
      'coins': _p.coins,
      'bits': _p.bits,
      'xp': _p.xp,
      'owned': _p.owned.toList(),
      'unc': _p.usernameChanges,
      'claimed': _p.questsClaimed.toList(),
      'stats': {
        'caught': _p.totalCaught,
        'shinies': _p.shinyCaught,
        'packs': _p.packsOpened,
        'scrapped': _p.cardsScrapped,
        'sold': _p.cardsSold,
        'trades': _p.tradesCompleted,
        'meters': _p.metersWalked.round(),
        'minigameBits': _p.minigameBits,
      },
      'cards': [for (var i = 0; i < col.length; i++) col.at(i).toPayload().toJson()],
    };
  }

  /// Copies this device's progress to the server (once per account).
  Future<void> importProgress() async {
    final j = await market.send('POST', '/me/import', body: _progress(), timeout: const Duration(seconds: 90)) as Map<String, dynamic>;
    _p.econImported = true;
    _p.econRev = -1;
    await apply(j['acct'] as Map<String, dynamic>);
  }
}

/// The result of one throw in the catch minigame.
class ThrowOutcome {
  const ThrowOutcome(this.result, {this.card, this.duplicateCoins = 0, this.note, this.xp = 0});

  /// XP gained by the catch.
  final int xp;

  /// caught, slipped or fled.
  final String result;
  final OwnedCard? card;
  final int duplicateCoins;
  final String? note;
  bool get caught => result == 'caught';
  bool get fled => result == 'fled';
}
