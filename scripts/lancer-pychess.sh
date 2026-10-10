#!/bin/bash
# lancer-pychess.sh - pose par le template AMP TeamKit (recree a chaque Update).
#
#   lancer-pychess.sh "port=<port>" "uri=<adresse publique>" "admins=<pseudos>" ...
#
# AMP passe chaque reglage sous la forme cle=valeur, entre guillemets : un reglage
# vide reste un argument « cle= » et ne decale jamais les autres.
#
# 1. demarre MongoDB, joignable SEULEMENT par une socket Unix dans /tmp du conteneur
#    (aucun port TCP : rien d'expose, meme si l'instance est en reseau hote) ;
# 2. demarre PyChess Variants (aiohttp) sur le port d'AMP ;
# 3. ecrit une ligne « pret » quand la page d'accueil repond vraiment ;
# 4. demarre fairyfishnet (adversaire IA Fairy-Stockfish), branche en local ;
# 5. a l'arret (SIGTERM d'AMP) : fairyfishnet, puis PyChess, puis MongoDB proprement.
cd "$(dirname "$0")" || exit 1
ICI="$PWD"
export LANG=C.UTF-8 LC_ALL=C.UTF-8
export HOME="$ICI/.maison"
# Sans cela, Python garde ses lignes en memoire tant que sa sortie n'est pas un
# terminal : la console d'AMP resterait muette (vu avec fairyfishnet, 10/10/2026).
export PYTHONUNBUFFERED=1
mkdir -p "$HOME"

declare -A V
for a in "$@"; do
  case "$a" in
    *=*) V["${a%%=*}"]="${a#*=}" ;;
    *) echo "ERREUR : argument inattendu : $a"; exit 1 ;;
  esac
done

refuser() {
  echo "ERREUR : $1"
  echo "Corrige ce reglage dans l'onglet Configuration d'AMP, puis relance."
  exit 1
}
entier() { [[ "$1" =~ ^[0-9]+$ ]]; }

PORT="${V[port]}"
URI="${V[uri]}"
ADMINS="${V[admins]}"
LICHESS_ID="${V[lichess]}"
DISCORD_ID="${V[discord_id]}"
DISCORD_SECRET="${V[discord_secret]}"
MOTEUR="${V[moteur]:-oui}"
COEURS="${V[coeurs]:-1}"
HASH="${V[hash]:-64}"
CACHE_MONGO="${V[cache_mongo]:-0.25}"

entier "$PORT" && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || refuser "port invalide : '$PORT'."
URI="${URI%/}"
[[ "$URI" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] \
  || refuser "adresse publique '$URI' : de la forme https://echecs.teamkit.fr (sans chemin ni / final)."
[[ "$ADMINS" =~ ^[A-Za-z0-9_,-]*$ ]] || refuser "administrateurs : pseudos separes par des virgules, sans espace."
[[ "$LICHESS_ID" =~ ^[A-Za-z0-9._-]*$ ]] || refuser "nom de l'application Lichess : lettres, chiffres, point, tiret."
[[ "$MOTEUR" =~ ^(oui|non)$ ]] || refuser "moteur IA : oui ou non."
entier "$COEURS" && [ "$COEURS" -ge 1 ] && [ "$COEURS" -le 8 ] || refuser "coeurs du moteur : de 1 a 8."
entier "$HASH" && [ "$HASH" -ge 16 ] && [ "$HASH" -le 512 ] || refuser "memoire du moteur : de 16 a 512 Mo."
[[ "$CACHE_MONGO" =~ ^[0-9]+(\.[0-9]+)?$ ]] || refuser "cache MongoDB : un nombre de Go (ex. 0.25)."
[[ "$DISCORD_ID" =~ ^[0-9]*$ ]] || refuser "identifiant Discord : des chiffres seulement."
[[ "$DISCORD_SECRET" =~ ^[A-Za-z0-9_-]*$ ]] || refuser "secret Discord : lettres, chiffres, _ et - seulement."
# Utilise seulement par verifier.py : controle des reglages sans rien demarrer.
if [ -n "$TK_ESSAI_REGLAGES" ]; then
  echo "TeamKit : reglages valides."
  exit 0
fi

SITE="$ICI/site"
MONGOD="$ICI/outils/mongodb/bin/mongod"
PY="$SITE/.venv/bin/python"
for f in "$MONGOD" "$PY" "$SITE/server/server.py" "$SITE/static/pychess-variants.js" donnees/secrets.env; do
  [ -e "$f" ] || { echo "ERREUR : $f absent. Lance Update (installation de PyChess, MongoDB, Python)."; exit 1; }
done
# shellcheck disable=SC1091
. donnees/secrets.env
[ -n "$FERNET_KEY" ] && [ -n "$FISHNET_KEY" ] && [ -n "$CLIENT_SECRET" ] || { echo "ERREUR : donnees/secrets.env incomplet : lance Update (il ajoute les cles manquantes)."; exit 1; }

# --- 1. MongoDB ---------------------------------------------------------------
# Socket hors du dossier de l'instance (une sauvegarde AMP n'a rien a y lire) et
# propre a l'instance (le port web est unique sur la machine).
RUN="${XDG_RUNTIME_DIR:-/tmp}/pychess-$PORT"
mkdir -p "$RUN" donnees/mongodb donnees/journaux
chmod 700 "$RUN"
SOCK="$RUN/mongodb-27017.sock"
rm -f "$SOCK"
echo "TeamKit : demarrage de MongoDB (cache ${CACHE_MONGO} Go, socket locale seulement)."
# GLIBC_TUNABLES : recommande par MongoDB 8 (rseq), comme le template officiel.
GLIBC_TUNABLES=glibc.pthread.rseq=0 setpriv --pdeathsig TERM -- "$MONGOD" \
  --dbpath "$ICI/donnees/mongodb" \
  --bind_ip "$SOCK" --port 27017 --unixSocketPrefix "$RUN" --filePermissions 0700 \
  --wiredTigerCacheSizeGB "$CACHE_MONGO" \
  --setParameter diagnosticDataCollectionEnabled=false \
  --logpath "$ICI/donnees/journaux/mongod.log" --logappend --logRotate reopen &
PID_MONGO=$!
for _ in $(seq 1 120); do
  [ -S "$SOCK" ] && break
  kill -0 "$PID_MONGO" 2>/dev/null || break
  sleep 0.5
done
if [ ! -S "$SOCK" ]; then
  echo "ERREUR : MongoDB n'a pas demarre. Fin de donnees/journaux/mongod.log :"
  # Decalees d'un espace : sinon la regex qui masque les lignes JSON de MongoDB les cacherait.
  tail -n 15 donnees/journaux/mongod.log 2>/dev/null | sed 's/^/  /'
  kill "$PID_MONGO" 2>/dev/null
  exit 1
fi
echo "TeamKit : MongoDB pret."

# --- 2. PyChess -----------------------------------------------------------------
export PORT URI PROD=true
export MONGO_HOST="mongodb://${SOCK//\//%2F}"
export FERNET_KEY ADMINS CLIENT_SECRET
export ALLOWED_ORIGINS="$URI"
export FISHNET_KEYS="{\"$FISHNET_KEY\":\"TeamKit\"}"
[ -n "$LICHESS_ID" ] && export LICHESS_CLIENT_ID="$LICHESS_ID"
if [ -n "$DISCORD_ID" ] && [ -n "$DISCORD_SECRET" ]; then
  export DISCORD_CLIENT_ID="$DISCORD_ID" DISCORD_CLIENT_SECRET="$DISCORD_SECRET"
fi
# perso.env : variables en plus (NOM=valeur), lues apres les reglages d'AMP.
if [ -f perso.env ]; then
  while IFS= read -r ligne || [ -n "$ligne" ]; do
    ligne="${ligne%$'\r'}"
    [[ "$ligne" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ "$ligne" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
      export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
    else
      echo "ATTENTION : ligne ignoree dans perso.env : $ligne"
    fi
  done < perso.env
fi

echo "TeamKit : demarrage de PyChess Variants $(cat donnees/version-installee 2>/dev/null) sur le port $PORT (adresse publique : $URI)."
cd "$SITE" || exit 1
setpriv --pdeathsig TERM -- "$PY" server/server.py &
PID_SITE=$!
cd "$ICI" || exit 1

PID_MOTEUR=""
ARRET=0
arreter() {
  trap - TERM INT
  ARRET=1
  echo "TeamKit : arret demande."
  [ -n "$PID_MOTEUR" ] && kill -TERM "$PID_MOTEUR" 2>/dev/null
  kill -TERM "$PID_SITE" 2>/dev/null
  for _ in $(seq 1 30); do kill -0 "$PID_SITE" 2>/dev/null || break; sleep 0.5; done
  kill -KILL "$PID_SITE" 2>/dev/null
  [ -n "$PID_MOTEUR" ] && kill -KILL "$PID_MOTEUR" 2>/dev/null
  echo "TeamKit : arret de MongoDB."
  kill -TERM "$PID_MONGO" 2>/dev/null
  for _ in $(seq 1 40); do kill -0 "$PID_MONGO" 2>/dev/null || break; sleep 0.5; done
  kill -0 "$PID_MONGO" 2>/dev/null && { echo "TeamKit : MongoDB ne s'arrete pas, arret force."; kill -KILL "$PID_MONGO"; }
}
trap arreter TERM INT

# --- 3. Ligne « pret » + 4. moteur ---------------------------------------------
PRET=0
for _ in $(seq 1 240); do
  kill -0 "$PID_SITE" 2>/dev/null || break
  if curl -fs -o /dev/null --max-time 5 "http://127.0.0.1:$PORT/"; then PRET=1; break; fi
  sleep 0.5
done
if [ "$PRET" = 1 ]; then
  echo "TeamKit : PyChess pret, le site repond sur le port $PORT."
  if [ "$MOTEUR" = "oui" ]; then
    if [ -x moteur/venv/bin/fairyfishnet ]; then
      # Les reseaux NNUE (~3 Go, un par variante) sont telecharges dans le dossier
      # courant : le moteur doit tourner dans le MEME dossier (essai du 10/10/2026).
      ( cd moteur && exec setpriv --pdeathsig TERM -- venv/bin/fairyfishnet --no-conf \
          --key "$FISHNET_KEY" --endpoint "http://127.0.0.1:$PORT/fishnet/" \
          --engine-dir "$ICI/moteur" --cores "$COEURS" --threads-per-process "$COEURS" \
          --memory "$HASH" run ) &
      PID_MOTEUR=$!
    else
      echo "ATTENTION : moteur IA active mais fairyfishnet absent : lance Update."
    fi
  fi
elif kill -0 "$PID_SITE" 2>/dev/null; then
  echo "TeamKit : ATTENTION, le site ne repond toujours pas apres 2 minutes."
fi

# Le SIGTERM d'AMP interrompt « wait » : on attend ensuite la fin reelle.
wait "$PID_SITE"
CODE=$?
if [ "$ARRET" = 1 ]; then
  wait "$PID_SITE" 2>/dev/null
  wait "$PID_MONGO" 2>/dev/null
  CODE=0
else
  echo "TeamKit : PyChess s'est arrete (code $CODE)."
  [ -n "$PID_MOTEUR" ] && kill -TERM "$PID_MOTEUR" 2>/dev/null
  kill -TERM "$PID_MONGO" 2>/dev/null
  wait "$PID_MONGO" 2>/dev/null
fi
rm -rf "$RUN"
exit "$CODE"
