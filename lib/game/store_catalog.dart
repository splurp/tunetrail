import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

enum ProductKind { bits, theme, hat, shirt, pet, backpack }

/// A real-money store item (bits bundles, map themes, cosmetics).
class Product {
  const Product({
    required this.id,
    required this.name,
    required this.kind,
    required this.usd,
    this.bits = 0,
    this.description = '',
    this.color = const Color(0xFF00E5FF),
    this.icon = Icons.star,
  });

  /// Store SKU. The same id is used for Google Play / App Store products.
  final String id;
  final String name;
  final ProductKind kind;
  final double usd;
  final int bits;
  final String description;
  final Color color;
  final IconData icon;

  bool get consumable => kind == ProductKind.bits;
  String get priceLabel => usd == 0 ? 'Free' : '\$${usd.toStringAsFixed(2)}';
  String get storeId => 'tt_$id';
}

const kBitsBundles = [
  Product(id: 'bits_100', name: 'Handful of Bits', kind: ProductKind.bits, usd: 0.99, bits: 100, icon: Icons.memory),
  Product(id: 'bits_550', name: 'Pouch of Bits', kind: ProductKind.bits, usd: 4.99, bits: 550, description: '+10% bonus', icon: Icons.memory),
  Product(id: 'bits_1200', name: 'Crate of Bits', kind: ProductKind.bits, usd: 9.99, bits: 1200, description: '+20% bonus', icon: Icons.memory),
  Product(id: 'bits_2500', name: 'Vault of Bits', kind: ProductKind.bits, usd: 19.99, bits: 2500, description: '+25% bonus', icon: Icons.memory),
  Product(id: 'bits_6500', name: 'Mainframe of Bits', kind: ProductKind.bits, usd: 49.99, bits: 6500, description: '+30% bonus', icon: Icons.memory),
];

const kThemeProducts = [
  Product(id: 'theme_classic', name: 'Obsidian', kind: ProductKind.theme, usd: 0, description: 'Default. Black and graphite streets with a soft violet glow.', color: Color(0xFF9A8CF0), icon: Icons.dark_mode),
  Product(id: 'theme_midnight', name: 'Midnight', kind: ProductKind.theme, usd: 1.99, description: 'Deep blue night streets with glowing roads.', color: Color(0xFF3F51B5), icon: Icons.nightlight),
  Product(id: 'theme_synthwave', name: 'Synthwave', kind: ProductKind.theme, usd: 2.99, description: 'Neon magenta grid and a retro sunset haze.', color: Color(0xFFFF00C8), icon: Icons.grid_on),
  Product(id: 'theme_vaporwave', name: 'Vaporwave', kind: ProductKind.theme, usd: 2.99, description: 'Pastel pink and teal aesthetic.', color: Color(0xFFFF9FF3), icon: Icons.landscape),
  Product(id: 'theme_noir', name: 'Noir', kind: ProductKind.theme, usd: 1.99, description: 'Black & white film grain with falling rain.', color: Color(0xFFBDBDBD), icon: Icons.movie),
  Product(id: 'theme_vinyl', name: 'Vintage Vinyl', kind: ProductKind.theme, usd: 1.99, description: 'Warm sepia tones and record-shop dust.', color: Color(0xFFD7A86E), icon: Icons.album),
  Product(id: 'theme_matrix', name: 'Digital Rain', kind: ProductKind.theme, usd: 2.99, description: 'Green code cascades over the city.', color: Color(0xFF00FF66), icon: Icons.code),
  Product(id: 'theme_arctic', name: 'Arctic', kind: ProductKind.theme, usd: 1.99, description: 'Icy blues with gentle snowfall.', color: Color(0xFF80DEEA), icon: Icons.ac_unit),
  Product(id: 'theme_lava', name: 'Magma', kind: ProductKind.theme, usd: 2.99, description: 'Molten streets and drifting embers.', color: Color(0xFFFF5722), icon: Icons.local_fire_department),
  Product(id: 'theme_aurora', name: 'Aurora', kind: ProductKind.theme, usd: 3.99, description: 'Shimmering northern lights over dark streets.', color: Color(0xFF69F0AE), icon: Icons.auto_awesome),
  Product(id: 'theme_candy', name: 'Candy', kind: ProductKind.theme, usd: 2.99, description: 'Giant lollipops and wrapped sweets drifting down from a sugar-pink sky.', color: Color(0xFFFF4FA3), icon: Icons.cake),
  Product(id: 'theme_sakura', name: 'Sakura', kind: ProductKind.theme, usd: 2.99, description: 'Soft pink blossoms drifting through town.', color: Color(0xFFF8BBD0), icon: Icons.local_florist),
];

const kHatProducts = [
  Product(id: 'hat_cap', name: 'Snapback', kind: ProductKind.hat, usd: 0.99, color: Color(0xFFE53935), icon: Icons.face),
  Product(id: 'hat_beanie', name: 'Beanie', kind: ProductKind.hat, usd: 0.99, color: Color(0xFF43A047), icon: Icons.face),
  Product(id: 'hat_headphones', name: 'Studio Headphones', kind: ProductKind.hat, usd: 1.99, color: Color(0xFF212121), icon: Icons.headphones),
  Product(id: 'hat_tophat', name: 'Top Hat', kind: ProductKind.hat, usd: 1.99, color: Color(0xFF263238), icon: Icons.face),
  Product(id: 'hat_cowboy', name: 'Cowboy Hat', kind: ProductKind.hat, usd: 1.99, color: Color(0xFF8D6E63), icon: Icons.face),
  Product(id: 'hat_party', name: 'Party Hat', kind: ProductKind.hat, usd: 0.99, color: Color(0xFFFFEB3B), icon: Icons.celebration),
  Product(id: 'hat_wizard', name: 'Wizard Hat', kind: ProductKind.hat, usd: 2.49, color: Color(0xFF5E35B1), icon: Icons.auto_fix_high),
  Product(id: 'hat_crown', name: 'Golden Crown', kind: ProductKind.hat, usd: 2.99, color: Color(0xFFFFC107), icon: Icons.workspace_premium),
  Product(id: 'hat_halo', name: 'Halo', kind: ProductKind.hat, usd: 2.99, color: Color(0xFFFFF59D), icon: Icons.circle_outlined),
];

const kShirtProducts = [
  Product(id: 'shirt_tee_red', name: 'Red Tee', kind: ProductKind.shirt, usd: 0.99, color: Color(0xFFE53935), icon: Icons.checkroom),
  Product(id: 'shirt_tee_black', name: 'Band Tee', kind: ProductKind.shirt, usd: 0.99, color: Color(0xFF212121), icon: Icons.checkroom),
  Product(id: 'shirt_striped', name: 'Striped Shirt', kind: ProductKind.shirt, usd: 1.49, color: Color(0xFF1E88E5), icon: Icons.checkroom),
  Product(id: 'shirt_hoodie', name: 'Hoodie', kind: ProductKind.shirt, usd: 1.99, color: Color(0xFF7E57C2), icon: Icons.checkroom),
  Product(id: 'shirt_hawaiian', name: 'Hawaiian Shirt', kind: ProductKind.shirt, usd: 1.99, color: Color(0xFF26A69A), icon: Icons.checkroom),
  Product(id: 'shirt_tux', name: 'Tuxedo', kind: ProductKind.shirt, usd: 2.49, color: Color(0xFF111111), icon: Icons.checkroom),
  Product(id: 'shirt_lightning', name: 'Lightning Tee', kind: ProductKind.shirt, usd: 1.99, color: Color(0xFFFFD600), icon: Icons.bolt),
  Product(id: 'shirt_rainbow', name: 'Rainbow Tee', kind: ProductKind.shirt, usd: 2.49, color: Color(0xFFFF4081), icon: Icons.gradient),
];

const kPetProducts = [
  Product(id: 'pet_cat', name: 'Vinyl Cat', kind: ProductKind.pet, usd: 2.99, color: Color(0xFFFF9800), icon: Icons.pets),
  Product(id: 'pet_dog', name: 'Beat Pup', kind: ProductKind.pet, usd: 2.99, color: Color(0xFF8D6E63), icon: Icons.pets),
  Product(id: 'pet_bird', name: 'Songbird', kind: ProductKind.pet, usd: 2.49, color: Color(0xFF29B6F6), icon: Icons.flutter_dash),
  Product(id: 'pet_slime', name: 'Bass Slime', kind: ProductKind.pet, usd: 1.99, color: Color(0xFF76FF03), icon: Icons.bubble_chart),
  Product(id: 'pet_robot', name: 'Drum Bot', kind: ProductKind.pet, usd: 3.49, color: Color(0xFF90A4AE), icon: Icons.smart_toy),
  Product(id: 'pet_ghost', name: 'Echo Ghost', kind: ProductKind.pet, usd: 2.99, color: Color(0xFFE0E0E0), icon: Icons.blur_on),
  Product(id: 'pet_dragon', name: 'Mini Dragon', kind: ProductKind.pet, usd: 4.99, color: Color(0xFFD50000), icon: Icons.whatshot),
];

const kBackpackProducts = [
  Product(id: 'bag_classic', name: 'Classic Backpack', kind: ProductKind.backpack, usd: 0.99, color: Color(0xFF1565C0), icon: Icons.backpack),
  Product(id: 'bag_boombox', name: 'Boombox', kind: ProductKind.backpack, usd: 1.99, color: Color(0xFF424242), icon: Icons.radio),
  Product(id: 'bag_guitar', name: 'Guitar Case', kind: ProductKind.backpack, usd: 1.99, color: Color(0xFF6D4C41), icon: Icons.music_note),
  Product(id: 'bag_crate', name: 'Vinyl Crate', kind: ProductKind.backpack, usd: 1.99, color: Color(0xFFA1887F), icon: Icons.inventory_2),
  Product(id: 'bag_jetpack', name: 'Jetpack', kind: ProductKind.backpack, usd: 3.99, color: Color(0xFFB0BEC5), icon: Icons.rocket_launch),
  Product(id: 'bag_wings', name: 'Angel Wings', kind: ProductKind.backpack, usd: 3.99, color: Color(0xFFFFFFFF), icon: Icons.flight),
];

final List<Product> kAllProducts = [
  ...kBitsBundles,
  ...kThemeProducts,
  ...kHatProducts,
  ...kShirtProducts,
  ...kPetProducts,
  ...kBackpackProducts,
];

Product? productById(String id) {
  for (final p in kAllProducts) {
    if (p.id == id) return p;
  }
  return null;
}

/// A pack of song cards bought with bits.
class PackDef {
  const PackDef({
    required this.id,
    required this.name,
    required this.bits,
    required this.cards,
    required this.description,
    required this.color,
    this.guaranteedMin,
    this.allMin = Rarity.common,
    this.luck = 1.0,
    this.shinyOdds = kShinyOdds,
    this.genreChoice = false,
    this.guaranteedShiny = false,
  });
  final String id;
  final String name;
  final int bits;
  final int cards;
  final String description;
  final Color color;

  /// At least one card of this rarity or higher.
  final Rarity? guaranteedMin;

  /// Every card is at least this rarity.
  final Rarity allMin;

  /// Multiplier on rare+ weights.
  final double luck;
  final int shinyOdds;

  /// Player picks a genre first.
  final bool genreChoice;

  /// One card is guaranteed to be shiny.
  final bool guaranteedShiny;
}

const kPacks = [
  PackDef(
      id: 'pack_standard',
      name: 'Street Pack',
      bits: 100,
      cards: 5,
      description: '5 songs from any genre. At least one Uncommon or better.',
      color: Color(0xFF7A7A86),
      guaranteedMin: Rarity.uncommon),
  PackDef(
      id: 'pack_genre',
      name: 'Genre Pack',
      bits: 150,
      cards: 5,
      description: 'Pick a genre. 5 songs, at least one Rare or better.',
      color: Color(0xFF5E8C6A),
      guaranteedMin: Rarity.rare,
      genreChoice: true),
  PackDef(
      id: 'pack_rare',
      name: 'Hi-Fi Pack',
      bits: 350,
      cards: 5,
      description: 'All Uncommon or better, one Epic or better, boosted luck.',
      color: Color(0xFF4E6FA8),
      allMin: Rarity.uncommon,
      guaranteedMin: Rarity.epic,
      luck: 1.5),
  PackDef(
      id: 'pack_legend',
      name: 'Platinum Pack',
      bits: 1000,
      cards: 3,
      description: 'All Rare or better, with a guaranteed Legendary.',
      color: Color(0xFFB39550),
      allMin: Rarity.rare,
      guaranteedMin: Rarity.legendary,
      luck: 2.0,
      shinyOdds: 48),
  PackDef(
      id: 'pack_shiny',
      name: 'Prism Pack',
      bits: 1200,
      cards: 3,
      description: '3 songs with one guaranteed Shiny variant (any rarity).',
      color: Color(0xFF8A7AD6),
      luck: 1.5,
      guaranteedShiny: true),
];
