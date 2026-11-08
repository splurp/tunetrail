import json, urllib.request, urllib.parse, time, unicodedata
UA='Tunetrail/0.1 (game dev data build)'
def get(u, ua=False):
    for i in range(5):
        try:
            req=urllib.request.Request(u, headers={'User-Agent':UA,'Accept':'application/json'} if ua else {})
            return json.load(urllib.request.urlopen(req, timeout=25))
        except Exception as e:
            time.sleep(1.5+i)
    return {}
def norm(s):
    s=unicodedata.normalize('NFKD',s).encode('ascii','ignore').decode().lower()
    return ''.join(c for c in s if c.isalnum())
arts=json.load(open('popular.json'))
out=[]
for i,a in enumerate(arts):
    q='artist:"%s"'%a['name'].replace('"','')
    r=get('https://musicbrainz.org/ws/2/artist/?query='+urllib.parse.quote(q)+'&fmt=json&limit=5', ua=True)
    time.sleep(1.1)
    best=None
    for c in r.get('artists',[]):
        if norm(c.get('name',''))==norm(a['name']) or any(norm(x.get('name',''))==norm(a['name']) for x in c.get('aliases',[]) or []):
            best=c; break
    if best is None and r.get('artists'):
        c=r['artists'][0]
        if c.get('score',0)>=95: best=c
    alb=get(f"https://api.deezer.com/artist/{a['id']}/albums?limit=200")
    years=[int(x['release_date'][:4]) for x in alb.get('data',[]) if x.get('release_date','')[:4].isdigit() and int(x['release_date'][:4])>1900]
    a['firstYear']=min(years) if years else None
    if best:
        a['country']=best.get('country') or (best.get('area') or {}).get('iso-3166-1-codes',[None])[0] if best.get('area') else best.get('country')
        a['area']=(best.get('area') or {}).get('name')
        a['beginArea']=(best.get('begin-area') or {}).get('name')
        a['type']=best.get('type')
        a['begin']=(best.get('life-span') or {}).get('begin')
    out.append(a)
    if i%20==0: print(i, a['name'], a.get('beginArea'), a.get('area'), a.get('country'), a['firstYear'], flush=True)
json.dump(out,open('enriched.json','w'),ensure_ascii=False,indent=0)
print('done',len(out))
