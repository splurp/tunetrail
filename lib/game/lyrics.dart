/// Finish the Lyric: famous lines from songs known around the world, each
/// with its real ending and three plausible wrong ones. Only one short line
/// per song is quoted.
class LyricLine {
  const LyricLine(this.start, this.answer, this.wrong, this.title, this.artist);

  /// The line up to the missing ending.
  final String start;
  final String answer;

  /// Three believable wrong endings.
  final List<String> wrong;
  final String title, artist;
}

const kLyricLines = <LyricLine>[
  LyricLine('Is this the real life? Is this just…', 'fantasy?', ['a dream?', 'make-believe?', 'a game?'], 'Bohemian Rhapsody', 'Queen'),
  LyricLine('Billie Jean is not my…', 'lover', ['daughter', 'baby', 'girlfriend'], 'Billie Jean', 'Michael Jackson'),
  LyricLine('We could have had it…', 'all', ['made', 'right', 'good'], 'Rolling in the Deep', 'Adele'),
  LyricLine('Here we are now…', 'entertain us', ['take us home', 'set us free', 'show us how'], 'Smells Like Teen Spirit', 'Nirvana'),
  LyricLine('And after all, you\'re my…', 'wonderwall', ['only one', 'saving grace', 'shining star'], 'Wonderwall', 'Oasis'),
  LyricLine('Hey Jude, don\'t make it…', 'bad', ['hard', 'sad', 'wrong'], 'Hey Jude', 'The Beatles'),
  LyricLine('When I find myself in times of…', 'trouble', ['sorrow', 'darkness', 'heartache'], 'Let It Be', 'The Beatles'),
  LyricLine('Buddy, you\'re a boy, make a big noise, playing in the…', 'street', ['rain', 'band', 'park'], 'We Will Rock You', 'Queen'),
  LyricLine('Just a small-town girl, livin\' in a…', 'lonely world', ['crazy world', 'city of dreams', 'world of her own'], 'Don\'t Stop Believin\'', 'Journey'),
  LyricLine('Whoa, we\'re halfway…', 'there', ['home', 'gone', 'through'], 'Livin\' on a Prayer', 'Bon Jovi'),
  LyricLine('I bless the rains down in…', 'Africa', ['the valley', 'the city', 'the desert'], 'Africa', 'Toto'),
  LyricLine('The club isn\'t the best place to find a…', 'lover', ['partner', 'friend', 'soulmate'], 'Shape of You', 'Ed Sheeran'),
  LyricLine('\'Cause the players gonna…', 'play, play, play, play, play', ['win, win, win, win, win', 'stay, stay, stay, stay, stay', 'say, say, say, say, say'], 'Shake It Off', 'Taylor Swift'),
  LyricLine('Got a long list of ex-…', 'lovers', ['boyfriends', 'friends', 'flames'], 'Blank Space', 'Taylor Swift'),
  LyricLine('Don\'t believe me, just…', 'watch', ['listen', 'look', 'wait'], 'Uptown Funk', 'Mark Ronson ft. Bruno Mars'),
  LyricLine('Clap along if you feel like a room without a…', 'roof', ['door', 'view', 'floor'], 'Happy', 'Pharrell Williams'),
  LyricLine('I want your ugly, I want your…', 'disease', ['secrets', 'heartbeat', 'madness'], 'Bad Romance', 'Lady Gaga'),
  LyricLine('Now that it\'s raining more than…', 'ever', ['before', 'yesterday', 'usual'], 'Umbrella', 'Rihanna ft. JAY-Z'),
  LyricLine('If you liked it then you shoulda put a…', 'ring on it', ['lock on it', 'name on it', 'price on it'], 'Single Ladies (Put a Ring on It)', 'Beyoncé'),
  LyricLine('His palms are sweaty, knees weak, arms are…', 'heavy', ['shaking', 'tired', 'steady'], 'Lose Yourself', 'Eminem'),
  LyricLine('My loneliness is…', 'killing me', ['taking over', 'all I know', 'breaking me'], '...Baby One More Time', 'Britney Spears'),
  LyricLine('Tell me why, ain\'t nothin\' but a…', 'heartache', ['mistake', 'memory', 'heartbreak'], 'I Want It That Way', 'Backstreet Boys'),
  LyricLine('At first I was afraid, I was…', 'petrified', ['terrified', 'paralysed', 'horrified'], 'I Will Survive', 'Gloria Gaynor'),
  LyricLine('You can dance, you can jive, having the time of…', 'your life', ['the night', 'your youth', 'the year'], 'Dancing Queen', 'ABBA'),
  LyricLine('Whether you\'re a brother or whether you\'re a…', 'mother', ['lover', 'sister', 'other'], 'Stayin\' Alive', 'Bee Gees'),
  LyricLine('You may say I\'m a dreamer, but I\'m not the…', 'only one', ['first one', 'last one', 'lonely one'], 'Imagine', 'John Lennon'),
  LyricLine('Don\'t worry about a thing, \'cause every little thing gonna be…', 'all right', ['just fine', 'okay', 'brand new'], 'Three Little Birds', 'Bob Marley & The Wailers'),
  LyricLine('Risin\' up, back on the…', 'street', ['road', 'top', 'track'], 'Eye of the Tiger', 'Survivor'),
  LyricLine('I used to rule the…', 'world', ['night', 'streets', 'stage'], 'Viva la Vida', 'Coldplay'),
  LyricLine('Look at the stars, look how they shine for…', 'you', ['us', 'me', 'all'], 'Yellow', 'Coldplay'),
  LyricLine('Coming out of my cage and I\'ve been doing just…', 'fine', ['time', 'right', 'great'], 'Mr. Brightside', 'The Killers'),
  LyricLine('Never gonna give you up, never gonna let you…', 'down', ['go', 'cry', 'fall'], 'Never Gonna Give You Up', 'Rick Astley'),
  LyricLine('Take on me, take me…', 'on', ['home', 'away', 'now'], 'Take On Me', 'a-ha'),
  LyricLine('Near, far, wherever you…', 'are', ['go', 'roam', 'stay'], 'My Heart Will Go On', 'Céline Dion'),
  LyricLine('Do you ever feel like a plastic…', 'bag', ['toy', 'doll', 'cup'], 'Firework', 'Katy Perry'),
  LyricLine('Hello, it\'s…', 'me', ['you', 'late', 'over'], 'Hello', 'Adele'),
  LyricLine('Now the day bleeds into…', 'nightfall', ['darkness', 'midnight', 'the evening'], 'Someone You Loved', 'Lewis Capaldi'),
  LyricLine('Baby, I\'m dancing in the dark with you between my…', 'arms', ['hands', 'sheets', 'dreams'], 'Perfect', 'Ed Sheeran'),
  LyricLine('I don\'t want a lot for…', 'Christmas', ['my birthday', 'the holidays', 'New Year'], 'All I Want for Christmas Is You', 'Mariah Carey'),
  LyricLine('I said, ooh, I\'m blinded by the…', 'lights', ['night', 'stars', 'sun'], 'Blinding Lights', 'The Weeknd'),
  LyricLine('I\'ll tell you what I want, what I really, really…', 'want', ['need', 'mean', 'like'], 'Wannabe', 'Spice Girls'),
  LyricLine('It\'s fun to stay at the…', 'Y.M.C.A.', ['disco', 'Hotel California', 'local bar'], 'Y.M.C.A.', 'Village People'),
  LyricLine('I\'m a shooting star, leaping through the…', 'sky', ['night', 'stars', 'air'], 'Don\'t Stop Me Now', 'Queen'),
  LyricLine('In this world, it\'s just us, you know it\'s not the same as it…', 'was', ['seems', 'used to be', 'should be'], 'As It Was', 'Harry Styles'),
  LyricLine('Sweet Caroline, good times never seemed so…', 'good', ['bright', 'sweet', 'fine'], 'Sweet Caroline', 'Neil Diamond'),
  LyricLine('You can check out any time you like, but you can never…', 'leave', ['stay', 'return', 'go home'], 'Hotel California', 'Eagles'),
  LyricLine('\'Cause this is thriller, thriller…', 'night', ['time', 'fright', 'life'], 'Thriller', 'Michael Jackson'),
  LyricLine('Like a virgin, touched for the very…', 'first time', ['last time', 'one time', 'right time'], 'Like a Virgin', 'Madonna'),
  LyricLine('Girls just want to have…', 'fun', ['love', 'more', 'everything'], 'Girls Just Want to Have Fun', 'Cyndi Lauper'),
  LyricLine('And now, the end is near, and so I face the final…', 'curtain', ['chapter', 'hour', 'answer'], 'My Way', 'Frank Sinatra'),
  LyricLine('You want me, I want you, baby. My sugarboo, I\'m…', 'levitating', ['falling for you', 'flying high', 'losing my mind'], 'Levitating', 'Dua Lipa'),
  LyricLine('Where do we go…', 'now', ['from here', 'tonight', 'today'], 'Sweet Child O\' Mine', 'Guns N\' Roses'),
];
