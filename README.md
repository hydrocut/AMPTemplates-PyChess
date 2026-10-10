# AMPTemplates-PyChess — PyChess Variants (chess variants website) for AMP

**AMP Generic Module** template that runs **PyChess Variants**, the free software behind
<https://www.pychess.org> (source <https://github.com/pychess/pychess-variants>, AGPL-3.0), as a
self-hosted chess and chess-variants website: chess, xiangqi, shogi, janggi, makruk, crazyhouse,
bughouse, Fairy-Stockfish AI opponent, tournaments, analysis board. Written for TeamKit, a free
French game host, on 10 Oct 2026. CubeCoders ships no PyChess template (checked against
`CubeCoders/AMPTemplates`, commit `cde98b5`, 5 Oct 2026); there is an official **MongoDB** template
(by Greelan), which this template deliberately does **not** use (see below).

> Résumé en français à la fin du fichier.

## What runs inside the instance

Everything lives in **one AMP instance** (container mode, `cubecoders/ampbase:debian` = Debian 13),
in the instance folder, because the container's `HOME` is lost each time AMP recreates the container:

| Part | Where | Source | Why |
|---|---|---|---|
| uv | `outils/uv` | astral-sh/uv GitHub release | PyChess targets **Python 3.14+**; Debian 13 ships 3.13 |
| Python 3.14 | `outils/python` | `uv python install 3.14` (python-build-standalone) | |
| Node.js 24 | `outils/node` | nodejs.org, SHA-256 checked | **build only** (esbuild bundle + docs); not running afterwards |
| MongoDB 8.0 | `outils/mongodb` | `fastdl.mongodb.org` *debian12* tarball, SHA-256 checked | MongoDB publishes no *debian13* tarball (403); the Debian 12 build runs on Debian 13 (`ldd`: nothing missing, tested) |
| PyChess Variants | `site/` | GitHub tag tarball (default: latest tag, e.g. `1.11.72`) | **unmodified** upstream code; `uv sync --frozen --no-dev`, `yarn install --frozen-lockfile`, `yarn prod`, `yarn md` |
| fairyfishnet + Fairy-Stockfish | `moteur/` | PyPI `fairyfishnet`; it downloads the engine and the NNUE networks itself | AI opponent ("Play with the computer") |
| data | `donnees/` | | MongoDB files, generated secrets, installed version — never touched by Update |

All pinned dependencies come from upstream's lock files (`uv.lock`, `yarn.lock`).

### One instance or two? Why MongoDB is inside

PyChess needs MongoDB (`MONGO_HOST`). Two options were studied:

- **Separate instance with the official MongoDB template**: runs `mongod --bind_ip 0.0.0.0 --auth`
  with a root `admin` user. PyChess would then reach it through the Docker bridge, which means a
  MongoDB port published on the host (and an Internet-facing port unless firewalled), a root password
  to carry over, two instances to start in the right order and to back up together.
- **Inside the PyChess instance** (chosen): `mongod` listens on a **Unix socket only**
  (`--bind_ip <socket path>`, no TCP port at all — checked: the only listening TCP port in the
  container is the web port). The socket lives in `$XDG_RUNTIME_DIR` (inside the container), so it is
  private even if an instance runs in Docker *host* network mode. No password needed, nothing exposed.
  The WiredTiger cache is capped (default 0.25 GB; MongoDB would otherwise take half of the host's RAM).

The CPU must support AVX for MongoDB 5.0+ (any recent x86_64 server does; the TeamKit host is a Ryzen 9 9900X).

## How players sign in

No key to request from anyone:

- **Guests**: anyone can play straight away as `Anon–xxxxxxxx`: casual real-time games against other
  players, against the AI, analysis board. Guests cannot play rated, correspondence or
  two-board (bughouse) games, nor join tournaments or post in the forum (upstream rules).
- **Lichess login**: Lichess supports *"unregistered and public clients (no client authentication,
  choose any unique client id)"* with PKCE (Lichess API docs, *Authentication*). PyChess only needs a
  client id (setting *Nom de l'application sur Lichess*, default `echecs.teamkit.fr`) and its public
  address (`URI`) for the redirect `URI/oauth/lichess`. Checked: `/login/lichess` → `/oauth/lichess` →
  `https://lichess.org/oauth?client_id=echecs.teamkit.fr&redirect_uri=https://echecs.teamkit.fr/oauth/lichess&code_challenge_method=S256…`.
  Lichess accepts `http` and `https` redirect URIs (`lila`, `modules/oauth/.../Protocol.scala`).
  The first login asks the player to choose a PyChess username; that name is what goes into *Administrateurs*.
- **Discord login** (optional): needs a Discord application's Client ID and Secret, with the redirect
  `URI/oauth/discord` added in the Discord Developer Portal.
- Google / Lishogi buttons are shown by upstream too; Google needs its own keys (put them in `perso.env`).

## Domain name and HTTPS: needed

PyChess is a website, so the public address matters:

- `URI` is used for the OAuth redirects, the `Secure` flag of the session cookie and the CSRF /
  WebSocket same-origin checks (the `Origin` must equal `X-Forwarded-Proto://Host`).
- The in-browser analysis engine (Fairy-Stockfish WebAssembly with threads) needs `SharedArrayBuffer`,
  which browsers only give to **cross-origin-isolated pages in a secure context**: PyChess sends the
  COOP/COEP headers, but over plain `http://IP:port` the analysis board engine will not start.

So: a subdomain (e.g. `echecs.teamkit.fr`) with a Let's Encrypt certificate on the host's nginx,
proxying to the instance port. Tested end to end with this block (self-signed certificate in the test):

```nginx
map $http_upgrade $connection_upgrade { default upgrade; '' close; }   # once per nginx (http block)

server {
    server_name echecs.teamkit.fr;
    client_max_body_size 10m;
    location / {
        proxy_pass http://127.0.0.1:9180;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;          # WebSockets: lobby /wsl, games /wsr/<id>
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;      # PyChess redirects to https when it sees "http"
        proxy_set_header X-Forwarded-For $remote_addr;   # OVERWRITE, do not append (see below)
        proxy_read_timeout 3600s;
        proxy_buffering off;
    }
    listen 80;   # then: certbot --nginx -d echecs.teamkit.fr
}
```

**`X-Forwarded-For $remote_addr`, not `$proxy_add_x_forwarded_for`**: PyChess takes the *first*
address of that header as the client IP for its rate limits and ban-evasion checks
(`request_protection.py`, `security_evasion.py`). Appending would let any visitor pick their own IP
by sending the header themselves (verified in the test: spoofed addresses were accepted).

Keep port 9180 **closed to the public** in the firewall: players go through nginx. Opened directly,
the site half-works (no HTTPS → no secure cookie, no analysis engine).

## Settings exposed in AMP (French UI)

| AMP setting | Effect | Default |
|---|---|---|
| Adresse publique du site | `URI`, `ALLOWED_ORIGINS` | `https://echecs.teamkit.fr` |
| Administrateurs | `ADMINS` (comma list of PyChess usernames) | empty |
| Nom de l'application sur Lichess | `LICHESS_CLIENT_ID` | `echecs.teamkit.fr` |
| Discord : identifiant / secret | `DISCORD_CLIENT_ID` / `DISCORD_CLIENT_SECRET` | empty |
| Adversaire IA Fairy-Stockfish | fairyfishnet on/off (off = Random-Mover only) | oui |
| Cœurs du moteur / Mémoire de calcul | fairyfishnet `--cores` / `--memory` (UCI Hash) | 1 / 64 MB |
| Cache de la base MongoDB | `--wiredTigerCacheSizeGB` | 0.25 |
| Version de PyChess Variants (Updates) | tag, `master`, or empty = latest tag | empty |

Fixed by the start script: `PROD=true` (no development-only variants), `PORT`, `MONGO_HOST` (socket),
`FISHNET_KEYS` (one local key). Secrets are generated once by the installer into
`donnees/secrets.env` (mode 600, never overwritten, missing keys added): `FERNET_KEY` (session
cookies), `FISHNET_KEY` (local AI worker), `CLIENT_SECRET` (in PyChess 1.11.x it is also the OAuth
`state` value, which is otherwise the constant `secret`). Any other upstream variable
(`GOOGLE_CLIENT_ID`, `TOURNAMENT_DIRECTORS`, `TWITCH_CLIENT_ID`…, see `server/settings.py`) goes into
**`perso.env`** (`NAME=value` per line, read last, created once, never overwritten).

All values are validated by the start script before anything starts (no quotes, no spaces where they
would break the command line, URI without path), with a French error message.

## Start, ready line, stop

`/bin/bash lancer-pychess.sh "port=…" "uri=…" …` (each setting as one quoted `key=value` argument):

1. `mongod` on the socket, under `setpriv --pdeathsig TERM`; waits for the socket;
2. `python server/server.py` (aiohttp, port from AMP);
3. prints `TeamKit : PyChess pret, le site repond sur le port <port>.` once `GET /` answers
   (upstream prints `Running on http://0.0.0.0:<port>` *before* the app has finished loading);
4. starts fairyfishnet with `--endpoint http://127.0.0.1:<port>/fishnet/` — it never talks to pychess.org.
   It runs **in the folder where it downloads the NNUE networks** (it saves them in its current
   directory, and the engine must find them in its own working directory: tested, otherwise every AI
   move fails with *network file … was not loaded successfully* and a 15 s timeout);
5. on SIGTERM: AI worker, then PyChess (graceful), then MongoDB (clean shutdown). Measured: 1–4 s.

`PYTHONUNBUFFERED=1` is required: without it, Python's output is block-buffered when it is not a
terminal and the AMP console stays silent. PyChess logs at DEBUG level even with `PROD=true` (its
logging config lives in MongoDB); `Console.ThrowawayMessageRegex` drops the DEBUG lines and MongoDB's
JSON start-up line, INFO/WARN/ERROR lines stay. There is no player list in AMP (`MaxUsers=0`): it is a
website, players are not "connected to a server" in AMP's sense.

## Update

`installer-pychess.sh` (Update stage) downloads uv, Python 3.14, Node 24 and MongoDB 8.0 (skipped when
already current), then PyChess: if the requested version is not the installed one, it builds it in
`site.new/` and swaps it in **only if the build succeeded** (otherwise the old site keeps running).
`node_modules` (~1 GB) and download caches are deleted afterwards. Measured: **~40 s** for a fresh
install, ~2 s when nothing changed, ~25 s for a version change, on the TeamKit host.

## Resources (measured, 10 Oct 2026)

| | |
|---|---|
| RAM, idle | PyChess 350 MB, MongoDB 195 MB, fairyfishnet 130 MB, Fairy-Stockfish 440 MB (NNUE loaded) → **~1.1 GB**; without the AI ~550 MB |
| RAM, 40 guests + 15 games | unchanged within a few MB (PyChess 351 MB, MongoDB 210 MB) |
| Memory limit to set in AMP | **2 GB** with the AI, 1 GB without |
| Disk | tools 740 MB, site 360 MB, **AI networks 3.2 GB** (one NNUE per variant), database grows with games |
| First start | site ready in ~6 s (fresh database: 46 collections, 118 indexes); AI ready ~1.5 min later the first time (NNUE download) |
| CPU | idle near 0; the AI uses the configured cores only while thinking |

## Backups

AMP backs up the instance folder. Two cautions:
- `moteur/` (3.2 GB of NNUE networks) and `outils/` are re-downloadable: exclude them if your backup
  settings allow it. `SmartExcludeExemptions` keeps the MongoDB files and the secrets.
- A copy of MongoDB files taken **while it runs** may not be consistent: prefer backups with the
  instance stopped (stop takes a few seconds).

## Licence (AGPL-3.0)

PyChess Variants is AGPL-3.0. Section 13 requires offering the source to network users **of a modified
version**. This template runs the **unmodified** upstream tag, configured only through environment
variables, and the site itself links to its source (About page and lobby → github.com/pychess/pychess-variants).
fairyfishnet is GPL-3.0+, Fairy-Stockfish GPL-3.0, MongoDB Community SSPL (used unmodified, not offered
as a database service). This repository only contains the template scripts, published publicly.
If you ever patch PyChess (texts, logo…), publish the patched source (a public fork) and link it from the site.

## Before pushing

```
python verifier.py
```

Must print `Tout est bon.`: JSON, includes, ports (outside AMP's 8080–8180 panel range), complete
`Console.*` / `Limits.*` block, every AMP setting passed as `"key={{key}}"` to the right script and read
by it, download URLs, LF endings, `bash -n`, the lessons from testing, 24 setting values against the start
script's validation, and the console regexes on real PyChess / MongoDB lines.

## Install in AMP

1. Public repository `hydrocut/AMPTemplates-PyChess` (Update downloads `scripts/` from it).
2. ADS → Configuration → Instance Deployment → **Configuration Repositories**: add
   `hydrocut/AMPTemplates-PyChess:main`, save, **Fetch latest**.
3. Create Instance → **PyChess Variants (TeamKit)** (container), memory limit 2 GB.
4. Configuration: check *Adresse publique du site*. **Update** (~1 min) → **Start**: the console shows
   `TeamKit : PyChess pret, le site repond sur le port 9180.`
5. nginx block above + `certbot --nginx -d echecs.teamkit.fr` + DNS `A echecs → host IP`.
6. Open the site, *Se connecter avec Lichess*, choose a username, put it in *Administrateurs*, restart.

## Credits

PyChess Variants by Bajusz Tamás (gbtami) and contributors (AGPL-3.0). Fairy-Stockfish by Fabian
Fichter and contributors. fairyfishnet by gbtami. This repository only contains the template.

---

## Résumé en français

Template AMP qui héberge **PyChess Variants**, le logiciel libre de pychess.org : un **site** d'échecs
et de variantes (échecs, xiangqi, shogi, janggi, crazyhouse, bughouse…), avec l'IA Fairy-Stockfish.
**Tout tient dans une seule instance** (conteneur obligatoire) : Python 3.14 (via uv), MongoDB 8.0
(socket locale, **aucun port**), le moteur IA. Le code de PyChess n'est pas modifié.

- **Connexion des joueurs** : en **invité** sans rien (parties amicales, contre l'IA, analyse) ; avec
  **Lichess** sans aucune clé à demander (Lichess accepte les applications non enregistrées) ; Discord en option.
- **Nom de domaine + HTTPS nécessaires** : sous-domaine `echecs.teamkit.fr` derrière nginx (bloc ci-dessus,
  WebSockets compris, `X-Forwarded-For $remote_addr`). Sans HTTPS, l'analyse dans le navigateur ne marche pas.
- **Ressources mesurées** : ~1,1 Go de RAM avec l'IA (limite AMP conseillée : 2 Go), ~4,5 Go de disque
  (dont 3,2 Go de réseaux NNUE pour l'IA).
- **Testé en vrai** le 10 oct. 2026 dans un conteneur jetable : installation (~40 s), démarrage, partie
  entre deux invités, coups de l'IA en échecs et en xiangqi, passage derrière nginx en HTTPS, redirection
  Lichess, 40 invités, arrêt propre, reprise de la base, changement de version.
- Avant de pousser : `python verifier.py` doit répondre « Tout est bon. ».
