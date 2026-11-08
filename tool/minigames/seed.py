import json, urllib.request, time
def get(u):
    for i in range(4):
        try:
            return json.load(urllib.request.urlopen(u, timeout=20))
        except Exception as e:
            time.sleep(1+i)
    return {}
cats = {  # our category -> deezer genre ids
 'pop':[132], 'hiphop':[116], 'rock':[152], 'metal':[464], 'electronic':[106,113], 'rnb':[165,169],
 'country':[84], 'kpop':[16], 'indie':[85], 'latin':[197,122],
}
artists={}
for cat,gids in cats.items():
    for gid in gids:
        ids=[a['id'] for a in get(f'https://api.deezer.com/genre/{gid}/artists').get('data',[])]
        ids+=[a['artist']['id'] for a in get(f'https://api.deezer.com/chart/{gid}/tracks?limit=100').get('data',[])]
        for aid in ids:
            artists.setdefault(aid,[]).append(cat)
print(len(artists))
json.dump(artists,open('seed_ids.json','w'))
