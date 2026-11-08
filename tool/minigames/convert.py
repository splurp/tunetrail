"""Turns enriched.json (seed.py -> enrich.py -> mb.py) into the app's
assets/minigames/artists.json: one game genre per artist, a language
guess from country/genre, hometown, and debut year."""
import json, sys
src = sys.argv[1] if len(sys.argv) > 1 else 'enriched.json'
dst = sys.argv[2] if len(sys.argv) > 2 else '../../assets/minigames/artists.json'
priority = ['kpop', 'metal', 'country', 'hiphop', 'rnb', 'electronic', 'indie', 'rock', 'pop', 'latin']
genre_of = {'latin': 'pop'}  # Latin pop/reggaeton plays as Pop
lang_by_country = {
    **{c: 'english' for c in 'US GB CA AU IE NZ JM BB TT ZA'.split()},
    **{c: 'spanish' for c in 'ES MX AR CO PR CL PE VE CU DO UY EC PA GT CR HN SV BO PY NI'.split()},
    **{c: 'french' for c in 'FR BE CH LU MC SN CI CM CD HT'.split()},
    **{c: 'portuguese' for c in 'BR PT AO MZ CV'.split()},
    'KR': 'korean', 'DE': 'german', 'AT': 'german', 'IT': 'italian', 'JP': 'japanese',
}
countries = {'US': 'United States', 'GB': 'United Kingdom', 'XE': 'Europe'}
out, skipped = [], []
for a in json.load(open(src)):
    cats = [c for c in a['cats'] if c in priority]
    if not cats:
        skipped.append(a['name']); continue
    cat = min(cats, key=priority.index) if a.get('manual') is False else cats[0]
    genre = genre_of.get(cat, cat)
    cc = a.get('country')
    lang = 'korean' if cat == 'kpop' else lang_by_country.get(cc, 'english' if cc in (None, 'SE', 'NO', 'DK', 'FI', 'NL', 'IS') else 'other')
    if cat == 'latin' and lang == 'english':
        lang = 'spanish'
    area = a.get('area')
    country = area if area and (cc is None or len(area) > 2) else countries.get(cc, cc)
    city = a.get('beginArea')
    if city == country:
        city = None
    year = a.get('firstYear')
    begin = a.get('begin')
    # Groups: the band's founding year if it's later than the earliest
    # (often mis-dated) catalogue entry; otherwise the first release.
    if a.get('type') == 'Group' and begin and begin[:4].isdigit() and year and int(begin[:4]) > year:
        year = int(begin[:4])
    out.append({'id': a['id'], 'name': a['name'], 'pic': a['pic'], 'genre': genre, 'lang': lang,
                'city': city, 'country': country, 'year': year, 'fans': a['fans']})
out.sort(key=lambda x: -x['fans'])
json.dump(out, open(dst, 'w'), ensure_ascii=False, indent=0)
print(len(out), 'artists; skipped', len(skipped))
