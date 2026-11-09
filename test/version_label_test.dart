import 'package:flutter_test/flutter_test.dart';
import 'package:tunetrail/data/models.dart';

void main() {
  test('song version labels', () {
    expect(songVersionLabel('Gnarly'), isNull);
    expect(songVersionLabel('Gnarly (Ice Spice Remix)'), 'Ice Spice Remix');
    expect(songVersionLabel('Gnarly (Clean Edit)'), 'Clean Edit');
    expect(songVersionLabel('Gnarly (Sped Up)'), 'Sped Up');
    expect(songVersionLabel('Let It Be - Remastered 2009'), 'Remastered 2009');
    expect(songVersionLabel('IM NOT GOD BUT I WISH I WAS (feat. Joeyy)'), isNull);
  });
}
