# -*- coding: utf-8 -*-
"""
Controle du template avant de le pousser (meme role que ceux de Wesnoth, Dominions 6...).

    python verifier.py

1. tous les JSON se parsent ;
2. le .kvp ne reference que des fichiers presents, le port principal existe, le bloc
   Console.* / Limits.* est complet, la ligne « pret » est attendue ;
3. chaque reglage d'AMP arrive au bon script, sous la forme "cle={{cle}}" entre guillemets
   (une valeur vide ne decale rien), et chaque cle passee est lue par le script ;
4. les fichiers telecharges a l'Update existent dans scripts/, a l'URL du depot du manifest ;
5. les scripts : fins de ligne LF, aucun {{ (AMP pourrait le remplacer), bash -n,
   et les points appris en testant (socket MongoDB sans port TCP, sortie Python non
   tamponnee, moteur lance dans le dossier des NNUE, cles secretes jamais ecrasees...) ;
6. le lanceur accepte les valeurs par defaut et refuse les valeurs dangereuses
   (guillemet, espace, chemin dans l'adresse...) - s'il y a un bash sous la main ;
7. les regex de console reconnaissent les vraies lignes (relevees le 10 oct. 2026 dans un
   conteneur jetable cubecoders/ampbase:debian, PyChess 1.11.72) et pas les autres.
"""
import io
import json
import os
import re
import shutil
import subprocess
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
NOM = 'pychess'
LANCEUR = 'scripts/lancer-pychess.sh'
INSTALLEUR = 'scripts/installer-pychess.sh'
soucis = []


def lire(nom, binaire=False):
    chemin = os.path.join(ICI, nom)
    if binaire:
        with open(chemin, 'rb') as f:
            return f.read()
    with io.open(chemin, encoding='utf-8') as f:
        return f.read()


def py(motif):
    # AMP est en C# : (?<nom>...) ; Python veut (?P<nom>...)
    return re.compile(motif.replace('(?<', '(?P<'))


# -- 1. JSON ------------------------------------------------------------------
data = {}
for nom in ('manifest.json', NOM + 'config.json', NOM + 'metaconfig.json', NOM + 'ports.json', NOM + 'updates.json'):
    try:
        data[nom] = json.loads(lire(nom))
        print('ok   %-24s JSON valide' % nom)
    except Exception as e:
        soucis.append('%s : JSON invalide (%s)' % (nom, e))
if soucis:
    print('\n'.join('NON  ' + s for s in soucis))
    sys.exit(1)
config = data[NOM + 'config.json']
updates = data[NOM + 'updates.json']
ports = data[NOM + 'ports.json']

# -- 2. kvp -------------------------------------------------------------------
kvp = lire(NOM + '.kvp')
cles = dict(l.split('=', 1) for l in kvp.splitlines() if '=' in l)
for ref in re.findall(r'@IncludeJson\[([^\]]+)\]', kvp):
    if not os.path.isfile(os.path.join(ICI, ref)):
        soucis.append('@IncludeJson[%s] : fichier absent' % ref)
for cle in ('Meta.ConfigManifest', 'Meta.MetaConfigManifest'):
    if not os.path.isfile(os.path.join(ICI, cles.get(cle, '?'))):
        soucis.append('%s pointe sur un fichier absent' % cle)
refs = {p['Ref'] for p in ports}
if cles.get('App.PrimaryApplicationPortRef') not in refs:
    soucis.append('PrimaryApplicationPortRef ne correspond a aucun port')
print('ok   ports                    %s' % ', '.join('%s %s/%s' % (p['Ref'], p['Port'], p['Protocol']) for p in ports))
if any(8080 <= p['Port'] <= 8180 for p in ports):
    soucis.append('port dans la plage 8080-8180 des panneaux AMP du dedie')
ATTENDUES = ['App.SupportsUniversalSleep', 'App.WakeupMode', 'App.ApplicationReadyMode', 'Console.FilterMatchRegex', 'Console.FilterMatchReplacement', 'Console.ThrowawayMessageRegex', 'Console.AppReadyRegex', 'Console.UserJoinRegex', 'Console.UserLeaveRegex', 'Console.UserChatRegex', 'Console.UpdateAvailableRegex', 'Console.PreConnectRegex', 'Console.ConnectIPRegex', 'Console.MetricsRegex', 'Console.HideFromConsoleRegex', 'Console.SuppressLogAtStart', 'Console.UserActions', 'Limits.SleepMode', 'Limits.SleepOnStart', 'Limits.SleepDelayMinutes', 'Limits.DozeDelay', 'Limits.AutoRetryCount', 'Limits.SleepStartThresholdSeconds']
absentes = [c for c in ATTENDUES if c not in cles]
if absentes:
    soucis.append('cles absentes du .kvp : ' + ', '.join(absentes))
else:
    print('ok   kvp complet              les %d cles Console/Limits sont la' % len(ATTENDUES))
if cles.get('App.ApplicationReadyMode') == 'RegexMatch' and not cles.get('Console.AppReadyRegex'):
    soucis.append('RegexMatch sans AppReadyRegex : l\'instance ne serait jamais declaree prete')
if cles.get('App.ExitMethod') != 'SIGTERM':
    soucis.append('App.ExitMethod doit etre SIGTERM : le lanceur arrete moteur, site puis MongoDB')
if int(cles.get('App.ExitTimeout', '0')) < 40:
    soucis.append('App.ExitTimeout trop court : le lanceur peut attendre 15 s le site puis 20 s MongoDB')
if cles.get('Meta.URL') != data['manifest.json']['url']:
    soucis.append('Meta.URL et manifest.json ne designent pas le meme depot')
if cles.get('Meta.SpecificDockerImage') != 'cubecoders/ampbase:debian' or cles.get('Meta.ContainerPolicy') != 'Required':
    soucis.append('image cubecoders/ampbase:debian et conteneur obligatoire attendus')

# -- 3. reglages <-> scripts --------------------------------------------------
lanceur = lire(LANCEUR)
installeur = lire(INSTALLEUR)
cmd = cles.get('App.CommandLineArgs', '')
etape_install = [e for e in updates if e['UpdateSource'] == 'Executable']
if len(etape_install) != 1:
    soucis.append('il faut exactement une etape Executable (l\'installeur)')
args_install = etape_install[0]['UpdateSourceArgs'] if etape_install else ''
if '"{{$FullBaseDir}}lancer-pychess.sh"' not in cmd:
    soucis.append('la ligne de commande doit lancer "{{$FullBaseDir}}lancer-pychess.sh"')
if '"{{$FullBaseDir}}installer-pychess.sh"' not in args_install:
    soucis.append('l\'etape d\'installation doit lancer "{{$FullBaseDir}}installer-pychess.sh"')
passes_lanceur = dict(re.findall(r'"(\w+)=\{\{([$\w]+)\}\}"', cmd))
passes_install = dict(re.findall(r'"(\w+)=\{\{([$\w]+)\}\}"', args_install))
# Les reglages secrets passent par l'environnement, jamais par la ligne de commande
# (visible dans ps et dans le journal d'AMP) : audit du 11/10/2026.
PAR_ENV = {'discord_id': 'TK_DISCORD_ID', 'discord_secret': 'TK_DISCORD_SECRET'}
try:
    env_kvp = json.loads(cles.get('App.EnvironmentVariables') or '{}')
except ValueError:
    env_kvp = {}
    soucis.append('App.EnvironmentVariables : JSON illisible')
for p, var in PAR_ENV.items():
    if env_kvp.get(var) != '{{%s}}' % p:
        soucis.append('App.EnvironmentVariables doit contenir "%s":"{{%s}}"' % (var, p))
    if var not in lanceur:
        soucis.append('le lanceur ne lit pas %s' % var)
    if '{{%s}}' % p in cmd:
        soucis.append('%s ne doit plus passer sur la ligne de commande' % p)
tous_args = re.findall(r'\{\{([$\w]+)\}\}', cmd + ' ' + args_install + ' ' + ' '.join(env_kvp.values()))
params = {}
for c in config:
    p = c['ParamFieldName']
    if p in params:
        soucis.append('reglage en double : %s' % p)
    params[p] = c
    if c['FieldName'] != p:
        soucis.append('%s : FieldName et ParamFieldName differents' % p)
    cible = passes_install if c['Category'] == 'Updates' else passes_lanceur
    if p not in PAR_ENV and cible.get(p) != p:
        soucis.append('reglage %s pas passe sous la forme "%s={{%s}}" au %s' % (p, p, p, 'installeur' if c['Category'] == 'Updates' else 'lanceur'))
    if c['InputType'] == 'number' and not str(c.get('DefaultValue', '')).isdigit():
        soucis.append('%s : valeur par defaut non numerique' % p)
for a in tous_args:
    if not a.startswith('$') and a not in params and a != 'moteur':
        soucis.append('{{%s}} sans reglage dans AMP' % a)
for a in re.findall(r'\{\{\$(\w+)\}\}', cmd):
    if a not in refs and a != 'FullBaseDir':
        soucis.append('{{$%s}} : aucun port ne porte ce Ref' % a)
if passes_lanceur.get('port') != '$' + cles.get('App.PrimaryApplicationPortRef', ''):
    soucis.append('le port principal n\'est pas passe au lanceur (port={{$WebPort}})')
if passes_install.get('moteur') != 'moteur':
    soucis.append('l\'installeur doit recevoir moteur={{moteur}} (fairyfishnet installe ou non)')
for cle in passes_lanceur:
    if 'V[%s]' % cle not in lanceur:
        soucis.append('le lanceur ne lit pas %s' % cle)
for cle in passes_install:
    if 'V[%s]' % cle not in installeur:
        soucis.append('l\'installeur ne lit pas %s' % cle)
print('ok   correspondance           %d reglages -> lanceur %s / installeur %s' % (len(params), sorted(passes_lanceur), sorted(passes_install)))
if not params['uri']['DefaultValue'].startswith('https://'):
    soucis.append('adresse publique par defaut : en https (analyse dans le navigateur, cookies)')
if params['moteur']['DefaultValue'] not in params['moteur']['EnumValues']:
    soucis.append('moteur : valeur par defaut hors de la liste')

# -- 4. fichiers telecharges a l'Update ---------------------------------------
depot = data['manifest.json']['url'].replace('https://github.com/', '')
fetch = [e for e in updates if e['UpdateSource'] == 'FetchURL']
for e in fetch:
    attendu = 'https://raw.githubusercontent.com/%s/main/scripts/%s' % (depot, e['UpdateSourceArgs'])
    if e['UpdateSourceData'] != attendu:
        soucis.append('URL inattendue pour %s : %s' % (e['UpdateSourceArgs'], e['UpdateSourceData']))
    elif not os.path.isfile(os.path.join(ICI, 'scripts', e['UpdateSourceArgs'])):
        soucis.append('scripts/%s absent du depot' % e['UpdateSourceArgs'])
    else:
        print('ok   telecharge a l\'Update    scripts/%s' % e['UpdateSourceArgs'])
if {e['UpdateSourceArgs'] for e in fetch} != {'installer-pychess.sh', 'lancer-pychess.sh'}:
    soucis.append('l\'Update doit deposer installer-pychess.sh et lancer-pychess.sh')
if updates.index(etape_install[0]) < max(updates.index(e) for e in fetch):
    soucis.append('l\'installeur doit tourner APRES le telechargement des scripts')

# -- 5. scripts -----------------------------------------------------------------
for nom in (LANCEUR, INSTALLEUR):
    brut = lire(nom, binaire=True)
    if b'\r' in brut:
        soucis.append('%s : fins de ligne Windows (CRLF)' % nom)
    if b'{{' in brut:
        soucis.append('%s contient {{ : AMP pourrait le remplacer' % nom)
for besoin, ou, pourquoi in [
    ('--bind_ip "$SOCK"', lanceur, 'MongoDB sur la socket seulement (aucun port TCP, essai du 10/10)'),
    ('--wiredTigerCacheSizeGB', lanceur, 'cache MongoDB bride (sinon la moitie de la RAM de la machine)'),
    ('XDG_RUNTIME_DIR', lanceur, 'socket hors du dossier de l\'instance'),
    ('export PYTHONUNBUFFERED=1', lanceur, 'sinon la console d\'AMP reste muette (fairyfishnet)'),
    ('export PORT URI PROD=true', lanceur, 'PROD=true : pas de variantes de dev'),
    ('--engine-dir "$ICI/moteur"', lanceur, 'le moteur doit tourner la ou sont les NNUE'),
    ('( cd moteur &&', lanceur, 'fairyfishnet telecharge les NNUE dans son dossier courant'),
    ('--endpoint "http://127.0.0.1:$PORT/fishnet/"', lanceur, 'moteur branche en local, jamais sur pychess.org'),
    ('echo "TeamKit : PyChess pret, le site repond sur le port $PORT."', lanceur, 'ligne pret'),
    ('trap arreter TERM INT', lanceur, 'arret propre'),
    ('--pdeathsig TERM', lanceur, 'les enfants ne doivent pas survivre au lanceur'),
    ('CLIENT_SECRET', lanceur, 'state OAuth Lichess non devinable (PyChess 1.11.x)'),
    ('grep -q "^$1=." donnees/secrets.env && return', installeur, 'une cle secrete existante n\'est jamais ecrasee'),
    ('mongodb-linux-x86_64-debian12-', installeur, 'archive MongoDB Debian 12 (tourne sur Debian 13, teste)'),
    ('sha256sum', installeur, 'empreintes de Node et MongoDB verifiees'),
    ('"$UV" sync --frozen --no-dev', installeur, 'dependances Python figees par uv.lock'),
    ('--frozen-lockfile', installeur, 'dependances JavaScript figees par yarn.lock'),
    ('UV_PYTHON_INSTALL_DIR="$ICI/outils/python"', installeur, 'Python dans l\'instance (le HOME du conteneur est perdu)'),
    ('mv site.new site', installeur, 'nouvelle version mise en place seulement si la construction reussit'),
    ('rm -rf node_modules', installeur, 'node_modules (~1 Go) hors des sauvegardes'),
]:
    if besoin not in ou:
        soucis.append('%s : %s (%s)' % ('lanceur' if ou is lanceur else 'installeur', besoin, pourquoi))
if re.search(r'--bind_ip\s+(?:0\.0\.0\.0|127\.0\.0\.1)', lanceur):
    soucis.append('MongoDB ne doit ecouter sur aucune adresse IP')
print('ok   scripts                  LF, pas de {{, %d points verifies' % 20)

bash = shutil.which('bash')
if bash:
    for nom in (LANCEUR, INSTALLEUR):
        r = subprocess.run([bash, '-n', os.path.join(ICI, nom)], capture_output=True, text=True)
        if r.returncode:
            soucis.append('bash -n %s : %s' % (nom, r.stderr.strip()))
    print('ok   bash -n                  les deux scripts')

    # -- 6. le lanceur face aux valeurs -----------------------------------------
    def essai(par_arguments=False, sortie=False, **vals):
        d = {p: str(c.get('DefaultValue', '')) for p, c in params.items() if c['Category'] != 'Updates'}
        d['port'] = '9180'
        d.update(vals)
        env = dict(os.environ, TK_ESSAI_REGLAGES='1')
        for p, var in PAR_ENV.items():
            env.pop(var, None)
            if not par_arguments:
                env[var] = d.pop(p)
        argv = ['%s=%s' % (k, v) for k, v in d.items()]
        r = subprocess.run([bash, os.path.join(ICI, LANCEUR)] + argv, capture_output=True, text=True, env=env)
        ok = r.returncode == 0 and 'reglages valides' in r.stdout
        return (ok, r.stdout) if sortie else ok
    BONS = [{}, {'uri': 'https://echecs.teamkit.fr/'}, {'uri': 'http://203.0.113.10:9180'},
            {'admins': 'Kevin,Marine_2,jean-luc'}, {'discord_id': '1234567890123', 'discord_secret': 'aB3_x-Y'},
            {'moteur': 'non'}, {'coeurs': '8', 'hash': '512', 'cache_mongo': '1'}, {'lichess': ''}]
    MAUVAIS = [{'uri': ''}, {'uri': 'echecs.teamkit.fr'}, {'uri': 'https://echecs.teamkit.fr/jeu'},
               {'uri': 'https://echecs teamkit.fr'}, {'admins': 'Kevin, Marine'}, {'admins': 'Ke"vin'},
               {'discord_secret': 'a b'}, {'discord_secret': 'a"b'}, {'discord_id': 'abc'},
               {'moteur': 'peut-etre'}, {'coeurs': '0'}, {'coeurs': '9'}, {'hash': '8'}, {'port': '80'},
               {'cache_mongo': '0,25'}, {'lichess': 'a b'}]
    for v in BONS:
        if not essai(**v):
            soucis.append('le lanceur refuse une valeur correcte : %r' % v)
    for v in MAUVAIS:
        if essai(**v):
            soucis.append('le lanceur accepte une valeur dangereuse : %r' % v)
    # Instance creee avant le 11/10/2026 : Discord encore en arguments, doit toujours marcher.
    if not essai(par_arguments=True, discord_id='1234567890123', discord_secret='aB3_x-Y'):
        soucis.append('le lanceur refuse Discord passe en arguments (anciennes instances)')
    if essai(par_arguments=True, discord_secret='a b'):
        soucis.append('le lanceur accepte un secret Discord dangereux passe en arguments')
    ok, sortie = essai(sortie=True)
    if 'ATTENTION' in sortie:
        soucis.append("le lanceur avertit a tort quand Discord arrive par l'environnement")
    print("ok   reglages                 %d valeurs acceptees, %d refusees comme prevu, Discord par l'environnement" % (len(BONS), len(MAUVAIS)))
else:
    print('--   bash                     pas de bash ici : syntaxe et reglages non verifies')

# -- 7. regex de console (vraies lignes, 10/10/2026) ---------------------------
ESSAIS = [
    ('Console.AppReadyRegex', 'TeamKit : PyChess pret, le site repond sur le port 9180.'),
    ('Console.ThrowawayMessageRegex', '2026-10-10 17:39:17,478.478 [DEBUG] init     system       __main__:17                     [startup] __main__ bootstrap started'),
    ('Console.ThrowawayMessageRegex', '2026-10-10 17:55:48,848.848 [DEBUG] VN1zeQrv Anon–P1HyA7IN game:994                        Removed too short game VN1zeQrv from db. Deleted 1 game.'),
    ('Console.ThrowawayMessageRegex', '{"t":{"$date":"2026-10-10T17:39:15.005Z"},"s":"I",  "c":"CONTROL",  "id":5760901, "ctx":"main","msg":"Applied --setParameter options"}'),
]
for cle, ligne in ESSAIS:
    if not py(cles.get(cle) or '^$').search(ligne):
        soucis.append('%s ne reconnait pas : %r' % (cle, ligne))
PIEGES = [
    ('Console.AppReadyRegex', 'TeamKit : demarrage de PyChess Variants 1.11.72 sur le port 9180 (adresse publique : https://echecs.teamkit.fr).'),
    ('Console.AppReadyRegex', 'TeamKit : ATTENTION, le site ne repond toujours pas apres 2 minutes.'),
    ('Console.AppReadyRegex', '======== Running on http://0.0.0.0:9180 ========'),
    ('Console.ThrowawayMessageRegex', '2026-10-10 17:39:17,579.579 [WARN]  init     system       pychess_global_app_state:836    DISCORD_TOKEN is missing/empty; Discord bot disabled'),
    ('Console.ThrowawayMessageRegex', '2026-10-10 17:39:23,120.120 [INFO]  init     system       pychess_global_app_state:414    [startup] MongoDB schema mode=fresh collections_created=46'),
    ('Console.ThrowawayMessageRegex', '2026-10-10 18:09:26,466.466 [WARN]  lobby    Anon–llDzpXXd request_protection:316          rate-limited new anonymous identity from 10.0.0.13 at path /wsl'),
    ('Console.ThrowawayMessageRegex', '><> 1: ERROR: Engine process timed out. Backing off 0.5s'),
    ('Console.ThrowawayMessageRegex', 'TeamKit : MongoDB pret.'),
    ('Console.ThrowawayMessageRegex', 'ERREUR : MongoDB n\'a pas demarre. Fin de donnees/journaux/mongod.log :'),
]
for cle, ligne in PIEGES:
    if py(cles[cle]).search(ligne):
        soucis.append('%s attrape une ligne qui n\'est pas pour lui : %r' % (cle, ligne))
print('ok   console                  %d lignes reelles, %d pieges' % (len(ESSAIS), len(PIEGES)))

print()
if soucis:
    print('%d probleme(s) :' % len(soucis))
    print('\n'.join('  NON  ' + s for s in soucis))
    sys.exit(1)
print('Tout est bon.')
