# Tunetrail multiplayer: free hosting setup

Target: ~1,000 players, ~50 online at once, **$0/month**.

| Piece | Service | Cost |
|---|---|---|
| Game server (market, serial numbers, accounts) | Oracle Cloud **Always Free** ARM VM, running `deploy/docker-compose.yml` | $0 |
| HTTPS certificate | Caddy + Let's Encrypt (automatic, inside the compose file) | $0 |
| Server hostname | DuckDNS (free subdomain) | $0 |
| Database | Supabase **Free** Postgres (500 MB) | $0 |
| Google sign-in | Google Cloud OAuth clients | $0 |
| Builds & downloads | GitHub Actions + Releases (already set up) | $0 |

The server keeps its state in memory and saves it to Postgres after every
change, so run **one** server instance.

Do the steps in order. Anything in `ALL_CAPS` is a value you copy into a later step.

---

## 1. Database — Supabase (10 min)

1. Sign up at <https://supabase.com> → **New project**. Pick a region near your
   players, set a strong database password and save it.
2. When the project is ready, press **Connect** in the top bar of the project
   dashboard → **Connection String** tab, type **URI**, and copy the
   **Session pooler** string (it works over IPv4; the direct connection doesn't
   on the free plan).
   In **Project Settings → Data API**, you can turn the Data API off: the game
   server talks to Postgres directly and never uses it. Leave "automatically
   expose new tables" off and automatic RLS on.
3. Copy it and put your password in place of `[YOUR-PASSWORD]` → this is
   `DATABASE_URL`.

The server creates its own table (`tunetrail_state`) on first start.
Free projects pause after 7 days with no activity; any game traffic counts as
activity. If one pauses, press **Restore** in the dashboard.

## 2. Google sign-in — Google Cloud (20 min)

1. Go to <https://console.cloud.google.com>, create a project called `Tunetrail`.
2. **APIs & Services → OAuth consent screen** (Google now calls this the
   **Google Auth Platform**, with these sections in its left menu):
   - **Branding**: app name "Tunetrail", your e-mail as support and developer contact.
   - **Audience**: while the status is **Testing**, add your own Google account under
     **Test users** (only listed accounts can sign in). Press **Publish app** when
     you're ready for everyone; basic sign-in (name + account id) doesn't need
     Google's verification review.
   - **Data Access**: nothing to change; the game asks for `openid` and `profile` itself.
3. **Clients → + Create client** (older layout: Credentials → Create credentials → OAuth client ID), three times. The names are only labels:
   - **Web application**, name "Tunetrail server". No redirect URIs needed.
     Its client ID → `GOOGLE_SERVER_CLIENT_ID`.
   - **Android**: package name `com.tunetrail.tunetrail`, SHA-1 of your **release**
     signing key (step 3 below).
   - **Desktop app**: its client ID → `GOOGLE_DESKTOP_CLIENT_ID`, its client secret →
     `GOOGLE_DESKTOP_CLIENT_SECRET`. (Google treats desktop-app secrets as not
     confidential; it's still kept in a GitHub secret.)
   - Later, for iOS: an **iOS** client → `GOOGLE_IOS_CLIENT_ID`.

## 3. Android release key (10 min, once)

Google sign-in on Android only works when the APK is always signed with the same
key. CI currently signs with a throwaway debug key, so create a release key **on
your own computer** (it needs `keytool`, which comes with Java: install Temurin JDK
17 from adoptium.net, or use Android Studio's
`C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe`).

Windows (PowerShell):

```powershell
keytool -genkey -v -keystore tunetrail-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias tunetrail
keytool -list -v -keystore tunetrail-release.jks -alias tunetrail   # copy the SHA1 line into the Android OAuth client
[Convert]::ToBase64String([IO.File]::ReadAllBytes("tunetrail-release.jks")) | Out-File keystore.b64 -Encoding ascii
```

macOS / Linux: the same two `keytool` lines, then `base64 -i tunetrail-release.jks > keystore.b64`
(Linux: `base64 -w0 tunetrail-release.jks > keystore.b64`).

Newer Java versions only ask for one password (the keystore password); use it
for both password secrets in step 4.

Keep `tunetrail-release.jks` and its password somewhere safe — if you lose them
you can't update the app on Google Play. Never commit them. If you later publish
on Google Play with Play App Signing, also add Play's SHA-1 (Play Console → App
integrity) as a second Android OAuth client.

## 4. GitHub settings (5 min)

Repository → **Settings → Secrets and variables → Actions**.

**Variables** tab:

| Name | Value |
|---|---|
| `TUNETRAIL_SERVER` | `https://YOUR-SUBDOMAIN.duckdns.org` (step 5) |
| `GOOGLE_SERVER_CLIENT_ID` | from step 2 |
| `GOOGLE_DESKTOP_CLIENT_ID` | from step 2 |
| `GOOGLE_IOS_CLIENT_ID` | (later, for iOS) |

**Secrets** tab:

| Name | Value |
|---|---|
| `GOOGLE_DESKTOP_CLIENT_SECRET` | from step 2 |
| `TUNETRAIL_KEYSTORE_BASE64` | contents of `keystore.b64` |
| `TUNETRAIL_KEYSTORE_PASSWORD` | the keystore password |
| `TUNETRAIL_KEY_ALIAS` | `tunetrail` |
| `TUNETRAIL_KEY_PASSWORD` | the key password (same as the keystore password on newer Java) |

Every build after this has the server address and sign-in built in; new installs
connect to the online market automatically.

## 5. Server — Oracle Cloud Always Free + DuckDNS (30–45 min)

1. Sign up at <https://www.oracle.com/cloud/free/> (needs a card for identity;
   Always Free resources are never charged). Choose a home region near your
   players — Always Free VMs can only be created there.
   Tip: upgrading the account to **Pay As You Go** keeps it free for Always Free
   resources and stops Oracle reclaiming VMs that look idle.
2. **Compute → Instances → Create instance**:
   - Image: **Ubuntu 24.04**; Shape: **Ampere VM.Standard.A1.Flex**, 2 OCPU, 12 GB
     RAM (well inside the free 4 OCPU / 24 GB).
   - Add your SSH public key. Create, and note the **public IP**. ("Out of
     capacity" means try again later or another availability domain.)
3. Open the web ports: the instance's **subnet → Security list → Add ingress
   rules**: source `0.0.0.0/0`, TCP, destination ports `80` and `443`.
4. DuckDNS: sign in at <https://www.duckdns.org>, create a subdomain (e.g.
   `tunetrail`) and set it to the VM's public IP → `DOMAIN` =
   `tunetrail.duckdns.org`.
5. On the VM (`ssh ubuntu@PUBLIC-IP`):

```bash
# Ubuntu's own firewall also blocks 80/443 on Oracle images:
sudo iptables -I INPUT 6 -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT 6 -p tcp --dport 443 -j ACCEPT
sudo netfilter-persistent save

# Docker
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker ubuntu && newgrp docker

# Read-only access to the (private) repository: make a key for this VM,
# then add the printed line in GitHub → repo Settings → Deploy keys → Add deploy key
# (title "oracle-vm", leave "Allow write access" unticked).
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 && cat ~/.ssh/id_ed25519.pub

# The game server
git clone -b ccr-3946c635-1vgat4 git@github.com:splurp/tunetrail.git && cd tunetrail/deploy
cp .env.example .env && nano .env      # fill in DOMAIN, DATABASE_URL, SESSION_SECRET, GOOGLE_CLIENT_IDS
docker compose up -d --build
```

   `SESSION_SECRET`: run `openssl rand -base64 48` and paste the result.
   `DATABASE_URL`: if your database password has symbols like `@ # / ? :`, either
   change it in Supabase to letters and numbers only, or URL-encode them (`@` → `%40`).
   `GOOGLE_CLIENT_IDS`: `GOOGLE_SERVER_CLIENT_ID,GOOGLE_DESKTOP_CLIENT_ID`.

6. Check it: open `https://YOUR-SUBDOMAIN.duckdns.org/health` — you should see
   `{"ok":true,...}`.

**Updating the server** later (do this whenever the app gets new online
features — new app builds expect the matching server):
`cd ~/tunetrail && git pull && cd deploy && docker compose up -d --build`.
**Logs:** `docker compose logs -f server`.

## 6. Play

Push any commit (or re-run the workflow) so the apps are rebuilt with the new
settings, install the new build, then **Profile → Settings → Account → Sign in
with Google**.

## 7. Push notifications — Firebase (15 min, optional)

Android players get a notification for new messages, sales, new offers and
accepted offers, even when the game is closed.

1. <https://console.firebase.google.com> → **Add project** → pick your existing
   Google Cloud project `Tunetrail` (so it shares the OAuth setup). Analytics: off.
2. **Project settings (gear) → General → Your apps → Add app → Android**:
   package name `com.tunetrail.tunetrail`, nickname "Tunetrail". Skip the
   google-services.json download and the SDK steps (the game doesn't need them).
3. Still on **General**, note these values for GitHub **Variables** (step 4's
   Variables tab — they're not secret; they identify the app, not you):

   | Name | Where |
   |---|---|
   | `FIREBASE_API_KEY` | Google Cloud console → APIs & Services → **Credentials** → "Android key (auto created by Firebase)" → Show key (`AIza…`); or `current_key` in the app's google-services.json |
   | `FIREBASE_APP_ID` | Your apps → Android app → **App ID** (`1:…:android:…`) |
   | `FIREBASE_PROJECT_ID` | **Project ID** |
   | `FIREBASE_SENDER_ID` | **Cloud Messaging** tab → **Sender ID** (= project number) |

4. **Project settings → Service accounts → Generate new private key** → a
   `.json` file downloads. This one *is* secret. On your PC (PowerShell, in
   the download folder):
   ```powershell
   [Convert]::ToBase64String([IO.File]::ReadAllBytes("tunetrail-xxxx-firebase-adminsdk-xxxx.json")) | Set-Clipboard
   ```
   then on the VM: `cd ~/tunetrail/deploy && nano .env`, paste it after
   `FIREBASE_SERVICE_ACCOUNT_B64=`, save, and `docker compose up -d`.
   The server log line should end with `push: true`.
5. Rebuild the app (Actions → Run workflow). Players are asked to allow
   notifications the first time they sign in.

Windows and Linux don't get push notifications (the red badges in the game
show what's new instead).

---

## 8. Admin (debug) tools

Public builds contain no debug tools at all. To use them:

1. In the game, **Profile → Settings → Player ID** — copy it (`g_…`).
2. On the VM, add it to `.env`: `ADMINS=g_123…` (comma-separate several), then
   `docker compose up -d`.
3. Download the admin build: GitHub → **Actions** → the latest *Build
   Tunetrail* run → **Artifacts** → `admin-windows` (only people with access
   to the repository can see it; it's never attached to releases). Its debug
   menu unlocks only for accounts in `ADMINS`.

---

## What's online now, and what's next

Online now: Google accounts with signed sessions and unique usernames; the
shared market (listings, offers, folders, showcases); player search and public
profiles (profile theme, showcase, stats, the whole collection); direct offers
on any song in another player's collection; direct messages with blocking; the
shared Canvas/Sample/Live serial numbers; per-address rate limiting; state
saved in Postgres (collections in their own `tunetrail_collections` table).

Usernames and messages are plain text only: the game never renders them as
HTML, Markdown or links, the server only stores them inside JSON and sends
them to Postgres as query parameters, and the shared rules in
`packages/tunetrail_core/lib/src/text_safety.dart` strip invisible and
direction-flipping characters and reject look-alike names.

Still on the device (next phases, in this order):

1. Coins and bits held by the server (a ledger; purchases verified with the
   App Store / Play receipts).
2. Collections stored on the server.
3. Spawns generated by the server, with catch checks and cheat detection
   (impossible travel, Play Integrity / App Attest).

## When to upgrade

| Sign | Move to |
|---|---|
| Supabase database near 400 MB, or you want daily backups | Supabase Pro ($25/mo) |
| More than ~300 players online at once, or the VM above 60% CPU | Bigger Always Free shape (up to 4 OCPU / 24 GB, still free), then a paid VM |
| More than ~1,000 online at once | Split collections/ledger into proper tables, 2+ server instances behind a load balancer |
| Oracle signup or capacity problems | Any small VM: Hetzner CAX11 (~€5/mo) or Google Cloud e2-micro (Always Free, 1 GB egress/mo) — same compose file |
