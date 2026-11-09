import 'package:flutter/material.dart';

/// Background pattern drawn on a profile theme's banner.
enum ProfilePattern { none, dots, stripes, grid, grooves, stars, waves, rays, confetti, hearts }

/// A look for a player's public profile page. Players customise their
/// profile by picking one of these instead of uploading pictures, so no
/// images from players are ever stored or shown.
class ProfileTheme {
  const ProfileTheme({
    required this.id,
    required this.name,
    required this.colors,
    required this.accent,
    this.pattern = ProfilePattern.none,
    this.price = 0,
    this.description = '',
  });

  /// Stored on the server; always `pt_` + lowercase letters/digits.
  final String id;
  final String name;

  /// Banner gradient (top-left → bottom-right).
  final List<Color> colors;
  final Color accent;
  final ProfilePattern pattern;

  /// Price in bits (0 = free for everyone).
  final int price;
  final String description;

  bool get free => price == 0;

  /// Light background (use dark text on it).
  bool get light => colors.fold<double>(0, (a, c) => a + c.computeLuminance()) / colors.length > 0.4;
}

const kProfileThemes = [
  ProfileTheme(id: 'pt_graphite', name: 'Graphite', colors: [Color(0xFF2A2A31), Color(0xFF15151A)], accent: Color(0xFFB9B4FF), description: 'Clean and dark.'),
  ProfileTheme(id: 'pt_violet', name: 'Violet Haze', colors: [Color(0xFF4B3C9E), Color(0xFF1B1530)], accent: Color(0xFFCFC6FF), pattern: ProfilePattern.dots),
  ProfileTheme(id: 'pt_ocean', name: 'Deep Sea', colors: [Color(0xFF0F4C75), Color(0xFF07182A)], accent: Color(0xFF7FDBFF), pattern: ProfilePattern.waves),
  ProfileTheme(id: 'pt_mono', name: 'Monochrome', colors: [Color(0xFFE8E8E8), Color(0xFF6E6E6E)], accent: Color(0xFF111111), pattern: ProfilePattern.stripes, price: 100),
  ProfileTheme(id: 'pt_sunset', name: 'Sunset Drive', colors: [Color(0xFFFF7E5F), Color(0xFF5B2A86)], accent: Color(0xFFFFE29A), pattern: ProfilePattern.rays, price: 150),
  ProfileTheme(id: 'pt_forest', name: 'Evergreen', colors: [Color(0xFF2E7D32), Color(0xFF0B2B12)], accent: Color(0xFFB9F6CA), pattern: ProfilePattern.dots, price: 150),
  ProfileTheme(id: 'pt_vinyl', name: 'Vinyl Grooves', colors: [Color(0xFF26201B), Color(0xFF0B0908)], accent: Color(0xFFD7A86E), pattern: ProfilePattern.grooves, price: 200),
  ProfileTheme(id: 'pt_candy', name: 'Candy Stripes', colors: [Color(0xFFFF8FC7), Color(0xFFFFC2E2)], accent: Color(0xFF8E1F5C), pattern: ProfilePattern.stripes, price: 200),
  ProfileTheme(id: 'pt_neon', name: 'Neon Grid', colors: [Color(0xFF2B0040), Color(0xFF07001A)], accent: Color(0xFFFF2BD6), pattern: ProfilePattern.grid, price: 300),
  ProfileTheme(id: 'pt_lava', name: 'Magma', colors: [Color(0xFFFF5722), Color(0xFF3A0A00)], accent: Color(0xFFFFD180), pattern: ProfilePattern.waves, price: 300),
  ProfileTheme(id: 'pt_starfield', name: 'Starfield', colors: [Color(0xFF0B1033), Color(0xFF000000)], accent: Color(0xFFFFF59D), pattern: ProfilePattern.stars, price: 400),
  ProfileTheme(id: 'pt_waves', name: 'Soundwaves', colors: [Color(0xFF00897B), Color(0xFF0D1B2A)], accent: Color(0xFFA7FFEB), pattern: ProfilePattern.waves, price: 400),
  ProfileTheme(id: 'pt_party', name: 'Confetti', colors: [Color(0xFF3949AB), Color(0xFF1A237E)], accent: Color(0xFFFFEB3B), pattern: ProfilePattern.confetti, price: 500),
  ProfileTheme(id: 'pt_aurora', name: 'Aurora', colors: [Color(0xFF1DE9B6), Color(0xFF283593), Color(0xFF0A0F2C)], accent: Color(0xFFB2FFDA), pattern: ProfilePattern.stars, price: 600),
  ProfileTheme(id: 'pt_sweetheart', name: 'Sweetheart', colors: [Color(0xFFE91E63), Color(0xFF4A0E2B)], accent: Color(0xFFFFC1D9), pattern: ProfilePattern.hearts, price: 750),
  ProfileTheme(id: 'pt_gold', name: 'Gold Record', colors: [Color(0xFFFFD54F), Color(0xFF8D6E00)], accent: Color(0xFF2B1D00), pattern: ProfilePattern.grooves, price: 1000, description: 'For collectors who\'ve made it.'),
];

/// The theme with [id] (the default when unknown — e.g. from a newer
/// version of the game).
ProfileTheme profileThemeById(String? id) => kProfileThemes.firstWhere((t) => t.id == id, orElse: () => kProfileThemes.first);
