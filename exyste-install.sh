#!/usr/bin/env bash
#
# exyste-install.sh — Installation de bout en bout d'EXYSTE sur Ubuntu Server.
#
# Ce script installe TOUTES les dépendances et démarre l'intégralité de la
# plateforme (14 services + interface web), en mode DÉVELOPPEMENT : le bypass
# d'authentification est actif (AUTH_DEV_MODE=true), Keycloak n'est PAS requis.
# Tu n'as quasiment rien à faire : réponds aux quelques questions et c'est parti.
#
# Cible : Ubuntu Server 22.04 / 24.04 (autres Debian-like : adapter apt).
# Source du code : par défaut, le script CLONE le dépôt GitHub
#   https://github.com/Maurowin/exyste.git
# (tu peux saisir une autre URL, ou choisir une archive locale exyste-full.tar.gz).
# Pour un dépôt privé, configure une clé SSH ou une URL HTTPS avec jeton avant de lancer.
#
# Usage :
#   chmod +x exyste-install.sh
#   ./exyste-install.sh
#
# Ce qu'il installe : git, build-essential, curl, Go 1.22, Node.js 20 + npm,
# (optionnel) PostgreSQL 16 pour la persistance, (optionnel) LibreOffice pour
# l'export PDF. Puis il compile les services, configure et démarre tout via
# systemd (ou en avant-plan si tu préfères).
#
set -euo pipefail

GO_VERSION="1.22.10"
NODE_MAJOR="20"
EXYSTE_USER="${SUDO_USER:-$(whoami)}"

# ---------------- Dialogue (whiptail) avec repli texte ----------------
DIALOG=""
command -v whiptail >/dev/null 2>&1 && DIALOG="whiptail"
ask()  { local t="$1" p="$2" d="${3:-}"; if [[ -n "$DIALOG" ]]; then "$DIALOG" --title "$t" --inputbox "$p" 10 74 "$d" 3>&1 1>&2 2>&3; else read -r -p "$p [$d] : " v; echo "${v:-$d}"; fi; }
ask_pass() { local t="$1" p="$2"; if [[ -n "$DIALOG" ]]; then "$DIALOG" --title "$t" --passwordbox "$p" 10 74 3>&1 1>&2 2>&3; else read -r -s -p "$p : " v; echo >&2; echo "$v"; fi; }
confirm() { local t="$1" p="$2"; if [[ -n "$DIALOG" ]]; then "$DIALOG" --title "$t" --yesno "$p" 12 74; else read -r -p "$p [o/N] : " r; [[ "$r" =~ ^[oOyY]$ ]]; fi; }
msg()  { local t="$1" x="$2"; if [[ -n "$DIALOG" ]]; then "$DIALOG" --title "$t" --msgbox "$x" 16 74; else echo -e "\n=== $t ===\n$x\n"; fi; }
gauge_echo() { echo "$1"; }  # simple log

log() { echo -e "\033[1;36m>> $*\033[0m"; }
err() { echo -e "\033[1;31m!! $*\033[0m" >&2; }

# ---------------- Vérifs de base ----------------
if [[ "$(id -u)" -eq 0 && -z "${SUDO_USER:-}" ]]; then
  err "Lance ce script en tant qu'utilisateur normal (il appellera sudo au besoin), pas directement en root."
  exit 1
fi
if ! command -v sudo >/dev/null 2>&1; then
  err "sudo est requis. Installe-le : apt-get install -y sudo"; exit 1
fi
if ! command -v apt-get >/dev/null 2>&1; then
  err "Ce script cible Ubuntu/Debian (apt). Sur une autre distribution, adapte les commandes d'installation."; exit 1
fi

# Installe whiptail tôt pour avoir les fenêtres ensuite.
if [[ -z "$DIALOG" ]]; then
  sudo apt-get update -qq && sudo apt-get install -y -qq whiptail >/dev/null 2>&1 || true
  command -v whiptail >/dev/null 2>&1 && DIALOG="whiptail"
fi

msg "EXYSTE — Installation" "Bienvenue.\n\nCe script va installer toutes les dépendances et démarrer la plateforme EXYSTE en mode développement (authentification bypassée, Keycloak non requis).\n\nIl te posera quelques questions, puis fera tout le reste automatiquement.\n\nDurée typique : 5 à 15 minutes selon la connexion."

# ---------------- Questions de configuration ----------------
WORKDIR="$(ask "Dossier d'installation" "Où installer EXYSTE ? (le dossier 'exyste/' y sera créé/utilisé)" "$HOME")"
mkdir -p "$WORKDIR"; cd "$WORKDIR"

ENABLE_PG="non"
if confirm "Persistance" "Veux-tu installer PostgreSQL pour une persistance RÉELLE des données ?\n\n• Oui  : les données survivent aux redémarrages (recommandé pour un vrai test serveur).\n• Non  : magasin mémoire (données perdues à l'arrêt). Plus simple, suffisant pour une première découverte."; then
  ENABLE_PG="oui"
fi

ENABLE_PDF="non"
if confirm "Export PDF" "Installer LibreOffice pour l'export des rapports en PDF ?\n\n(Volumineux ~400 Mo. Tu peux dire Non et l'ajouter plus tard ; DOCX et XLSX fonctionnent sans.)"; then
  ENABLE_PDF="oui"
fi

RUN_MODE="$( if [[ -n "$DIALOG" ]]; then
  whiptail --title "Mode d'exécution" --menu "Comment démarrer les services ?" 16 74 4 \
   "systemd" "Service permanent (démarre au boot, recommandé serveur)" \
   "foreground" "En avant-plan (s'arrête si tu fermes la session)" \
   3>&1 1>&2 2>&3
 else
  echo "systemd"
 fi )"
[[ -z "$RUN_MODE" ]] && RUN_MODE="systemd"

BIND_ADDR="$(ask "Accès réseau" "Adresse d'écoute de la passerelle.\n  0.0.0.0 = accessible depuis le réseau (autres machines)\n  127.0.0.1 = accessible seulement depuis la VM" "0.0.0.0")"

# Source du code : clone GitHub (par défaut) ou archive locale.
DEFAULT_REPO_URL="https://github.com/Maurowin/exyste.git"
SOURCE="$( if [[ -n "$DIALOG" ]]; then
  whiptail --title "Source du code" --menu "D'où récupérer le code d'EXYSTE ?" 16 76 4 \
   "git"     "Cloner depuis GitHub (recommandé, toujours à jour)" \
   "archive" "Utiliser une archive locale exyste-full.tar.gz" \
   3>&1 1>&2 2>&3
 else
  echo "git"
 fi )"
[[ -z "$SOURCE" ]] && SOURCE="git"

REPO_URL=""
if [[ "$SOURCE" == "git" ]]; then
  REPO_URL="$(ask "Dépôt GitHub" "URL du dépôt à cloner.\n\nPour un dépôt PRIVÉ, utilise une URL SSH (git@github.com:Maurowin/exyste.git) avec ta clé configurée, ou une URL HTTPS avec un jeton d'accès." "$DEFAULT_REPO_URL")"
  [[ -z "$REPO_URL" ]] && REPO_URL="$DEFAULT_REPO_URL"
fi

# ---------------- Récupération du code (clone ou archive) ----------------
# Note : le clone et la décompression ont besoin de git/tar, installés juste après
# dans la section « outils de base ». On installe donc ces outils d'abord, puis on
# récupère le code.
PROJECT="$WORKDIR/exyste"

# ================= INSTALLATION DES DÉPENDANCES =================
log "Mise à jour des paquets et outils de base..."
sudo apt-get update -qq
sudo apt-get install -y -qq git curl ca-certificates build-essential jq tar >/dev/null

# Récupération du code maintenant que git et tar sont disponibles.
if [[ "$SOURCE" == "git" ]]; then
  if [[ -d "$PROJECT/.git" ]]; then
    log "Dépôt déjà présent : mise à jour (git pull)..."
    ( cd "$PROJECT" && git pull --ff-only ) || msg "Avertissement" "git pull a échoué (modifications locales ?). On poursuit avec le code déjà présent."
  else
    [[ -d "$PROJECT" ]] && { msg "Conflit" "Le dossier $PROJECT existe déjà mais n'est pas un dépôt git.\n\nDéplace-le ou choisis un autre dossier d'installation, puis relance."; exit 1; }
    log "Clonage de $REPO_URL ..."
    if ! git clone "$REPO_URL" "$PROJECT"; then
      msg "Échec du clone" "Impossible de cloner $REPO_URL.\n\nCauses fréquentes :\n - dépôt privé : configure une clé SSH ou utilise une URL HTTPS avec jeton ;\n - réseau/proxy ;\n - URL incorrecte.\n\nTu peux aussi relancer en choisissant « archive locale »."
      exit 1
    fi
  fi
else
  # Archive locale.
  if [[ ! -d "$PROJECT" ]]; then
    if [[ -f "exyste-full.tar.gz" ]]; then
      log "Décompression de exyste-full.tar.gz..."
      tar xzf exyste-full.tar.gz
    elif [[ -f "$HOME/exyste-full.tar.gz" ]]; then
      log "Décompression de ~/exyste-full.tar.gz..."
      tar xzf "$HOME/exyste-full.tar.gz"
    else
      ARCHIVE="$(ask "Archive introuvable" "Chemin complet vers exyste-full.tar.gz" "$HOME/exyste-full.tar.gz")"
      [[ -f "$ARCHIVE" ]] || { msg "Erreur" "Archive introuvable : $ARCHIVE"; exit 1; }
      tar xzf "$ARCHIVE"
    fi
  fi
fi
[[ -d "$PROJECT" ]] || { msg "Erreur" "Le dossier exyste/ est absent après récupération du code." ; exit 1; }

# ---- Go 1.22 ----
NEED_GO=1
if command -v go >/dev/null 2>&1; then
  CUR="$(go version | grep -oE 'go[0-9]+\.[0-9]+' | head -1 | tr -d 'go')"
  MAJ="${CUR%%.*}"; MIN="${CUR##*.}"
  if [[ "$MAJ" -gt 1 || ( "$MAJ" -eq 1 && "$MIN" -ge 22 ) ]]; then NEED_GO=0; log "Go $CUR déjà présent."; fi
fi
if [[ "$NEED_GO" -eq 1 ]]; then
  log "Installation de Go ${GO_VERSION}..."
  ARCH="$(dpkg --print-architecture)"; [[ "$ARCH" == "amd64" ]] && GOARCH="amd64" || GOARCH="arm64"
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz" -o /tmp/go.tgz
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf /tmp/go.tgz
  rm -f /tmp/go.tgz
fi
export PATH="$PATH:/usr/local/go/bin"
# Persiste le PATH pour les sessions futures.
if ! grep -q '/usr/local/go/bin' /etc/profile.d/exyste-go.sh 2>/dev/null; then
  echo 'export PATH="$PATH:/usr/local/go/bin"' | sudo tee /etc/profile.d/exyste-go.sh >/dev/null
fi
log "Go : $(go version)"

# ---- Node.js 20 + npm ----
NEED_NODE=1
if command -v node >/dev/null 2>&1; then
  NV="$(node -v | tr -d 'v' | cut -d. -f1)"
  [[ "$NV" -ge "$NODE_MAJOR" ]] && { NEED_NODE=0; log "Node $(node -v) déjà présent."; }
fi
if [[ "$NEED_NODE" -eq 1 ]]; then
  log "Installation de Node.js ${NODE_MAJOR}..."
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash - >/dev/null 2>&1
  sudo apt-get install -y -qq nodejs >/dev/null
fi
log "Node : $(node -v) / npm : $(npm -v)"

# ---- Outils d'export documents (docx + openpyxl ; LibreOffice optionnel) ----
log "Installation des outils de génération de rapports..."
sudo npm install -g docx >/dev/null 2>&1 || true
sudo apt-get install -y -qq python3 python3-pip >/dev/null
pip3 install --quiet --break-system-packages openpyxl 2>/dev/null || pip3 install --quiet openpyxl 2>/dev/null || true
if [[ "$ENABLE_PDF" == "oui" ]]; then
  log "Installation de LibreOffice (export PDF)..."
  sudo apt-get install -y -qq libreoffice-writer libreoffice-calc >/dev/null
fi

# ---- PostgreSQL (optionnel) ----
DATABASE_URLS=""
if [[ "$ENABLE_PG" == "oui" ]]; then
  log "Installation de PostgreSQL..."
  sudo apt-get install -y -qq postgresql postgresql-client >/dev/null
  sudo systemctl enable --now postgresql >/dev/null 2>&1 || true
  PGPASS="$(ask_pass "PostgreSQL" "Mot de passe à définir pour l'utilisateur PostgreSQL 'exyste'")"
  [[ -z "$PGPASS" ]] && PGPASS="exyste"
  log "Création de l'utilisateur et des bases EXYSTE..."
  sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='exyste'" | grep -q 1 || \
    sudo -u postgres psql -q -c "CREATE ROLE exyste LOGIN PASSWORD '${PGPASS}';"
  for db in exyste_iam exyste_knowledge exyste_org exyste_risk exyste_validation \
            exyste_kpi exyste_reporting exyste_vuln exyste_pentest exyste_audit; do
    sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${db}'" | grep -q 1 || \
      sudo -u postgres psql -q -c "CREATE DATABASE ${db} OWNER exyste;"
  done
  PGHOST="localhost"
  DATABASE_URLS="oui"
  log "PostgreSQL prêt (10 bases créées, propriétaire 'exyste')."
fi

# ================= COMPILATION =================
cd "$PROJECT"
export GOTOOLCHAIN=local GOFLAGS=-mod=mod GOWORK=off
log "Compilation des 14 services (première fois : peut prendre quelques minutes)..."
BIN_DIR="$PROJECT/.bin"
mkdir -p "$BIN_DIR"
SERVICES="gateway iam-bff knowledge-base audit-log org-context risk-engine validation-workflow kpi-consolidation reporting-export vuln-service pentest-roadmap mitre-attack ai-assistant"
for s in $SERVICES; do
  echo "   - $s"
  ( cd "services/$s" && go build -o "$BIN_DIR/$s" ./cmd/server )
done
log "Compilation terminée. Binaires dans $BIN_DIR"

# Construit l'interface web (dépendances + build de prod).
log "Installation des dépendances du frontend..."
( cd frontend && npm install --no-audit --no-fund >/dev/null 2>&1 )

# Dépendances du service de rendu binaire (Node : docx + exceljs).
log "Installation des dépendances du service de rendu (rapports PDF/DOCX/XLSX)..."
( cd services/render-service && npm install --omit=dev --no-audit --no-fund >/dev/null 2>&1 )
if [[ "$ENABLE_PDF" != "oui" ]]; then
  log "Note : LibreOffice non installé -> le rendu PDF sera indisponible (DOCX/XLSX OK). Relance avec l'option PDF pour l'activer."
fi

# ================= CONFIGURATION DES PORTS / URLS =================
declare -A PORTS=( [gateway]=8080 [iam-bff]=8081 [knowledge-base]=8082 [audit-log]=8083 \
  [org-context]=8084 [risk-engine]=8085 [validation-workflow]=8086 [kpi-consolidation]=8087 \
  [reporting-export]=8089 [vuln-service]=8090 [pentest-roadmap]=8091 [mitre-attack]=8092 [ai-assistant]=8093 )

# Associe chaque service à sa base (si PostgreSQL activé).
declare -A DBOF=( [iam-bff]=exyste_iam [knowledge-base]=exyste_knowledge [org-context]=exyste_org \
  [risk-engine]=exyste_risk [validation-workflow]=exyste_validation [kpi-consolidation]=exyste_kpi \
  [reporting-export]=exyste_reporting [vuln-service]=exyste_vuln [pentest-roadmap]=exyste_pentest \
  [audit-log]=exyste_audit )

# URLs internes pour la passerelle (toutes en localhost sur la VM).
GW_ENV=""
for s in iam-bff knowledge-base audit-log org-context risk-engine validation-workflow \
         kpi-consolidation reporting-export vuln-service pentest-roadmap mitre-attack ai-assistant; do
  VAR="$(echo "$s" | tr 'a-z-' 'A-Z_')_URL"
  GW_ENV="$GW_ENV $VAR=http://localhost:${PORTS[$s]}"
done

# ================= DÉMARRAGE =================
if [[ "$RUN_MODE" == "systemd" ]]; then
  log "Création des services systemd (démarrage automatique au boot)..."
  for s in $SERVICES; do
    PORT="${PORTS[$s]}"
    ENVLINES="Environment=AUTH_DEV_MODE=true"
    ENVLINES="$ENVLINES"$'\n'"Environment=LISTEN_ADDR=:${PORT}"
    # Adresse d'écoute de la passerelle paramétrable.
    if [[ "$s" == "gateway" ]]; then
      ENVLINES="Environment=AUTH_DEV_MODE=true"$'\n'"Environment=LISTEN_ADDR=${BIND_ADDR}:${PORT}"
      for kv in $GW_ENV; do ENVLINES="$ENVLINES"$'\n'"Environment=$kv"; done
    fi
    # Persistance : injecte DATABASE_URL si PostgreSQL est activé et le service est à état.
    if [[ "$ENABLE_PG" == "oui" && -n "${DBOF[$s]:-}" ]]; then
      ENVLINES="$ENVLINES"$'\n'"Environment=DATABASE_URL=postgres://exyste:${PGPASS}@localhost:5432/${DBOF[$s]}?sslmode=disable"
    fi
    # Le service de reporting appelle le service de rendu binaire.
    if [[ "$s" == "reporting-export" ]]; then
      ENVLINES="$ENVLINES"$'\n'"Environment=RENDER_SERVICE_URL=http://localhost:8094"
    fi
    sudo tee "/etc/systemd/system/exyste-$s.service" >/dev/null <<UNIT
[Unit]
Description=EXYSTE $s
After=network.target ${ENABLE_PG:+postgresql.service}

[Service]
Type=simple
User=$EXYSTE_USER
WorkingDirectory=$PROJECT/services/$s
ExecStart=$BIN_DIR/$s
$ENVLINES
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
  done

  # Service de rendu binaire (Node) : unité dédiée.
  sudo tee "/etc/systemd/system/exyste-render-service.service" >/dev/null <<UNIT
[Unit]
Description=EXYSTE render-service (rapports binaires PDF/DOCX/XLSX)
After=network.target

[Service]
Type=simple
User=$EXYSTE_USER
WorkingDirectory=$PROJECT/services/render-service
Environment=PORT=8094
ExecStart=$(command -v node) src/server.js
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

  sudo systemctl daemon-reload
  sudo systemctl enable --now exyste-render-service >/dev/null 2>&1 || true
  for s in $SERVICES; do sudo systemctl enable --now "exyste-$s" >/dev/null 2>&1; done
  sleep 3
  log "Services systemd démarrés."

  # Interface web : service systemd dédié (Vite en mode preview/prod servi).
  ( cd frontend && npm run build >/dev/null 2>&1 ) || true
  sudo tee "/etc/systemd/system/exyste-frontend.service" >/dev/null <<UNIT
[Unit]
Description=EXYSTE frontend (Vite preview)
After=network.target exyste-gateway.service

[Service]
Type=simple
User=$EXYSTE_USER
WorkingDirectory=$PROJECT/frontend
Environment=EXYSTE_GATEWAY_URL=http://localhost:8080
ExecStart=$(command -v npm) run preview -- --host ${BIND_ADDR} --port 5173
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now exyste-frontend >/dev/null 2>&1 || true

else
  # Mode avant-plan : réutilise le script run-dev.sh existant pour les services,
  # et lance le frontend en dev. (S'arrête à la fermeture de la session.)
  log "Démarrage en avant-plan via scripts/run-dev.sh (CTRL+C pour arrêter)."
  msg "Démarrage" "Les services vont démarrer en avant-plan.\n\nLaisse ce terminal ouvert. Pour l'interface web, ouvre un AUTRE terminal et lance :\n  cd $PROJECT/frontend && npm run dev -- --host\n\nFerme avec CTRL+C."
fi

# ================= VÉRIFICATION & RÉSUMÉ =================
IPADDR="$(hostname -I 2>/dev/null | awk '{print $1}')"
HEALTH="(non vérifié)"
if [[ "$RUN_MODE" == "systemd" ]]; then
  sleep 2
  if curl -fsS "http://localhost:8080/healthz" >/dev/null 2>&1; then HEALTH="OK ✓"; else HEALTH="à vérifier (les services démarrent peut-être encore)"; fi
fi

TOKEN_HINT="$PROJECT/scripts/dev-token.sh demo admin_fonctionnel,analyste GROUPE,E1,E2"

SUMMARY="Installation terminée.

Mode             : développement (auth bypassée, Keycloak NON requis)
Source du code   : $([[ "$SOURCE" == "git" ]] && echo "clone GitHub ($REPO_URL)" || echo "archive locale")
Persistance      : $([[ "$ENABLE_PG" == "oui" ]] && echo "PostgreSQL (données conservées)" || echo "mémoire (volatile)")
Export PDF       : $([[ "$ENABLE_PDF" == "oui" ]] && echo "oui (LibreOffice)" || echo "non (DOCX/XLSX seulement)")
Exécution        : $RUN_MODE
Santé passerelle : $HEALTH

ACCÈS
  API passerelle : http://${IPADDR:-localhost}:8080
  Interface web  : http://${IPADDR:-localhost}:5173
  (depuis la VM  : http://localhost:8080 et :5173)

TESTER L'API (depuis la VM)
  TOKEN=\$($TOKEN_HINT)
  curl -s -H \"Authorization: Bearer \$TOKEN\" \\
    -X POST http://localhost:8080/api/knowledge/v1/entities/E1/seed-defaults | jq .

GÉRER LES SERVICES (systemd)
  sudo systemctl status 'exyste-*'
  sudo systemctl restart exyste-gateway
  journalctl -u exyste-risk-engine -f

Le bypass d'authentification reste actif sur TOUS les modules tant que tu n'as pas
validé. Quand tu seras prêt à passer à Keycloak, on désactivera AUTH_DEV_MODE
service par service (rien à refaire côté code)."

msg "EXYSTE prêt" "$SUMMARY"
echo "$SUMMARY"
