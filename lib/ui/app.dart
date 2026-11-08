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
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: kAccent,
    onPrimary: Colors.black,
    primaryContainer: kAccentDim,
    onPrimaryContainer: kTextPrimary,
    secondary: Color(0xFFE6E6EB),
    onSecondary: Colors.black,
    secondaryContainer: kSurface2,
    onSecondaryContainer: kTextPrimary,
    tertiary: kAccent,
    onTertiary: Colors.black,
    error: Color(0xFFE5737A),
    onError: Colors.black,
    surface: kSurface,
    onSurface: kTextPrimary,
    onSurfaceVariant: kTextSecondary,
    surfaceContainerLowest: kBg,
    surfaceContainerLow: kSurface,
    surfaceContainer: kSurface,
    surfaceContainerHigh: kSurface2,
    surfaceContainerHighest: Color(0xFF222227),
    outline: kOutline,
    outlineVariant: kOutline,
  );
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true, colorScheme: scheme, scaffoldBackgroundColor: kBg);
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: kTextPrimary, displayColor: kTextPrimary),
    appBarTheme: const AppBarTheme(
      backgroundColor: kBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: kTextPrimary, letterSpacing: -0.3),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: kBg,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      height: 62,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(size: 22, color: s.contains(WidgetState.selected) ? kAccent : kTextTertiary)),
      labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: s.contains(WidgetState.selected) ? kTextPrimary : kTextTertiary)),
    ),
    cardTheme: CardThemeData(
      color: kSurface,
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: kOutline)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFFECECF1),
        foregroundColor: Colors.black,
        disabledBackgroundColor: kSurface2,
        disabledForegroundColor: kTextTertiary,
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(foregroundColor: kTextPrimary, side: const BorderSide(color: kOutline), shape: shape, padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12)),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: kAccent)),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: kSurface2,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      hintStyle: const TextStyle(color: kTextTertiary),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kOutline)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kOutline)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: kAccent.withValues(alpha: 0.7))),
    ),
    tabBarTheme: TabBarThemeData(
      indicatorColor: kAccent,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: kOutline,
      labelColor: kTextPrimary,
      unselectedLabelColor: kTextTertiary,
      labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
    ),
    chipTheme: base.chipTheme.copyWith(backgroundColor: kSurface2, side: const BorderSide(color: kOutline), shape: StadiumBorder(side: const BorderSide(color: kOutline))),
    dividerTheme: const DividerThemeData(color: kOutline, thickness: 1, space: 1),
    listTileTheme: const ListTileThemeData(iconColor: kTextSecondary),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: kSurface, surfaceTintColor: Colors.transparent, showDragHandle: false,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)))),
    dialogTheme: DialogThemeData(backgroundColor: kSurface, surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
    popupMenuTheme: PopupMenuThemeData(color: kSurface2, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    dropdownMenuTheme: const DropdownMenuThemeData(textStyle: TextStyle(fontSize: 13)),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : kTextTertiary),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? kAccent : kSurface2),
      trackOutlineColor: WidgetStateProperty.all(kOutline),
    ),
    sliderTheme: base.sliderTheme.copyWith(activeTrackColor: kAccent, inactiveTrackColor: kSurface2, thumbColor: Colors.white),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: kAccent, linearTrackColor: kSurface2),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF1E1E23),
      contentTextStyle: const TextStyle(color: kTextPrimary),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(backgroundColor: Color(0xFFECECF1), foregroundColor: Colors.black),
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
            const Icon(Icons.graphic_eq_rounded, size: 44, color: kAccent),
            const SizedBox(height: 14),
            const Text('tunetrail', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w300, letterSpacing: 4)),
            const SizedBox(height: 28),
            if (error == null) const SizedBox(width: 120, child: LinearProgressIndicator(minHeight: 2)) else Text('Failed to start: $error'),
          ]),
        ),
      );
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  static void goTo(BuildContext context, int tab) => context.findAncestorStateOfType<_HomeShellState>()?.setTab(tab);

  /// The currently visible tab (0 = map).
  static final ValueNotifier<int> currentTab = ValueNotifier(0);

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
        HomeShell.currentTab.value = t;
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
        const Divider(height: 1),
        NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: setTab,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.explore_outlined), selectedIcon: Icon(Icons.explore), label: 'Explore'),
            NavigationDestination(icon: Icon(Icons.grid_view_outlined), selectedIcon: Icon(Icons.grid_view_rounded), label: 'Collection'),
            NavigationDestination(icon: Icon(Icons.storefront_outlined), selectedIcon: Icon(Icons.storefront), label: 'Market'),
            NavigationDestination(icon: Icon(Icons.local_mall_outlined), selectedIcon: Icon(Icons.local_mall), label: 'Shop'),
            NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
          ],
        ),
      ]),
    );
  }
}
