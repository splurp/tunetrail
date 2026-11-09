import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../data/models.dart';
import '../../game/game.dart';
import '../../game/purchase_service.dart';
import '../../game/store_catalog.dart';
import '../app.dart';
import '../map/map_themes.dart';
import '../widgets/figure_preview.dart';
import '../widgets/cards.dart';
import '../widgets/net_image.dart';
import '../widgets/stick_figure.dart';
import 'pack_opening_screen.dart';

class ShopScreen extends StatelessWidget {
  const ShopScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final free = g.profile.debugEnabled && g.profile.freePurchases;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Shop'),
          actions: [
            CurrencyChip(icon: kCoinIcon, value: g.profile.coins, color: kCoinColor),
            const SizedBox(width: 6),
            CurrencyChip(icon: kBitsIcon, value: g.profile.bits, color: kBitsColor),
            const SizedBox(width: 12),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Packs'),
              Tab(text: 'Bits'),
              Tab(text: 'Map themes'),
              Tab(text: 'Style'),
            ],
          ),
        ),
        body: ContentWidth(
          maxWidth: 1100,
          child: Column(
            children: [
              if (free)
                Container(
                  width: double.infinity,
                  color: kAccentDim,
                  padding: const EdgeInsets.all(6),
                  child: const Text('DEBUG: real-money purchases are free (no charge)', textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
                ),
              const Expanded(child: TabBarView(children: [_Packs(), _Bits(), _Themes(), _Style()])),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> buyProduct(BuildContext context, Product p) async {
  final g = GameScope.read(context);
  final r = await g.purchase(p);
  switch (r) {
    case PurchaseResult.granted:
      break;
    case PurchaseResult.pending:
      g.toast('Purchase pending…');
    case PurchaseResult.cancelled:
      g.toast('Purchase cancelled');
    case PurchaseResult.unavailable:
      g.toast('Store unavailable on this device. (Developer build: enable Debug → Free purchases.)');
    case PurchaseResult.error:
      g.toast('Purchase failed');
  }
}

// ---------------------------------------------------------------- packs
class _Packs extends StatelessWidget {
  const _Packs();

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const _PackArt(color: Color(0xFFFF6F91), cards: 1),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Artist Blind Box', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 4),
                      const Text(
                        'Pick any artist: get one of their songs as a shiny — every rarity equally likely — with a 1 in 100 chance of a Canvas edition. 5–100 bits depending on the artist\'s popularity.',
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                      const SizedBox(height: 6),
                      FilledButton.icon(
                        icon: const Icon(Icons.person_search, size: 18),
                        label: const Text('Choose an artist'),
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const BlindBoxScreen())),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        for (final p in kPacks)
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  _PackArt(color: p.color, cards: p.cards),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(p.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                        const SizedBox(height: 4),
                        Text(p.description, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                        TextButton(
                          style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                          onPressed: () => _showOdds(context, p),
                          child: const Text('View drop rates'),
                        ),
                        FilledButton.icon(icon: const Icon(kBitsIcon, size: 18), label: Text('${p.bits} bits'), onPressed: g.profile.bits < p.bits ? null : () => _open(context, p)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (g.profile.bits < kPacks.first.bits) TextButton(onPressed: () => DefaultTabController.of(context).animateTo(1), child: const Text('Get more bits →')),
      ],
    );
  }

  Future<void> _open(BuildContext context, PackDef p) async {
    final g = GameScope.read(context);
    int? genre;
    if (p.genreChoice) {
      genre = await showDialog<int>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('Choose a genre'),
          children: [
            for (final gd in kGenres)
              if (g.catalog.poolFor(gd.id).isNotEmpty) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, gd.id), child: Text('${gd.name}  (${g.catalog.poolFor(gd.id).length} songs)')),
          ],
        ),
      );
      if (genre == null) return;
    }
    try {
      final cards = g.openPack(p, genreId: genre);
      if (!context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PackOpeningScreen(pack: p, cards: cards),
        ),
      );
    } catch (e) {
      g.toast('$e');
    }
  }

  void _showOdds(BuildContext context, PackDef p) {
    final weights = [for (final r in Rarity.values) r.index >= p.allMin.index ? (r.spawnWeight * (r.index >= 2 ? p.luck : 1.0)) : 0.0];
    final total = weights.fold<double>(0, (a, b) => a + b);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${p.name} drop rates'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final r in Rarity.values)
              if (weights[r.index] > 0)
                Row(
                  children: [
                    RarityDot(r),
                    const SizedBox(width: 8),
                    Expanded(child: Text(r.label)),
                    Text('${(weights[r.index] / total * 100).toStringAsFixed(1)}%'),
                  ],
                ),
            const SizedBox(height: 8),
            Text('Shiny chance per card: ${p.guaranteedShiny ? 'one guaranteed, others ' : ''}1 in ${p.shinyOdds}'),
            if (p.guaranteedMin != null) Text('Guaranteed: at least one ${p.guaranteedMin!.label} or better'),
            const SizedBox(height: 8),
            const Text('Rates are per card before guarantees are applied.', style: TextStyle(fontSize: 12, color: Colors.white54)),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }
}

class _PackArt extends StatelessWidget {
  const _PackArt({required this.color, required this.cards});
  final Color color;
  final int cards;
  @override
  Widget build(BuildContext context) => Glint(
    strength: 0.45,
    child: Container(
      width: 84,
      height: 116,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [color, Color.lerp(color, Colors.black, 0.6)!]),
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 14)],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.graphic_eq, size: 38, color: Colors.white),
          Text('×$cards', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
        ],
      ),
    ),
  );
}

// ----------------------------------------------------------------- bits
class _Bits extends StatelessWidget {
  const _Bits();
  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Text('Bits are used to buy song packs.', style: TextStyle(color: Colors.white60)),
        const SizedBox(height: 8),
        for (final p in kBitsBundles)
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              leading: const Icon(kBitsIcon, color: kBitsColor, size: 36),
              title: Text('${formatNumber(p.bits)} bits', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
              subtitle: Text(p.description.isEmpty ? p.name : '${p.name} • ${p.description}'),
              trailing: FilledButton(onPressed: () => buyProduct(context, p), child: Text(g.purchases.priceFor(p))),
            ),
          ),
        if (g.purchases.storeAvailable) TextButton(onPressed: g.purchases.restore, child: const Text('Restore purchases')),
      ],
    );
  }
}

// --------------------------------------------------------------- themes
class _Themes extends StatelessWidget {
  const _Themes();
  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 220, childAspectRatio: 0.78, crossAxisSpacing: 10, mainAxisSpacing: 10),
      itemCount: kThemeProducts.length,
      itemBuilder: (context, i) {
        final p = kThemeProducts[i];
        final owned = g.profile.owned.contains(p.id);
        final active = g.profile.activeTheme == p.id;
        final t = themeById(p.id);
        return Card(
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: active ? p.color : Colors.transparent, width: 2),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _ThemePreview(theme: t)),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                    Text(
                      p.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Colors.white60),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      width: double.infinity,
                      child: active
                          ? const OutlinedButton(onPressed: null, child: Text('Equipped'))
                          : owned
                          ? FilledButton.tonal(onPressed: () => g.equip(ProductKind.theme, p.id), child: const Text('Equip'))
                          : FilledButton(onPressed: () => buyProduct(context, p), child: Text(g.purchases.priceFor(p))),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ThemePreview extends StatefulWidget {
  const _ThemePreview({required this.theme});
  final MapThemeDef theme;
  @override
  State<_ThemePreview> createState() => _ThemePreviewState();
}

class _ThemePreviewState extends State<_ThemePreview> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 60))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    return Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(painter: _MiniWorldPainter(t)),
        AnimatedBuilder(
          animation: _c,
          builder: (_, _) => CustomPaint(painter: MapEffectPainter(t, _c.value * 60)),
        ),
      ],
    );
  }
}

/// A tiny 3D-ish scene rendered with a theme's palette.
class _MiniWorldPainter extends CustomPainter {
  _MiniWorldPainter(this.theme);
  final MapThemeDef theme;

  @override
  void paint(Canvas canvas, Size size) {
    final p = theme.palette;
    final w = size.width, h = size.height;
    final horizon = h * 0.22;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, horizon),
      Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [p.skyTop, p.skyBottom]).createShader(Rect.fromLTWH(0, 0, w, horizon)),
    );
    canvas.drawRect(Rect.fromLTWH(0, horizon, w, h - horizon), Paint()..color = p.ground);
    final vp = Offset(w * 0.5, horizon);
    Path quad(double x0, double x1, double y0, double y1) {
      // Ground quad in "perspective": x converges towards the vanishing point.
      Offset g(double x, double y) => Offset(vp.dx + (x - vp.dx) * (y - horizon) / (h - horizon), y);
      return Path()
        ..moveTo(g(x0, y0).dx, y0)
        ..lineTo(g(x1, y0).dx, y0)
        ..lineTo(g(x1 * 1.0, y1).dx, y1)
        ..lineTo(g(x0, y1).dx, y1)
        ..close();
    }

    canvas.drawPath(quad(-w * 0.6, w * 0.25, horizon + 4, h * 0.55), Paint()..color = p.park);
    canvas.drawPath(quad(w * 0.7, w * 1.6, horizon + 2, h * 0.7), Paint()..color = p.water);
    canvas.drawPath(quad(w * 0.2, w * 0.62, h * 0.72, h), Paint()..color = p.parking);
    // Roads converging to the horizon + one crossing road.
    for (final (x, width, color) in [(w * 0.5, w * 0.14, p.roadMajor), (-w * 0.4, w * 0.08, p.roadMinor), (w * 1.5, w * 0.1, p.roadHighway)]) {
      canvas.drawPath(
        Path()
          ..moveTo(vp.dx - 1, horizon)
          ..lineTo(vp.dx + 1, horizon)
          ..lineTo(x + width, h)
          ..lineTo(x - width, h)
          ..close(),
        Paint()..color = color,
      );
    }
    final cy = h * 0.62;
    canvas.drawRect(Rect.fromLTRB(0, cy, w, cy + h * 0.06), Paint()..color = p.roadMinor);
    // A mega-building block.
    final b = Rect.fromLTWH(w * 0.08, h * 0.3, w * 0.22, h * 0.12);
    canvas.drawRect(b.translate(0, -h * 0.06), Paint()..color = p.buildingRoof);
    canvas.drawRect(Rect.fromLTRB(b.left, b.bottom - h * 0.06, b.right, b.bottom), Paint()..color = p.buildingWall);
    // Player marker.
    canvas.drawCircle(Offset(w * 0.5, h * 0.8), 10, Paint()..color = p.accent.withValues(alpha: 0.25));
    canvas.drawCircle(Offset(w * 0.5, h * 0.8), 4, Paint()..color = p.accent);
  }

  @override
  bool shouldRepaint(_MiniWorldPainter old) => old.theme.id != theme.id;
}

// ---------------------------------------------------------------- style
class _Style extends StatelessWidget {
  const _Style();

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final p = g.profile;
    Widget section(String title, ProductKind kind, List<Product> items, String? equipped) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
          child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        ),
        SizedBox(
          height: 210,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final it = items[i];
              final owned = p.owned.contains(it.id);
              final on = equipped == it.id;
              final look = FigureLook(
                color: Color(p.figureColor),
                hat: kind == ProductKind.hat ? it.id : p.hat,
                shirt: kind == ProductKind.shirt ? it.id : p.shirt,
                pet: kind == ProductKind.pet ? it.id : null,
                backpack: kind == ProductKind.backpack ? it.id : p.backpack,
              );
              return Container(
                width: 140,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: kSurface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: on ? it.color : Colors.white12, width: on ? 2 : 1),
                ),
                child: Column(
                  children: [
                    Expanded(
                      child: Center(child: Figure3DPreview(look: look, size: 130, animate: on, facing: kind == ProductKind.backpack ? 30 : 200)),
                    ),
                    Text(
                      it.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(6),
                      child: SizedBox(
                        width: double.infinity,
                        child: owned
                            ? FilledButton.tonal(onPressed: () => g.equip(kind, on ? null : it.id), child: Text(on ? 'Unequip' : 'Equip'))
                            : FilledButton(onPressed: () => buyProduct(context, it), child: Text(g.purchases.priceFor(it))),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
    return ListView(
      children: [
        section('Hats', ProductKind.hat, kHatProducts, p.hat),
        section('Shirts', ProductKind.shirt, kShirtProducts, p.shirt),
        section('Backpacks', ProductKind.backpack, kBackpackProducts, p.backpack),
        section('Pets', ProductKind.pet, kPetProducts, p.pet),
        const SizedBox(height: 20),
      ],
    );
  }
}

/// Artist Blind Box: search for an artist, see their price, open the box.
class BlindBoxScreen extends StatefulWidget {
  const BlindBoxScreen({super.key});
  @override
  State<BlindBoxScreen> createState() => _BlindBoxScreenState();
}

class _BlindBoxScreenState extends State<BlindBoxScreen> {
  final _q = TextEditingController();
  List<ArtistInfo> _results = [];
  bool _loading = false, _opening = false;

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.isEmpty) return;
    final g = GameScope.read(context);
    setState(() => _loading = true);
    try {
      final r = await g.api.searchArtists(q, limit: 20);
      if (mounted) setState(() => _results = r);
    } catch (e) {
      g.toast('Search failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(ArtistInfo a) async {
    final g = GameScope.read(context);
    setState(() => _opening = true);
    try {
      final pull = await g.openArtistBlindBox(a);
      if (!mounted) return;
      final pack = PackDef(id: 'blind_${a.id}', name: '${a.name} Blind Box', bits: Game.blindBoxPrice(a.fans), cards: 1, description: '', color: const Color(0xFFFF6F91));
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PackOpeningScreen(pack: pack, cards: [pull]),
        ),
      );
    } catch (e) {
      g.toast('$e');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Artist Blind Box'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text('${formatNumber(g.profile.bits)} bits', style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
      body: ContentWidth(
        maxWidth: 800,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _q,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: 'Search for an artist',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _search),
              ),
            ),
            const SizedBox(height: 8),
            for (final a in _results)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Art(a.picture(), size: 44, circle: true),
                title: Text(a.name),
                subtitle: Text('${formatNumber(a.fans)} fans', style: const TextStyle(fontSize: 12, color: kTextTertiary)),
                trailing: FilledButton.icon(
                  icon: const Icon(kBitsIcon, size: 16),
                  label: Text('${Game.blindBoxPrice(a.fans)}'),
                  onPressed: _opening || g.profile.bits < Game.blindBoxPrice(a.fans) ? null : () => _open(a),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
