import 'rarity.dart';

/// 64-bit mixing function (SplitMix64 finalizer). Works on native Dart ints.
int mix64(int z) {
  z = (z ^ (z >>> 30)) * -4658895280553007687; // 0xbf58476d1ce4e5b9
  z = (z ^ (z >>> 27)) * -7723592293110705685; // 0x94d049bb133111eb
  return z ^ (z >>> 31);
}

/// Combines several integers into one deterministic hash.
int hashInts(List<int> values) {
  var h = 0x2545F4914F6CDD1D;
  for (final v in values) {
    h = mix64(h ^ mix64(v + 0x9E3779B97F4A7C15));
  }
  return h;
}

/// Hash for strings (FNV-1a 64 then mixed).
int hashString(String s) {
  var h = -3750763034362895579; // 0xcbf29ce484222325
  for (final c in s.codeUnits) {
    h ^= c;
    h *= 0x100000001b3;
  }
  return mix64(h);
}

/// Small, fast deterministic PRNG (SplitMix64).
class Rng {
  Rng(int seed) : _state = seed;
  int _state;

  int nextInt64() {
    _state += 0x9E3779B97F4A7C15;
    return mix64(_state);
  }

  /// Uniform integer in [0, max).
  int nextInt(int max) {
    if (max <= 0) return 0;
    return (nextInt64() >>> 1) % max;
  }

  /// Uniform double in [0, 1).
  double nextDouble() => (nextInt64() >>> 11) / 9007199254740992.0;

  bool chance(int oneIn) => nextInt(oneIn) == 0;

  T pick<T>(List<T> items) => items[nextInt(items.length)];

  /// Rolls a rarity using the default spawn weights, optionally shifted.
  Rarity rollRarity({int minIndex = 0, double luck = 1.0}) {
    final candidates =
        Rarity.values.where((r) => r.index >= minIndex).toList();
    final weights = [
      for (final r in candidates)
        (r.spawnWeight * (r.index >= 2 ? luck : 1.0)).round()
    ];
    final total = weights.fold<int>(0, (a, b) => a + b);
    var roll = nextInt(total);
    for (var i = 0; i < candidates.length; i++) {
      roll -= weights[i];
      if (roll < 0) return candidates[i];
    }
    return candidates.last;
  }
}
