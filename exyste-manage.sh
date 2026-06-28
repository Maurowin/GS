#!/usr/bin/env bash
#
# exyste-manage.sh — Gérer EXYSTE après installation (systemd).
#
# Usage :
#   ./exyste-manage.sh status        # état de tous les services
#   ./exyste-manage.sh start|stop|restart
#   ./exyste-manage.sh logs <service>   # ex: logs risk-engine
#   ./exyste-manage.sh prod-auth <service|all>   # DÉSACTIVE le bypass (active Keycloak)
#   ./exyste-manage.sh dev-auth  <service|all>   # RÉACTIVE le bypass de développement
#   ./exyste-manage.sh remove        # supprime tous les services systemd EXYSTE
#
set -euo pipefail

SERVICES="gateway iam-bff knowledge-base audit-log org-context risk-engine validation-workflow kpi-consolidation reporting-export vuln-service pentest-roadmap mitre-attack ai-assistant frontend"
STATEFUL="gateway iam-bff knowledge-base audit-log org-context risk-engine validation-workflow kpi-consolidation reporting-export vuln-service pentest-roadmap mitre-attack ai-assistant"

cmd="${1:-status}"; arg="${2:-}"

case "$cmd" in
  status)
    for s in $SERVICES; do
      st=$(systemctl is-active "exyste-$s" 2>/dev/null || echo "absent")
      printf "  %-22s %s\n" "$s" "$st"
    done ;;
  start|stop|restart)
    for s in $SERVICES; do sudo systemctl "$cmd" "exyste-$s" 2>/dev/null || true; done
    echo ">> $cmd effectué." ;;
  logs)
    [[ -z "$arg" ]] && { echo "Précise un service, ex: $0 logs risk-engine"; exit 1; }
    journalctl -u "exyste-$arg" -f ;;
  prod-auth)
    # Désactive le bypass : retire AUTH_DEV_MODE=true (les services exigeront un vrai jeton OIDC).
    targets="$STATEFUL"; [[ "$arg" != "all" && -n "$arg" ]] && targets="$arg"
    for s in $targets; do
      sudo sed -i '/Environment=AUTH_DEV_MODE=true/d' "/etc/systemd/system/exyste-$s.service" 2>/dev/null || true
    done
    sudo systemctl daemon-reload
    for s in $targets; do sudo systemctl restart "exyste-$s" 2>/dev/null || true; done
    echo ">> Bypass d'authentification DÉSACTIVÉ pour : $targets"
    echo ">> Assure-toi que les variables OIDC (OIDC_ISSUER, etc.) sont configurées et Keycloak démarré." ;;
  dev-auth)
    # Réactive le bypass de développement.
    targets="$STATEFUL"; [[ "$arg" != "all" && -n "$arg" ]] && targets="$arg"
    for s in $targets; do
      unit="/etc/systemd/system/exyste-$s.service"
      [[ -f "$unit" ]] || continue
      grep -q "AUTH_DEV_MODE=true" "$unit" || \
        sudo sed -i '/^\[Service\]/a Environment=AUTH_DEV_MODE=true' "$unit"
    done
    sudo systemctl daemon-reload
    for s in $targets; do sudo systemctl restart "exyste-$s" 2>/dev/null || true; done
    echo ">> Bypass d'authentification RÉACTIVÉ pour : $targets" ;;
  remove)
    read -r -p "Supprimer tous les services systemd EXYSTE ? [o/N] : " r
    [[ "$r" =~ ^[oOyY]$ ]] || { echo "Annulé."; exit 0; }
    for s in $SERVICES; do
      sudo systemctl disable --now "exyste-$s" 2>/dev/null || true
      sudo rm -f "/etc/systemd/system/exyste-$s.service"
    done
    sudo systemctl daemon-reload
    echo ">> Services EXYSTE supprimés. (Les binaires, le code et PostgreSQL restent en place.)" ;;
  *)
    echo "Usage : $0 {status|start|stop|restart|logs <svc>|prod-auth <svc|all>|dev-auth <svc|all>|remove}" ;;
esac
