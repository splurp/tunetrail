import 'package:test/test.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

CardPayload card(int uid) => CardPayload(
      uid: uid,
      songId: uid,
      title: 'Song $uid',
      artistId: 1,
      artistName: 'Artist',
      albumId: 1,
      albumTitle: 'Album',
      coverMd5: '',
      rarity: Rarity.common,
      shiny: false,
    );

void main() {
  group('usernames', () {
    test('accepts letters, numbers, symbols and emoji', () {
      for (final n in ['Aidan', 'dj_pebble99', 'Ñandú', '漢字のなまえ', 'beat★drop', '🎧Mixer', '👩‍💻coder', '🇺🇸usa', '👍🏽ok', 'a.b-c!']) {
        expect(usernameError(n), isNull, reason: n);
      }
    });
    test('rejects markup, spaces, hidden and direction characters', () {
      for (final n in ['<script>', 'a"b', "o'neil", 'back`tick', 'a\\b', 'a/b', 'two words', 'tab\tx', 'zero​width', 'rtl‮evil',
          'bad\u0000', 'join‍me', 'nl\nx', 'ab', '', '...']) {
        expect(usernameError(n), isNotNull, reason: n.runes.toList().toString());
      }
    });
    test('length counts emoji as one character', () {
      expect(usernameError('a' * 24), isNull);
      expect(usernameError('a' * 25), isNotNull);
      expect(visibleLength('👨‍👩‍👧'), 1);
      expect(visibleLength('🇺🇸🇬🇧'), 2);
      expect(visibleLength('é'), 1);
    });
    test('blocks Zalgo and reserved names', () {
      expect(usernameError('Ź̂̃alg'), isNotNull);
      expect(usernameError('Admin'), isNotNull);
      expect(usernameError('Tunetrail_Official'), isNotNull);
    });
    test('look-alikes share a key', () {
      expect(usernameKey('José'), usernameKey('josé'));
      expect(usernameKey('Pаypal'), usernameKey('paypal')); // Cyrillic а
      expect(usernameKey('ＡＢＣ'), usernameKey('abc'));
    });
    test('clean text strips invisible characters', () {
      expect(cleanUserText('hi‮ there\u0000', maxLength: 50), 'hi there');
      expect(cleanUserText('a\n\n\n\nb', maxLength: 50, multiline: true), 'a\n\nb');
      expect(cleanUserText('x' * 600, maxLength: 500).length, 500);
    });
  });

  group('social', () {
    late MarketEngine m;
    setUp(() {
      m = MarketEngine(seed: 1)
        ..register('a', 'a')
        ..register('b', 'b');
    });

    test('usernames are unique ignoring case and look-alikes', () {
      m.setUsername('a', 'Melody');
      expect(() => m.setUsername('b', 'melody'), throwsA(isA<MarketException>()));
      expect(() => m.setUsername('b', 'Mеlody'), throwsA(isA<MarketException>())); // Cyrillic е
      m.setUsername('b', 'Harmony');
      expect(m.searchPlayers('mel').map((p) => p.id), ['a']);
      // Registering again never overwrites a chosen username.
      m.register('a', 'Google Name');
      expect(m.nameOf('a'), 'Melody');
    });

    test('direct offers trade collection songs', () {
      m.setCollection('b', [card(1), card(2)]);
      final o = m.createDirectOffer('a', 'b', [1], [card(10)], 50, note: 'pls');
      expect(m.offersFor('b').single.id, o.id);
      m.acceptOffer('b', o.id);
      final toB = m.claimInbox('b').single;
      expect(toB.coins, 50);
      expect(toB.cards.single.uid, 10);
      expect(m.claimInbox('a').single.cards.single.uid, 1);
      expect(m.collectionPage('b').cards.map((c) => c.uid), [2]);
    });

    test('offers for songs that left the collection are returned', () async {
      m.setCollection('b', [card(1)]);
      m.createDirectOffer('a', 'b', [1], const [], 5);
      await Future<void>.delayed(const Duration(milliseconds: 3100));
      m.setCollection('b', [card(2)]);
      expect(m.offersFor('b'), isEmpty);
      expect(m.claimInbox('a').single.coins, 5);
    });

    test('messages, unread counts and blocking', () {
      m.sendMessage('a', 'b', 'hello‮');
      expect(m.unreadCount('b'), 1);
      expect(m.thread('b', 'a').single.text, 'hello');
      expect(m.unreadCount('b'), 0);
      m.setBlocked('b', 'a', true);
      expect(() => m.sendMessage('a', 'b', 'hi'), throwsA(isA<MarketException>()));
      expect(() => m.createDirectOffer('a', 'b', [1], const [], 5), throwsA(isA<MarketException>()));
    });

    test('state survives a save and load', () {
      m.setUsername('a', 'Melody');
      m.setPublicProfile('a', theme: 'pt_neon', level: 7);
      m.sendMessage('a', 'b', 'yo');
      final copy = MarketEngine()..loadJson(m.toJson());
      expect(copy.players['a']!.named, isTrue);
      expect(copy.publicProfile('a').theme, 'pt_neon');
      expect(copy.conversations('b').single.unread, 1);
      expect(() => copy.setPublicProfile('a', theme: '<x>'), throwsA(isA<MarketException>()));
    });
  });
}
