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
2. **APIs & Services → OAuth consent screen**: External, app name "Tunetrail",
   your e-mail as support and developer contact. Scopes: just the defaults
   (`openid`, `profile`). Add yourself as a test user, or press **Publish app**
   when you're ready for everyone.
3. **APIs & Services → Credentials → Create credentials → OAuth client ID**, three times:
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
key. CI currently signs with a throwaway debug key, so create a release key:

```bash
keytool -genkey -v -keystore tunetrail-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias tunetrail
keytool -list -v -keystore tunetrail-release.jks -alias tunetrail   # copy the SHA1 line into the Android OAuth client
base64 -w0 tunetrail-release.jks > keystore.b64                     # macOS: base64 -i tunetrail-release.jks
```

Keep `tunetrail-release.jks` and its passwords somewhere safe — if you lose them
you can't update the app on Google Play. Never commit them.

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
| `TUNETRAIL_KEY_PASSWORD` | the key password |

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

# The game server
git clone https://github.com/splurp/tunetrail.git && cd tunetrail/deploy
cp .env.example .env && nano .env      # fill in DOMAIN, DATABASE_URL, SESSION_SECRET, GOOGLE_CLIENT_IDS
docker compose up -d --build
```

   `SESSION_SECRET`: run `openssl rand -base64 48` and paste the result.
   `GOOGLE_CLIENT_IDS`: `GOOGLE_SERVER_CLIENT_ID,GOOGLE_DESKTOP_CLIENT_ID`.

6. Check it: open `https://YOUR-SUBDOMAIN.duckdns.org/health` — you should see
   `{"ok":true,...}`.

**Updating the server** later: `cd ~/tunetrail && git pull && cd deploy && docker compose up -d --build`.
**Logs:** `docker compose logs -f server`.

## 6. Play

Push any commit (or re-run the workflow) so the apps are rebuilt with the new
settings, install the new build, then **Profile → Settings → Account → Sign in
with Google**.

---

## What's online now, and what's next

Online now: the shared market (listings, offers, folders, showcases), the
shared Canvas/Sample/Live serial numbers, and Google accounts with signed
sessions, per-address rate limiting, and state saved in Postgres.

Still on the device (next phases, in this order):

1. Coins and bits held by the server (a ledger; purchases verified with the
   App Store / Play receipts).
2. Collections stored on the server.
3. Spawns generated by the server, with catch checks and cheat detection
   (impossible travel, Play Integrity / App Attest).
4. Push notifications (Firebase Cloud Messaging — free).

## When to upgrade

| Sign | Move to |
|---|---|
| Supabase database near 400 MB, or you want daily backups | Supabase Pro ($25/mo) |
| More than ~300 players online at once, or the VM above 60% CPU | Bigger Always Free shape (up to 4 OCPU / 24 GB, still free), then a paid VM |
| More than ~1,000 online at once | Split collections/ledger into proper tables, 2+ server instances behind a load balancer |
| Oracle signup or capacity problems | Any small VM: Hetzner CAX11 (~€5/mo) or Google Cloud e2-micro (Always Free, 1 GB egress/mo) — same compose file |
