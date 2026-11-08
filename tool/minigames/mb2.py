"""Second pass: MusicBrainz id, genre tags and earliest release year, plus
Deezer top-track titles (for language detection)."""
import json, urllib.request, urllib.parse, time, unicodedata
UA='Tunetrail/0.1 (game dev data build)'
def get(u, ua=False):
    for i in range(5):
        try:
            req=urllib.request.Request(u, headers={'User-Agent':UA,'Accept':'application/json'} if ua else {})
            return json.load(urllib.request.urlopen(req, timeout=25))
        except Exception:
            time.sleep(1.5+i)
    return {}
def norm(s):
    s=unicodedata.normalize('NFKD',s).encode('ascii','ignore').decode().lower()
    return ''.join(c for c in s if c.isalnum())
arts=json.load(open('enriched.json'))
for i,a in enumerate(arts):
    q='artist:"%s"'%a['name'].replace('"','')
    r=get('https://musicbrainz.org/ws/2/artist/?query='+urllib.parse.quote(q)+'&fmt=json&limit=5', ua=True)
    time.sleep(1.05)
    best=None
    for c in r.get('artists',[]):
        if norm(c.get('name',''))==norm(a['name']): best=c; break
    if best is None and r.get('artists') and r['artists'][0].get('score',0)>=95: best=r['artists'][0]
    if best:
        a['mbid']=best['id']
        a['tags']={t['name']:t.get('count',1) for t in best.get('tags',[]) or []}
        rg=get(f"https://musicbrainz.org/ws/2/release-group?artist={best['id']}&type=album|single|ep&limit=100&fmt=json", ua=True)
        time.sleep(1.05)
        ys=[int(x['first-release-date'][:4]) for x in rg.get('release-groups',[]) if (x.get('first-release-date') or '')[:4].isdigit()]
        a['mbFirstYear']=min(ys) if ys else None
    top=get(f"https://api.deezer.com/artist/{a['id']}/top?limit=15")
    a['titles']=[t['title'] for t in top.get('data',[])]
    if i%20==0: print(i,a['name'],a.get('mbFirstYear'),list(a.get('tags',{}))[:4],flush=True)
json.dump(arts,open('enriched2.json','w'),ensure_ascii=False)
print('done',len(arts))
