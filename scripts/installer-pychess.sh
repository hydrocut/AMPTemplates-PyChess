#!/bin/bash
# installer-pychess.sh - pose par le template AMP TeamKit (recree a chaque Update).
#
#   installer-pychess.sh "version=<tag|master|vide>" "moteur=oui|non"
#
# Installe ou met a jour, DANS le dossier de l'instance (le HOME du conteneur est
# perdu a chaque recreation du conteneur) :
#   outils/uv        uv (gestionnaire Python d'Astral), binaire statique
#   outils/python    Python 3.14 telecharge par uv (Debian 13 n'a que 3.13)
#   outils/node      Node.js 24 (pour construire l'interface, pas pour la faire tourner)
#   outils/mongodb   MongoDB Community 8.0 (archive officielle Debian 12, tourne sur Debian 13)
#   site/            PyChess Variants (code AGPL non modifie) + .venv + interface construite
#   moteur/          fairyfishnet + Fairy-Stockfish (adversaire IA), si moteur=oui
#   donnees/         base MongoDB, cles secretes : JAMAIS ecrase par une mise a jour
set -o pipefail
cd "$(dirname "$0")" || exit 1
ICI="$PWD"
export LANG=C.UTF-8 LC_ALL=C.UTF-8
export HOME="$ICI/.maison"
export UV_CACHE_DIR="$ICI/.cache/uv"
export UV_PYTHON_INSTALL_DIR="$ICI/outils/python"
export UV_PYTHON_PREFERENCE=only-managed
export UV_NO_PROGRESS=1
export npm_config_cache="$ICI/.cache/npm"
export YARN_CACHE_FOLDER="$ICI/.cache/yarn"
mkdir -p "$HOME" outils donnees .cache

DEPOT=https://github.com/pychess/pychess-variants
MONGO_SERIE=8.0
NODE_SERIE=24
PYTHON_VERSION=3.14

declare -A V
for a in "$@"; do
  case "$a" in
    *=*) V["${a%%=*}"]="${a#*=}" ;;
    *) echo "ERREUR : argument inattendu : $a"; exit 1 ;;
  esac
done
VOULUE="${V[version]}"
MOTEUR="${V[moteur]:-oui}"

echec() { echo "ERREUR : $1"; exit 1; }
etape() { echo "TeamKit : $1"; }
telecharger() { # url fichier
  curl -fsSL --retry 3 --connect-timeout 20 -o "$2" "$1"
}

# --- 1. uv ------------------------------------------------------------------
etape "uv (gestionnaire Python)..."
# Extraction a cote puis renommage : ecraser un binaire en cours d'execution
# echoue (« Text file busy », vu le 10/10/2026).
rm -rf .cache/uv.tar.gz outils/uv.new && mkdir -p outils/uv.new
if telecharger https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-gnu.tar.gz .cache/uv.tar.gz    && tar -xzf .cache/uv.tar.gz -C outils/uv.new --strip-components=1 && [ -x outils/uv.new/uv ]; then
  rm -rf outils/uv.old; [ -d outils/uv ] && mv outils/uv outils/uv.old
  mv outils/uv.new outils/uv && rm -rf outils/uv.old
elif [ -x outils/uv/uv ]; then
  echo "ATTENTION : uv pas telecharge (github.com), on garde l'ancien."
else
  echec "telechargement de uv impossible (github.com)."
fi
rm -rf .cache/uv.tar.gz outils/uv.new
UV="$ICI/outils/uv/uv"
"$UV" --version || echec "uv ne demarre pas."

etape "Python $PYTHON_VERSION (gere par uv)..."
"$UV" python install "$PYTHON_VERSION" || echec "installation de Python $PYTHON_VERSION impossible."

# --- 2. Node.js 24 (construction de l'interface) ------------------------------
etape "Node.js $NODE_SERIE..."
NODE_V=$(curl -fsSL --retry 3 https://nodejs.org/dist/index.json | jq -r "[.[] | select(.version | startswith(\"v$NODE_SERIE.\"))][0].version")
if [[ ! "$NODE_V" =~ ^v$NODE_SERIE\.[0-9]+\.[0-9]+$ ]]; then
  [ -x outils/node/bin/node ] || echec "version de Node.js $NODE_SERIE introuvable sur nodejs.org."
  NODE_V=$(outils/node/bin/node --version)
  echo "ATTENTION : nodejs.org injoignable, on garde Node $NODE_V."
fi
if [ "$(outils/node/bin/node --version 2>/dev/null)" != "$NODE_V" ]; then
  F="node-$NODE_V-linux-x64.tar.xz"
  telecharger "https://nodejs.org/dist/$NODE_V/$F" ".cache/$F" || echec "telechargement de $F impossible."
  ATTENDU=$(curl -fsSL "https://nodejs.org/dist/$NODE_V/SHASUMS256.txt" | awk -v f="$F" '$2 == f { print $1 }')
  [ -n "$ATTENDU" ] && [ "$(sha256sum ".cache/$F" | cut -d' ' -f1)" = "$ATTENDU" ] || echec "empreinte SHA-256 de $F incorrecte."
  rm -rf outils/node.new && mkdir -p outils/node.new
  tar -xJf ".cache/$F" -C outils/node.new --strip-components=1 || echec "archive $F illisible."
  rm -f ".cache/$F"
  rm -rf outils/node && mv outils/node.new outils/node
fi
export PATH="$ICI/outils/node/bin:$PATH"
echo "Node.js $(node --version)"

# --- 3. MongoDB 8.0 -----------------------------------------------------------
etape "MongoDB $MONGO_SERIE..."
MONGO_V=$(curl -fsSL --retry 3 "https://endoflife.date/api/v1/products/mongodb/releases/$MONGO_SERIE" | jq -r '.result.latest.name')
ACTUELLE=$(outils/mongodb/bin/mongod --version 2>/dev/null | sed -n 's/^db version v\([0-9.]*\)$/\1/p')
if [[ ! "$MONGO_V" =~ ^${MONGO_SERIE//./\\.}\.[0-9]+$ ]]; then
  [ -n "$ACTUELLE" ] || echec "version de MongoDB $MONGO_SERIE introuvable (endoflife.date)."
  MONGO_V="$ACTUELLE"
  echo "ATTENTION : endoflife.date injoignable, on garde MongoDB $MONGO_V."
fi
if [ "$ACTUELLE" != "$MONGO_V" ]; then
  F="mongodb-linux-x86_64-debian12-$MONGO_V.tgz"
  telecharger "https://fastdl.mongodb.org/linux/$F" ".cache/$F" || echec "telechargement de $F impossible (fastdl.mongodb.org)."
  ATTENDU=$(curl -fsSL "https://fastdl.mongodb.org/linux/$F.sha256" | awk '{ print $1 }')
  [ -n "$ATTENDU" ] && [ "$(sha256sum ".cache/$F" | cut -d' ' -f1)" = "$ATTENDU" ] || echec "empreinte SHA-256 de $F incorrecte."
  rm -rf outils/mongodb.new && mkdir -p outils/mongodb.new
  tar -xzf ".cache/$F" -C outils/mongodb.new --strip-components=1 || echec "archive $F illisible."
  rm -f ".cache/$F"
  rm -rf outils/mongodb && mv outils/mongodb.new outils/mongodb
fi
manque=$(ldd outils/mongodb/bin/mongod | grep "not found")
[ -z "$manque" ] || echec "bibliotheques manquantes pour mongod : $manque"
outils/mongodb/bin/mongod --version | head -n 1

# --- 4. PyChess Variants --------------------------------------------------------
etape "PyChess Variants..."
if [ -z "$VOULUE" ]; then
  VOULUE=$(git ls-remote --tags --refs "$DEPOT.git" 2>/dev/null | sed 's#.*refs/tags/##' | grep -E '^[0-9]+(\.[0-9]+)+$' | sort -V | tail -n 1)
  [ -n "$VOULUE" ] || VOULUE=$(cat donnees/version-installee 2>/dev/null)
  [ -n "$VOULUE" ] || echec "derniere version de PyChess introuvable (github.com)."
fi
[[ "$VOULUE" =~ ^[A-Za-z0-9._-]{1,60}$ ]] || echec "version '$VOULUE' : un tag (ex. 1.11.72) ou master."
INSTALLEE=$(cat donnees/version-installee 2>/dev/null)
if [ "$INSTALLEE" = "$VOULUE" ] && [ "$VOULUE" != "master" ] && [ -f site/static/pychess-variants.js ] && [ -x site/.venv/bin/python ]; then
  echo "PyChess $VOULUE deja installe et construit."
else
  if [[ "$VOULUE" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then REF="refs/tags/$VOULUE"; else REF="refs/heads/$VOULUE"; fi
  rm -rf site.new .cache/pychess.tar.gz && mkdir -p site.new
  telecharger "https://codeload.github.com/pychess/pychess-variants/tar.gz/$REF" .cache/pychess.tar.gz \
    || echec "version '$VOULUE' introuvable sur $DEPOT (tags : $DEPOT/tags)."
  tar -xzf .cache/pychess.tar.gz -C site.new --strip-components=1 && rm -f .cache/pychess.tar.gz
  (
    cd site.new || exit 1
    etape "construction de l'interface (yarn install, quelques minutes)..."
    npx --yes yarn@1.22.22 install --frozen-lockfile --non-interactive --network-timeout 600000 || exit 1
    etape "construction de l'interface (yarn prod)..."
    npx --yes yarn@1.22.22 prod || exit 1
    etape "pages d'aide (yarn md)..."
    npx --yes yarn@1.22.22 md || exit 1
    etape "dependances Python (uv sync)..."
    "$UV" sync --frozen --no-dev --python "$PYTHON_VERSION" || exit 1
    # node_modules ne sert qu'a la construction : ~1 Go de moins dans les sauvegardes.
    rm -rf node_modules
  ) || { rm -rf site.new; echec "construction de PyChess $VOULUE ratee (voir ci-dessus). L'ancienne version est gardee."; }
  [ -f site.new/static/pychess-variants.js ] || { rm -rf site.new; echec "l'interface n'a pas ete produite (static/pychess-variants.js absent)."; }
  rm -rf site.old
  [ -d site ] && mv site site.old
  mv site.new site && rm -rf site.old
  echo "$VOULUE" > donnees/version-installee
  echo "PyChess Variants $VOULUE installe."
fi

# --- 5. Moteur (fairyfishnet + Fairy-Stockfish) -------------------------------------
if [ "$MOTEUR" = "oui" ]; then
  etape "fairyfishnet (adversaire IA Fairy-Stockfish)..."
  mkdir -p moteur
  [ -x moteur/venv/bin/python ] || "$UV" venv --quiet --python "$PYTHON_VERSION" moteur/venv || echec "environnement Python du moteur impossible."
  VIRTUAL_ENV="$ICI/moteur/venv" "$UV" pip install --quiet --upgrade fairyfishnet || echec "installation de fairyfishnet impossible (pypi.org)."
  moteur/venv/bin/fairyfishnet --version
else
  echo "Moteur IA desactive (reglage) : seul Random-Mover jouera contre les joueurs."
fi

# --- 6. Cles secretes, creees une seule fois (une cle absente est ajoutee) -----------
# FERNET_KEY    chiffre les cookies de session : la changer deconnecte tout le monde ;
# FISHNET_KEY   cle du moteur IA local aupres du site (jamais envoyee ailleurs) ;
# CLIENT_SECRET valeur « state » de la connexion Lichess dans PyChess 1.11.x (sinon
#               le mot fixe « secret ») ; envoyee a Lichess, qui l'ignore (client public).
umask 077
if [ ! -f donnees/secrets.env ]; then
  echo "# Cles generees par le template. Ne pas partager, ne pas publier." > donnees/secrets.env
fi
ajouter_cle() { # nom commande-python
  grep -q "^$1=." donnees/secrets.env && return
  echo "$1=$(python3 -c "$2")" >> donnees/secrets.env
  echo "Cle $1 creee (donnees/secrets.env)."
}
ajouter_cle FERNET_KEY 'import base64, os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())'
ajouter_cle FISHNET_KEY 'import secrets; print(secrets.token_hex(16))'
ajouter_cle CLIENT_SECRET 'import secrets; print(secrets.token_urlsafe(32))'
umask 022

if [ ! -f perso.env ]; then
  printf '%s\n' \
    "# perso.env - variables d'environnement en plus pour PyChess, une par ligne : NOM=valeur" \
    "# Lu a chaque demarrage APRES les reglages d'AMP. Le template ne l'ecrase jamais." \
    "# Exemples (voir server/settings.py et server/oauth_config.py de PyChess) :" \
    "# GOOGLE_CLIENT_ID=..." \
    "# GOOGLE_CLIENT_SECRET=..." \
    "# TOURNAMENT_DIRECTORS=Pseudo1,Pseudo2" > perso.env
fi

# Caches de telechargement (~200 Mo) : inutiles une fois installe, et hors des sauvegardes.
rm -rf .cache
etape "installation terminee (PyChess $(cat donnees/version-installee), MongoDB $MONGO_V, Node $NODE_V)."
