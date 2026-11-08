# Tunetrail

A location-based music collecting game. Walk around the real world, catch
popular songs floating on the map, complete quests, open packs, trade on a
player market and build playlists you can actually listen to.

Built with **Flutter** (Dart, AOT-compiled to native code) from one codebase
for **Android, iOS, Windows**, plus macOS and Linux.

![Tunetrail screenshots](docs/screenshots.jpg)

---|---|---|---|
| Player stick figure at the centre, songs float and glow by rarity | Virtualised grid, instant filter & sort | Beat-ring catch minigame with song preview | NPC/online listings, trades, showcases |

---

## Downloads

Every push builds through GitHub Actions (`.github/workflows/build.yml`) and
publishes a **GitHub Release** with:

* `Tunetrail-windows-x64-setup.exe` (installer) and `Tunetrail-windows-x64.zip` (portable: extract, run `Tunetrail.exe`)
* `Tunetrail-android-universal.apk` (any device) and per-ABI APKs (`arm64` suits most phones)

APKs are signed with the debug key (developer build): enable *Install unknown apps* to sideload.

## Gameplay

* **Real-world map.** OpenStreetMap street data. The player is always at the centre (pinch to zoom, two-finger rotate).
* **Wild spawns.** The world is split into ~200 m cells and 15-minute windows. Each cell/window is hashed into a seed, so **everyone in the same place at the same time sees the same songs**, with no server needed. Time of day biases genres (electronic & R&B at night, folk & pop in the morning…).
* **Rarities:** Common (grey), Uncommon (green), Rare (blue), Epic (purple), Legendary (gold). Rarer spawns glow brighter, and Legendaries get rotating light rays.
* **Shiny variants** (1/128): an animated glint sweeps across the card and across the rarity name everywhere it's shown (collection, market, playlists, showcases).
* **Catching:** tap a song within 70 m to open the encounter. The 30-second preview plays while a beat ring pulses; tap when it lines up with the target. Rarer songs pulse faster and flee more often.
* **Quests:** 4 rotating dailies; weekly **Artist Spotlights** (collect N songs by an artist → unlock an exclusive Epic/Legendary card of their biggest hit); **Album completion** (own every track on an album → Legendary card); milestones.
* **Discography browser:** artist pages (picture, top tracks, albums/EPs/singles) and album pages in official track order, showing which tracks you own.
* **Currencies:** **coins** (earned by catching, quests and selling; spent on the player market) and **bits** (bought with real money; spent on packs).
* **Packs** (bits): Street, Genre (pick a genre), Hi-Fi, Platinum (guaranteed Legendary), Prism (guaranteed Shiny). Drop rates are shown in-app.
* **Player market:** list cards for coins (held in escrow), buy, make **trade offers** (cards + coins) on trade-enabled listings, accept/decline offers, and publish a **showcase** of favourite cards and playlists that others can browse, like and listen to.
* **Playlists:** build them from owned cards, reorder, and play them back (30-second Deezer previews, auto-advance, mini player).
* **Character:** a stylised stick figure. Colour is free to change. Hats, shirts, backpacks and pets are sold in the store.
* **Map themes** (store): Classic, Midnight, Synthwave, Vaporwave, Noir (rain & film grain), Vintage Vinyl, Digital Rain, Arctic (snow), Magma (embers), Aurora, Sakura (petals).

## Developer debug menu

Profile → ⚙ Settings → **Debug menu** switch, then *Open debug menu*:

* Set coin and bit balances (presets up to 10M)
* **Free real-money purchases** (bits bundles, themes and cosmetics granted with no charge), or unlock everything at once
* **Joystick movement** with a speed multiplier (×1–×50); on PC, **WASD / arrow keys** also work
* **Teleport:** search any real-world place (OpenStreetMap Nominatim) or pick a preset, then jump there (also on the map's 🔍 button)
* Unlimited catch range, respawn nearby songs
* Stress test: add 1k / 10k / 100k random cards, clear the collection, crawl more of the catalog

## Data sources (all free, no API keys)

| What | Source |
|---|---|
| Songs, artists, albums, track order, discographies, cover art, artist photos, 30 s previews | [Deezer public API](https://developers.deezer.com/api) |
| Street map tiles | © [OpenStreetMap](https://www.openstreetmap.org/copyright) contributors |
| Place search (teleport) | OpenStreetMap Nominatim |

The catalog is built progressively: genre charts first (instantly playable),
then each genre's most popular artists' top tracks, then related artists
above a fan threshold. **Non-English genres** (Latin, Reggaeton, K-Pop/Asian,
Brazilian, African, Indian) only admit artists with ≥500k Deezer fans, and
genre spawn weights keep the game primarily English-language. The crawl
targets ~60k songs (the debug menu can push it further); the result is cached
locally as JSON lines.

> **Before a public launch:** OSM's tile servers are for light use only. Point
> *Settings → Map tile server* at your own or a commercial tile provider (any
> `{z}/{x}/{y}` URL template works). Deezer previews are 30 s clips; full-track
> playback needs a licensed provider.

## Performance (100,000+ cards)

The collection (`lib/data/collection.dart`) is stored **column-wise in typed
arrays**, about 26 bytes per card, so 100k cards take ~2.6 MB of RAM and load
from a binary file in milliseconds. Queries filter directly over the arrays,
then sort by packing *(primary key, secondary key, index)* into one 63-bit
integer per card and sorting an `Int64List`. Alphabetical sorts use
precomputed title/artist rank tables, so no strings are compared while
sorting. The UI is a virtualised grid/list that only builds visible cards,
decodes artwork at thumbnail size, and shares one animation clock across
every shiny glint.

`flutter test` includes a 100k-card benchmark (filter, sort by
date/title/artist/rarity, text search, persistence round trip).

## Multiplayer market server

The app runs a **local market** by default (offline, with simulated NPC
traders that list, buy and answer trade offers). For real player-to-player
trading, run the server and switch *Settings → Market → Online*:

```bash
cd server
dart pub get
dart run bin/server.dart --port 8080 --data market.json
```

The client and the server share the same market engine
(`packages/tunetrail_core`), so behaviour is identical. This is a **developer
server**: it has no authentication and trusts client-reported coin balances.
A production deployment should add accounts and server-side balances, and
should verify store receipts on the server.

## Real-money purchases

`lib/game/purchase_service.dart` uses `in_app_purchase` (Google Play Billing /
StoreKit) on Android and iOS. Product IDs are `tt_<id>` (e.g. `tt_bits_550`,
`tt_theme_synthwave`, `tt_hat_crown`); see `lib/game/store_catalog.dart`.
Create matching products in Play Console / App Store Connect. Windows has no
store integration in this build, so use the debug *free purchases* switch.

## Building locally

```bash
flutter pub get
flutter run                      # any connected device / desktop
flutter build apk --release      # Android (Linux/macOS/Windows host)
flutter build windows --release  # Windows (Windows host required)
flutter build ios --release      # iOS (macOS + Xcode required)
flutter test                     # unit tests incl. 100k-card benchmark
```

## Project layout

```
lib/
  data/        models, Deezer client, catalog crawler, collection store, save file
  game/        game controller, spawns, quests, packs/store catalog, market, IAP, GPS/joystick, audio
  ui/          app shell, map (+ themes, markers), screens, widgets (cards, glint, stick figure)
packages/tunetrail_core/   shared pure-Dart logic: rarities, RNG, market engine (+ tests)
server/                    multiplayer market HTTP server (shelf)
.github/workflows/         CI: tests → Android APKs + Windows exe/installer → GitHub Release
```
