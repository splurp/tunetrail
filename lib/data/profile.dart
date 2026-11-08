import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:tunetrail_core/tunetrail_core.dart';

import 'models.dart';

enum MarketMode { local, online }

/// Price + trade note used by "quick list" for one rarity.
class QuickListPreset {
  QuickListPreset({required this.price, this.note = '', this.trades = false});
  int price;
  String note;
  bool trades;

  static int defaultPrice(Rarity r) => switch (r) {
        Rarity.common => 15,
        Rarity.uncommon => 40,
        Rarity.rare => 120,
        Rarity.epic => 450,
        Rarity.legendary => 1600,
      };

  Map<String, dynamic> toJson() => {'price': price, 'note': note, 'trades': trades};
  factory QuickListPreset.fromJson(Map<String, dynamic> j) =>
      QuickListPreset(price: (j['price'] as num?)?.toInt() ?? 10, note: j['note'] as String? ?? '', trades: j['trades'] as bool? ?? false);
}

/// Everything about the player except the card collection.
class PlayerProfile extends ChangeNotifier {
  PlayerProfile(this.dir);
  final Directory dir;
  File get _file => File('${dir.path}/profile.json');
  Timer? _saveTimer;

  String playerId = '';
  String name = 'Trailblazer';
  int coins = 500;
  int bits = 0;
  int xp = 0;
  int figureColor = 0xFFE9E6FF;

  // Cosmetics & themes.
  Set<String> owned = {'theme_classic'};
  String activeTheme = 'theme_classic';
  String? hat;
  String? shirt;
  String? pet;
  String? backpack;

  // Playlists.
  List<Playlist> playlists = [];

  // Stats.
  int totalCaught = 0;
  int shinyCaught = 0;
  double metersWalked = 0;
  int packsOpened = 0;
  int cardsSold = 0;
  int cardsScrapped = 0;
  int tradesCompleted = 0;

  // Quests: questId → progress; claimed quest ids.
  Map<String, int> questProgress = {};
  Set<String> questsClaimed = {};
  String questDay = '';

  /// Spawn ids caught/fled recently → expiry (ms epoch).
  Map<String, int> spentSpawns = {};

  /// Sample-edition sync tuner overrides: songId → (sourceShift, songShift).
  Map<int, (double, double)> sampleOverrides = {};

  /// Favourite artists (shown on the profile/showcase; 10× spawn weight).
  List<FavoriteArtist> favoriteArtists = [];

  // Showcase.
  String showcaseTitle = '';
  List<int> showcaseCards = [];
  List<String> showcasePlaylists = [];

  // Location.
  double lastLat = 40.7580;
  double lastLng = -73.9855;

  // Settings.
  bool debugEnabled = false;
  bool freePurchases = false;
  bool joystickEnabled = false;
  bool unlimitedRange = false;
  double speedMultiplier = 1.0;
  MarketMode marketMode = MarketMode.local;
  String serverUrl = 'http://localhost:8080';
  String tileUrl = '';

  /// Last.fm API key (optional) for play-count based rarity. Defaults to the
  /// key baked in at build time with --dart-define=LASTFM_API_KEY=...
  String lastFmKey = '';
  static const builtInLastFmKey = String.fromEnvironment('LASTFM_API_KEY');
  String get effectiveLastFmKey => lastFmKey.isNotEmpty ? lastFmKey : builtInLastFmKey;
  double volume = 0.8;
  bool playOnEncounter = true;

  /// Catch-ring calibration: shifts the beat grid later (+) or earlier (−)
  /// to match this device's audio latency.
  int beatOffsetMs = 0;

  /// UI sound effects (catches, sales, trades…).
  bool soundEffects = true;

  /// Keep the preview playing after a song is caught (off by default).
  bool keepPlayingAfterCatch = false;

  /// Quick-list presets, one per rarity (Common → Legendary).
  List<QuickListPreset> quickListPresets = [
    for (final r in Rarity.values) QuickListPreset(price: QuickListPreset.defaultPrice(r)),
  ];

  QuickListPreset quickListPreset(Rarity r) => quickListPresets[r.index];
  bool reduceEffects = false;

  int get level => levelForXp(xp);
  static int levelForXp(int xp) => (math.sqrt(xp / 100)).floor() + 1;
  static int xpForLevel(int level) => (level - 1) * (level - 1) * 100;

  Future<void> load() async {
    if (await _file.exists()) {
      try {
        _fromJson(jsonDecode(await _file.readAsString()) as Map<String, dynamic>);
      } catch (e) {
        debugPrint('profile load failed: $e');
      }
    }
    if (playerId.isEmpty) {
      final r = math.Random.secure();
      playerId = List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
      name = 'Trailblazer${r.nextInt(9000) + 1000}';
      save();
    }
  }

  void changed() {
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), save);
  }

  Future<void> save() async {
    _saveTimer?.cancel();
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(_toJson()), flush: true);
    await tmp.rename(_file.path);
  }

  Map<String, dynamic> _toJson() => {
        'v': 1,
        'playerId': playerId,
        'name': name,
        'coins': coins,
        'bits': bits,
        'xp': xp,
        'beatOffset': beatOffsetMs,
        'sfx': soundEffects,
        'sampleOv2': {for (final e in sampleOverrides.entries) '${e.key}': [e.value.$1, e.value.$2]},
        'color': figureColor,
        'owned': owned.toList(),
        'theme': activeTheme,
        'hat': hat,
        'shirt': shirt,
        'pet': pet,
        'backpack': backpack,
        'playlists': [for (final p in playlists) p.toJson()],
        'totalCaught': totalCaught,
        'shinyCaught': shinyCaught,
        'meters': metersWalked,
        'packs': packsOpened,
        'sold': cardsSold,
        'scrapped': cardsScrapped,
        'keepPlaying': keepPlayingAfterCatch,
        'quickList': [for (final p in quickListPresets) p.toJson()],
        'trades': tradesCompleted,
        'questProgress': questProgress,
        'questsClaimed': questsClaimed.toList(),
        'questDay': questDay,
        'spent': spentSpawns,
        'favArtists': [for (final a in favoriteArtists) a.toJson()],
        'showcaseTitle': showcaseTitle,
        'showcaseCards': showcaseCards,
        'showcasePlaylists': showcasePlaylists,
        'lat': lastLat,
        'lng': lastLng,
        'debug': debugEnabled,
        'freePurchases': freePurchases,
        'joystick': joystickEnabled,
        'unlimitedRange': unlimitedRange,
        'speed': speedMultiplier,
        'marketMode': marketMode.index,
        'server': serverUrl,
        'tileUrl': tileUrl,
        'lastFmKey': lastFmKey,
        'volume': volume,
        'playOnEncounter': playOnEncounter,
        'reduceEffects': reduceEffects,
      };

  void _fromJson(Map<String, dynamic> j) {
    playerId = j['playerId'] as String? ?? '';
    name = j['name'] as String? ?? name;
    coins = (j['coins'] as num?)?.toInt() ?? coins;
    bits = (j['bits'] as num?)?.toInt() ?? bits;
    xp = (j['xp'] as num?)?.toInt() ?? 0;
    beatOffsetMs = (j['beatOffset'] as num?)?.toInt() ?? 0;
    soundEffects = j['sfx'] as bool? ?? true;
    sampleOverrides = {
      for (final e in (j['sampleOv2'] as Map<String, dynamic>? ?? const {}).entries)
        int.parse(e.key): (
          ((e.value as List)[0] as num).toDouble(),
          ((e.value as List)[1] as num).toDouble(),
        ),
    };
    figureColor = (j['color'] as num?)?.toInt() ?? figureColor;
    owned = {...owned, for (final x in (j['owned'] as List? ?? const [])) x as String};
    activeTheme = j['theme'] as String? ?? activeTheme;
    hat = j['hat'] as String?;
    shirt = j['shirt'] as String?;
    pet = j['pet'] as String?;
    backpack = j['backpack'] as String?;
    playlists = [
      for (final p in (j['playlists'] as List? ?? const []))
        Playlist.fromJson(p as Map<String, dynamic>)
    ];
    totalCaught = (j['totalCaught'] as num?)?.toInt() ?? 0;
    shinyCaught = (j['shinyCaught'] as num?)?.toInt() ?? 0;
    metersWalked = (j['meters'] as num?)?.toDouble() ?? 0;
    packsOpened = (j['packs'] as num?)?.toInt() ?? 0;
    cardsSold = (j['sold'] as num?)?.toInt() ?? 0;
    cardsScrapped = (j['scrapped'] as num?)?.toInt() ?? 0;
    keepPlayingAfterCatch = j['keepPlaying'] as bool? ?? false;
    final ql = j['quickList'] as List?;
    if (ql != null && ql.length == 5) {
      quickListPresets = [for (final x in ql) QuickListPreset.fromJson(x as Map<String, dynamic>)];
    }
    tradesCompleted = (j['trades'] as num?)?.toInt() ?? 0;
    questProgress = {
      for (final e in (j['questProgress'] as Map<String, dynamic>? ?? const {}).entries)
        e.key: (e.value as num).toInt()
    };
    questsClaimed = {for (final x in (j['questsClaimed'] as List? ?? const [])) x as String};
    questDay = j['questDay'] as String? ?? '';
    final now = DateTime.now().millisecondsSinceEpoch;
    spentSpawns = {
      for (final e in (j['spent'] as Map<String, dynamic>? ?? const {}).entries)
        if ((e.value as num).toInt() > now) e.key: (e.value as num).toInt()
    };
    favoriteArtists = [for (final a in (j['favArtists'] as List? ?? const [])) FavoriteArtist.fromJson(a as Map<String, dynamic>)];
    showcaseTitle = j['showcaseTitle'] as String? ?? '';
    showcaseCards = [for (final x in (j['showcaseCards'] as List? ?? const [])) (x as num).toInt()];
    showcasePlaylists = [for (final x in (j['showcasePlaylists'] as List? ?? const [])) x as String];
    lastLat = (j['lat'] as num?)?.toDouble() ?? lastLat;
    lastLng = (j['lng'] as num?)?.toDouble() ?? lastLng;
    debugEnabled = j['debug'] as bool? ?? false;
    freePurchases = j['freePurchases'] as bool? ?? false;
    joystickEnabled = j['joystick'] as bool? ?? false;
    unlimitedRange = j['unlimitedRange'] as bool? ?? false;
    speedMultiplier = (j['speed'] as num?)?.toDouble() ?? 1.0;
    marketMode = MarketMode.values[((j['marketMode'] as num?)?.toInt() ?? 0).clamp(0, 1)];
    serverUrl = j['server'] as String? ?? serverUrl;
    tileUrl = j['tileUrl'] as String? ?? '';
    lastFmKey = j['lastFmKey'] as String? ?? '';
    volume = (j['volume'] as num?)?.toDouble() ?? volume;
    playOnEncounter = j['playOnEncounter'] as bool? ?? true;
    reduceEffects = j['reduceEffects'] as bool? ?? false;
  }
}
