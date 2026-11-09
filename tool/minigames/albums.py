"""Builds assets/minigames/albums.json: famous albums whose covers do not
show the album's title (so the cover doesn't give the answer away).

    python3 tool/minigames/albums.py   (needs network access to api.deezer.com)
"""
import json, re, sys, time, urllib.parse, urllib.request

# (artist, album title as it should be answered, genre, language)
ALBUMS = [
    ("Kanye West", "My Beautiful Dark Twisted Fantasy", "hiphop", "english"),
    ("Kanye West", "Yeezus", "hiphop", "english"),
    ("JAY-Z & Kanye West", "Watch The Throne", "hiphop", "english"),
    ("Kendrick Lamar", "To Pimp A Butterfly", "hiphop", "english"),
    ("Travis Scott", "ASTROWORLD", "hiphop", "english"),
    ("Drake", "Nothing Was The Same", "hiphop", "english"),
    ("Drake", "Views", "hiphop", "english"),
    ("Post Malone", "Hollywood's Bleeding", "hiphop", "english"),
    ("SZA", "SOS", "rnb", "english"),
    ("SZA", "Ctrl", "rnb", "english"),
    ("The Weeknd", "After Hours", "rnb", "english"),
    ("The Weeknd", "Beauty Behind The Madness", "rnb", "english"),
    ("Billie Eilish", "WHEN WE ALL FALL ASLEEP, WHERE DO WE GO?", "pop", "english"),
    ("Harry Styles", "Fine Line", "pop", "english"),
    ("Lorde", "Melodrama", "pop", "english"),
    ("Bad Bunny", "Un Verano Sin Ti", "pop", "spanish"),
    ("Pink Floyd", "The Dark Side Of The Moon", "rock", "english"),
    ("Pink Floyd", "Wish You Were Here", "rock", "english"),
    ("Pink Floyd", "Animals", "rock", "english"),
    ("The Beatles", "Abbey Road", "rock", "english"),
    ("Led Zeppelin", "Led Zeppelin IV", "rock", "english"),
    ("Arctic Monkeys", "Whatever People Say I Am, That's What I'm Not", "rock", "english"),
    ("The Strokes", "Is This It", "rock", "english"),
    ("Joy Division", "Unknown Pleasures", "rock", "english"),
    ("Kanye West", "ye", "hiphop", "english"),
    ("Kendrick Lamar", "Mr. Morale & The Big Steppers", "hiphop", "english"),
    ("Travis Scott", "Rodeo", "hiphop", "english"),
    ("Tyler, The Creator", "Flower Boy", "hiphop", "english"),
    ("Mac Miller", "Swimming", "hiphop", "english"),
    ("Juice WRLD", "Legends Never Die", "hiphop", "english"),
    ("Beyoncé", "RENAISSANCE", "rnb", "english"),
    ("Rihanna", "ANTI", "pop", "english"),
    ("Olivia Rodrigo", "SOUR", "pop", "english"),
    ("Doja Cat", "Planet Her", "pop", "english"),
    ("Bad Bunny", "El Último Tour Del Mundo", "pop", "spanish"),
    ("MGMT", "Oracular Spectacular", "rock", "english"),
    ("Childish Gambino", "Because the Internet", "hiphop", "english"),
]
# Deezer album ids for when the search picks a cover version.
FIXED = {"After Hours": 137272602}

def get(url):
    for _ in range(4):
        try:
            with urllib.request.urlopen(url, timeout=20) as r:
                return json.load(r)
        except Exception as e:
            err = e
            time.sleep(1.5)
    raise err

def norm(s):
    return re.sub(r"[^a-z0-9]", "", s.lower())

out = []
for artist, title, genre, lang in ALBUMS:
    if title in FIXED:
        a = get(f"https://api.deezer.com/album/{FIXED[title]}")
        if a.get("artist", {}).get("name", "").lower() == artist.lower():
            md5 = a["cover_xl"].split("/cover/")[1].split("/")[0]
            out.append({"albumId": a["id"], "title": title, "artistId": a["artist"]["id"], "artist": a["artist"]["name"], "cover": md5, "genre": genre, "lang": lang})
            print(f'{artist:22} {title[:40]:40} -> {a["title"][:50]} ({a["id"]}) fixed')
            continue
        print("FIXED MISMATCH", artist, title, a.get("title"), a.get("artist", {}).get("name"), file=sys.stderr)
    q = urllib.parse.quote(f'artist:"{artist.split(" & ")[0]}" album:"{title}"')
    res = get(f"https://api.deezer.com/search/album?q={q}&limit=25").get("data", [])
    if not res:
        res = get(f"https://api.deezer.com/search/album?q={urllib.parse.quote(artist + ' ' + title)}&limit=25").get("data", [])
    want = norm(title)
    # Only the artist's own releases (not covers or tributes).
    names = {norm(n) for n in artist.split(" & ")}
    res = [a for a in res if norm(a["artist"]["name"]) in names or norm(a["artist"]["name"]) == norm(artist)]
    cands = [a for a in res if norm(a["title"]).startswith(want) and a.get("record_type") == "album"] or [a for a in res if want in norm(a["title"])]
    if not cands:
        print("MISSING", artist, title, [a["title"] for a in res[:5]], file=sys.stderr)
        continue
    # The plain edition first (shortest title), then the most tracks.
    a = sorted(cands, key=lambda a: (len(a["title"]), -a.get("nb_tracks", 0)))[0]
    md5 = a["cover_xl"].split("/cover/")[1].split("/")[0]
    out.append({"albumId": a["id"], "title": title, "artistId": a["artist"]["id"], "artist": a["artist"]["name"],
                "cover": md5, "genre": genre, "lang": lang})
    print(f'{artist:22} {title[:40]:40} -> {a["title"][:50]} ({a["id"]})')
# Original release years where Deezer only has a reissue.
YEARS = {"Wish You Were Here": 1975, "Abbey Road": 1969, "Unknown Pleasures": 1979}
for a in out:
    a["year"] = YEARS.get(a["title"]) or int((get(f"https://api.deezer.com/album/{a['albumId']}").get("release_date") or "0")[:4])
json.dump(out, open("assets/minigames/albums.json", "w"), indent=0, ensure_ascii=False)
print(len(out), "albums")
