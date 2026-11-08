import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'models.dart';

enum MarketMode { local, online }

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
  int figureColor = 0xFF00E5FF;

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
  int tradesCompleted = 0;

  // Quests: questId → progress; claimed quest ids.
  Map<String, int> questProgress = {};
  Set<String> questsClaimed = {};
  String questDay = '';

  /// Spawn ids caught/fled recently → expiry (ms epoch).
  Map<String, int> spentSpawns = {};

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
  double volume = 0.8;
  bool playOnEncounter = true;
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
        'trades': tradesCompleted,
        'questProgress': questProgress,
        'questsClaimed': questsClaimed.toList(),
        'questDay': questDay,
        'spent': spentSpawns,
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
    volume = (j['volume'] as num?)?.toDouble() ?? volume;
    playOnEncounter = j['playOnEncounter'] as bool? ?? true;
    reduceEffects = j['reduceEffects'] as bool? ?? false;
  }
}
