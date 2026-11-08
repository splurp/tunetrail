import json, urllib.request, urllib.parse, time
def get(u):
    for i in range(5):
        try:
            return json.load(urllib.request.urlopen(u, timeout=20))
        except Exception as e:
            time.sleep(1+i)
    return {}
seed={int(k):v for k,v in json.load(open('seed_ids.json')).items()}
manual=set()
classics={
 'rock':['Queen','The Beatles','Led Zeppelin','Pink Floyd','The Rolling Stones','David Bowie','Fleetwood Mac','Nirvana',"Guns N' Roses",'AC/DC','Red Hot Chili Peppers','Green Day','Foo Fighters','Coldplay','Linkin Park','The Killers','Muse','U2','Bon Jovi','Aerosmith','The Doors','Oasis','Imagine Dragons','Soda Stereo','Maná'],
 'metal':['Metallica','Iron Maiden','Black Sabbath','Motörhead','Slipknot','System of a Down','Rammstein','Megadeth','Pantera','Judas Priest','Avenged Sevenfold','Korn','Disturbed','Ghost','Gojira'],
 'pop':['Michael Jackson','Madonna','Whitney Houston','Taylor Swift','Lady Gaga','Britney Spears','ABBA','Elton John','Ed Sheeran','Adele','Dua Lipa','Billie Eilish','Ariana Grande','Harry Styles','Shakira','Stromae','Édith Piaf','Christine and the Queens','Indila','Angèle','Mylène Farmer','Enrique Iglesias','Elvis Presley','Bruno Mars','Katy Perry','Justin Bieber','Sabrina Carpenter','Olivia Rodrigo','Chappell Roan','Lana Del Rey'],
 'hiphop':['Eminem','2Pac','The Notorious B.I.G.','Kanye West','Drake','Kendrick Lamar','Jay-Z','Snoop Dogg','50 Cent','Travis Scott','Nicki Minaj','Cardi B','Lil Wayne','Tyler, The Creator','J. Cole','Post Malone','PNL','Gims','Aya Nakamura','Booba','Nekfeu','Ninho','Jul','Outkast','Wu-Tang Clan','Run-DMC','Missy Elliott','Doja Cat'],
 'rnb':['Beyoncé','Rihanna','Usher','Alicia Keys','Frank Ocean','The Weeknd','SZA','Mariah Carey','Prince','Stevie Wonder','Marvin Gaye','Aretha Franklin','Destiny\'s Child','Chris Brown','H.E.R.','Daniel Caesar','Bruno Mars'],
 'country':['Johnny Cash','Dolly Parton','Garth Brooks','Shania Twain','Luke Combs','Morgan Wallen','Willie Nelson','Kenny Rogers','Carrie Underwood','Chris Stapleton','Zach Bryan','Kacey Musgraves','Tim McGraw','Blake Shelton','Luke Bryan','Lainey Wilson'],
 'electronic':['Daft Punk','Avicii','Calvin Harris','Skrillex','David Guetta','Deadmau5','The Chemical Brothers','Swedish House Mafia','Martin Garrix','Kygo','Marshmello','Fred again..','Justice','The Prodigy','Disclosure','Kavinsky','Moby','Fatboy Slim','Tiësto'],
 'kpop':['BTS','BLACKPINK','TWICE','EXO','Stray Kids','NewJeans','BIGBANG','SEVENTEEN','Red Velvet','ITZY','aespa','IVE','LE SSERAFIM','PSY','Jungkook','Jennie','ROSÉ','LISA'],
 'indie':['Radiohead','Arctic Monkeys','The Strokes','Tame Impala','Gorillaz','Vampire Weekend','Florence + The Machine','Lorde','The 1975','Mac DeMarco','Phoebe Bridgers','Bon Iver','The National','MGMT','Phoenix','Franz Ferdinand','The White Stripes','Glass Animals','Cage The Elephant','Hozier'],
 'latin':['Bad Bunny','Daddy Yankee','J Balvin','Rosalía','Juanes','Karol G','Ozuna','Shakira','Maluma','Peso Pluma','Rauw Alejandro','Luis Fonsi','Marc Anthony','Selena','Romeo Santos','Anuel AA','Feid'],
}
for cat,names in classics.items():
    for n in names:
        r=get('https://api.deezer.com/search/artist?q='+urllib.parse.quote(n)+'&limit=3').get('data',[])
        best=None
        for a in r:
            if a['name'].lower()==n.lower(): best=a; break
        if best is None and r: best=max(r,key=lambda a:a.get('nb_fan',0))
        if best:
            seed.setdefault(best['id'],[]).insert(0,cat)
            manual.add(best['id'])
        time.sleep(0.05)
print('seeded',len(seed))
out=[]
for aid,cats in seed.items():
    a=get(f'https://api.deezer.com/artist/{aid}')
    if not a or 'name' not in a: continue
    if a.get('nb_fan',0) < (200000 if aid in manual else 1000000): continue
    out.append({'id':aid,'name':a['name'],'fans':a['nb_fan'],'pic':a.get('picture_medium','').split('/artist/')[-1].split('/')[0] if 'picture_medium' in a else '','cats':cats,'manual':aid in manual})
    time.sleep(0.03)
print('popular',len(out))
json.dump(out,open('popular.json','w'),ensure_ascii=False)
