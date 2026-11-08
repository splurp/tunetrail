"""Builds assets/minigames/artists.json from enriched2.json.

Pipeline: seed.py (Deezer genre charts/artists) -> enrich.py (+ hand-picked
classics, popularity filter) -> mb.py (MusicBrainz hometown/area, Deezer
earliest release) -> mb2.py (MusicBrainz genre tags + earliest release
group, Deezer top-track titles) -> convert.py.

* Genre: MusicBrainz community tags mapped onto the nine game genres
  (the Deezer chart an artist was seeded from is only a fallback — charts
  are noisy). Artists with no fitting genre are dropped.
* Debut year: earliest MusicBrainz release group (album/single/EP), else
  Deezer's earliest release.
* Language: K-pop -> Korean; otherwise detected from the artist's top song
  titles (stopwords), with the country as a tie-breaker.
"""
import json, re, sys, collections

src = sys.argv[1] if len(sys.argv) > 1 else 'enriched2.json'
dst = sys.argv[2] if len(sys.argv) > 2 else '../../assets/minigames/artists.json'

TAGS = {
    'kpop': ['k-pop', 'kpop', 'korean pop', 'k-hip hop'],
    'metal': ['metal', 'heavy metal', 'thrash metal', 'nu metal', 'death metal', 'alternative metal', 'industrial metal', 'metalcore',
              'speed metal', 'groove metal', 'progressive metal', 'black metal', 'doom metal', 'neue deutsche härte', 'hard rock'],
    'country': ['country', 'country pop', 'contemporary country', 'outlaw country', 'country rock', 'americana', 'bluegrass'],
    'hiphop': ['hip hop', 'hip-hop', 'rap', 'trap', 'gangsta rap', 'pop rap', 'east coast hip hop', 'west coast hip hop', 'french hip hop',
               'conscious hip hop', 'southern hip hop', 'drill', 'cloud rap', 'emo rap', 'rap français'],
    'rnb': ['r&b', 'rnb', 'contemporary r&b', 'soul', 'neo soul', 'funk', 'alternative r&b', 'motown', 'new jack swing'],
    'electronic': ['electronic', 'house', 'edm', 'electro house', 'dance', 'techno', 'electro', 'french house', 'trance', 'dubstep',
                   'progressive house', 'big room', 'electronica', 'synth-pop', 'drum and bass', 'uk garage', 'future bass', 'big beat'],
    'indie': ['indie', 'indie rock', 'indie pop', 'alternative', 'art rock', 'garage rock revival', 'post-punk revival', 'dream pop',
              'psychedelic pop', 'neo-psychedelia', 'indie folk', 'shoegaze', 'lo-fi', 'bedroom pop', 'post-punk', 'chamber pop'],
    'rock': ['rock', 'classic rock', 'pop rock', 'alternative rock', 'punk rock', 'grunge', 'pop punk', 'arena rock', 'glam rock',
             'progressive rock', 'blues rock', 'soft rock', 'post-grunge', 'rock and roll', 'britpop', 'psychedelic rock', 'rock en español'],
    'pop': ['pop', 'dance-pop', 'latin pop', 'reggaeton', 'latin', 'electropop', 'teen pop', 'synthpop', 'chanson', 'chanson française',
            'variété française', 'europop', 'urbano latino', 'latin trap', 'bachata', 'adult contemporary', 'pop soul', 'disco'],
}
TAG2 = {t: g for g, ts in TAGS.items() for t in ts}
# Ties / mixed artists: the more specific genre wins.
PRIORITY = ['kpop', 'metal', 'country', 'hiphop', 'rnb', 'electronic', 'indie', 'rock', 'pop']

STOP = {
    'english': 'the you i me my love a of to in it on your dont i\'m be all is what we baby girl like up night go heart',
    'spanish': 'el la de que y mi tu te amor no me con por para una lo yo se si mas como quiero corazon vida noche ella',
    'french': 'le la les de des je tu et pas mon ma pour une dans qui c\'est moi toi est sur au sans plus amour vie',
    'portuguese': 'não você eu meu minha do da com que pra é amor vida seu sua coração',
    'german': 'ich du und nicht der die das ein mein sie wir auf mit ist liebe dich mich zu',
    'italian': 'il di che e non per una mi ti amore sei la le gli io tu ci',
}
STOPS = {l: set(w.split()) for l, w in STOP.items()}
COUNTRY_LANG = {
    **{c: 'english' for c in 'US GB CA AU IE NZ JM BB TT ZA SE NO DK FI NL IS'.split()},
    **{c: 'spanish' for c in 'ES MX AR CO PR CL PE VE CU DO UY EC PA GT CR HN SV BO PY NI'.split()},
    **{c: 'french' for c in 'FR BE CH LU MC SN CI CM CD HT'.split()},
    **{c: 'portuguese' for c in 'BR PT AO MZ CV'.split()},
    'KR': 'korean', 'DE': 'german', 'AT': 'german', 'IT': 'italian', 'JP': 'japanese',
}


def genre(a):
    score = collections.Counter()
    for t, n in (a.get('tags') or {}).items():
        g = TAG2.get(t.lower())
        if g:
            score[g] += max(1, n)
    if score:
        top = max(score.values())
        best = [g for g in PRIORITY if score[g] >= top * 0.6]
        # Prefer the broad, strongly-voted genre unless a specific one is close.
        return best[0]
    cats = [('pop' if c == 'latin' else c) for c in a['cats']]
    if a.get('manual'):
        return cats[0]
    return None  # chart-only artists without tags are too uncertain


def language(a, g):
    if g == 'kpop' or a.get('country') == 'KR':
        return 'korean'
    words = re.findall(r"[a-zà-ÿ']+", ' '.join(a.get('titles', [])).lower())
    if re.search(r'[가-힣]', ' '.join(a.get('titles', []))):
        return 'korean'
    counts = {l: sum(1 for w in words if w in s) for l, s in STOPS.items()}
    prior = COUNTRY_LANG.get(a.get('country'))
    if prior:
        counts[prior] = counts.get(prior, 0) + 1.5
    best = max(counts, key=counts.get)
    return best if counts[best] > 0 else (prior or 'english')


out, skipped = [], []
for a in json.load(open(src)):
    g = genre(a)
    if g is None:
        skipped.append(a['name'])
        continue
    cc = a.get('country')
    area = a.get('area')
    country = area if area else cc
    city = a.get('beginArea')
    if city == country:
        city = None
    year = a.get('mbFirstYear') or a.get('firstYear')
    if a.get('firstYear') and year and a['firstYear'] < year and a['firstYear'] > 1940:
        year = min(year, a['firstYear'])
    out.append({'id': a['id'], 'name': a['name'], 'pic': a['pic'], 'genre': g, 'lang': language(a, g),
                'city': city, 'country': country, 'year': year, 'fans': a['fans']})
out.sort(key=lambda x: -x['fans'])
json.dump(out, open(dst, 'w'), ensure_ascii=False, indent=0)
print(len(out), 'artists; skipped (no reliable genre):', len(skipped), skipped[:20])
