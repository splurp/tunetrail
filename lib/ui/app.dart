import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../game/game.dart';
import 'map/map_screen.dart';
import 'screens/collection_screen.dart';
import 'screens/market_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/shop_screen.dart';
import 'widgets/cards.dart';
import 'widgets/mini_player.dart';

/// Makes the [Game] available to every widget and rebuilds dependents when
/// it notifies.
class GameScope extends InheritedNotifier<Game> {
  const GameScope({super.key, required Game game, required super.child}) : super(notifier: game);

  static Game of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<GameScope>()!.notifier!;
  static Game read(BuildContext context) => context.getInheritedWidgetOfExactType<GameScope>()!.notifier!;
}

ThemeData buildTheme() {
  const accent = Color(0xFF00E5FF);
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark, surface: const Color(0xFF12141F)),
    scaffoldBackgroundColor: const Color(0xFF0B0D16),
  );
  return base.copyWith(
    appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF0B0D16), elevation: 0, centerTitle: false),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: const Color(0xFF12141F),
      indicatorColor: accent.withValues(alpha: 0.2),
      labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
    ),
    cardTheme: const CardThemeData(color: Color(0xFF171A28), margin: EdgeInsets.zero),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, backgroundColor: Color(0xFF263238), contentTextStyle: TextStyle(color: Colors.white)),
  );
}

class TunetrailApp extends StatefulWidget {
  const TunetrailApp({super.key});
  @override
  State<TunetrailApp> createState() => _TunetrailAppState();
}

class _TunetrailAppState extends State<TunetrailApp> with WidgetsBindingObserver {
  Game? _game;
  Object? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Game.create().then((g) => setState(() => _game = g), onError: (Object e) => setState(() => _error = e));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _game?.saveAll();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _game?.saveAll();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = _game;
    return MaterialApp(
      title: 'Tunetrail',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      // GameScope wraps the Navigator so pushed routes can reach the game.
      builder: (context, child) => g == null ? child! : GameScope(game: g, child: child!),
      home: g == null ? _Splash(error: _error) : const HomeShell(),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash({this.error});
  final Object? error;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.graphic_eq, size: 72, color: Color(0xFF00E5FF)),
            const SizedBox(height: 12),
            const Text('TUNETRAIL', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: 6)),
            const SizedBox(height: 24),
            if (error == null) const CircularProgressIndicator() else Text('Failed to start: $error'),
          ]),
        ),
      );
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  static void goTo(BuildContext context, int tab) => context.findAncestorStateOfType<_HomeShellState>()?.setTab(tab);

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with SingleTickerProviderStateMixin {
  int _tab = 0;
  StreamSubscription<String>? _toasts;
  late final Ticker _glint;
  final _built = <int>{0};

  void setTab(int t) => setState(() {
        _tab = t;
        _built.add(t);
      });

  @override
  void initState() {
    super.initState();
    _glint = createTicker((d) => glintClock.value = (d.inMilliseconds / 2400) % 1.0)..start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _toasts ??= GameScope.read(context).toasts.listen((m) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 3)));
    });
  }

  @override
  void dispose() {
    _toasts?.cancel();
    _glint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const pages = [MapScreen(), CollectionScreen(), MarketScreen(), ShopScreen(), ProfileScreen()];
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          for (var i = 0; i < pages.length; i++) _built.contains(i) ? pages[i] : const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
        const MiniPlayer(),
        NavigationBar(
          selectedIndex: _tab,
          height: 64,
          onDestinationSelected: setTab,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Map'),
            NavigationDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music), label: 'Collection'),
            NavigationDestination(icon: Icon(Icons.storefront_outlined), selectedIcon: Icon(Icons.storefront), label: 'Market'),
            NavigationDestination(icon: Icon(Icons.shopping_bag_outlined), selectedIcon: Icon(Icons.shopping_bag), label: 'Shop'),
            NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
          ],
        ),
      ]),
    );
  }
}
