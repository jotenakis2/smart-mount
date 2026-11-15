#!/usr/bin/env bash
# shellcheck enable=all
#
# Construit et signe le paquet, en tant qu'utilisateur de construction (makepkg
# refuse root). Appelé par .github/workflows/package.yml avec l'empreinte de la clé
# en argument ; la clé privée et sa phrase de passe sont attendues dans le HOME de
# l'utilisateur courant, déposées par le workflow :
#   ~/signing-key.asc   clé privée blindée
#   ~/signing-pass      phrase de passe, sans saut de ligne final

set -euo pipefail

key_id="${1:-}"
[[ -n ${key_id} ]] || { echo "empreinte de clé manquante" >&2; exit 1; }
for f in "${HOME}/signing-key.asc" "${HOME}/signing-pass"; do
  [[ -r ${f} ]] || { echo "fichier de signature absent : ${f}" >&2; exit 1; }
done

install -d -m 700 "${HOME}/.gnupg"
echo 'allow-loopback-pinentry' >"${HOME}/.gnupg/gpg-agent.conf"
echo 'pinentry-mode loopback' >"${HOME}/.gnupg/gpg.conf"
gpgconf --kill gpg-agent 2>/dev/null || true

gpg --batch --import "${HOME}/signing-key.asc"

# Amorçage : la signature réelle n'aura pas de terminal pour demander la phrase de
# passe, on la fait donc mettre en cache par gpg-agent sur un fichier vide.
gpg --batch --pinentry-mode loopback --passphrase-file "${HOME}/signing-pass" \
  --local-user "${key_id}" --detach-sign -o /dev/null /dev/null

# --nodeps : les dépendances du paquet sont des dépendances d'EXÉCUTION
# (NetworkManager, systemd, nfs-utils…), inutiles pour produire des fichiers.
makepkg -f --nodeps --sign --key "${key_id}"

rm -f "${HOME}/signing-key.asc" "${HOME}/signing-pass"
gpgconf --kill gpg-agent 2>/dev/null || true
echo "paquet signé avec ${key_id}"
