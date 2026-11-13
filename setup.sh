#!/usr/bin/env bash
# Le questionnaire vit maintenant dans nas-smartmount.sh (`setup`) : un seul
# fichier, un seul catalogue de messages, un seul format d'enregistrement.
# Ce point d'entrée reste pour les habitudes et pour les messages d'aide déjà
# publiés ; il ne fait que transmettre.
set -uo pipefail

# Le script principal est à côté (paquet, arbre de sources) ; sinon on retombe
# sur l'installation par défaut.
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MAIN="${SMARTMOUNT_MAIN:-${HERE}/nas-smartmount.sh}"
[[ -x "${MAIN}" ]] || MAIN=/usr/local/bin/nas-smartmount.sh

# Les options d'information s'adressent au script, pas au questionnaire.
case "${1:-}" in
    -h|--help|-V|--version) exec "${MAIN}" "$@" ;;
esac

exec "${MAIN}" setup "$@"
