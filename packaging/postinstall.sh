#!/bin/bash
# postinst (deb) / %post (rpm) : mêmes gestes que le scriptlet pacman.
#
# Le paquet ne peut pas fonctionner sans NetworkManager : les deux hooks vivent
# dans son dispatcher. On le signale sans faire échouer l'installation, parce que
# l'ordre des dépendances ne garantit pas que le paquet soit déjà configuré.
set -e

if [ -d /run/systemd/system ]; then
    # 1.25 : les unités et les hooks ont été renommés (nfs -> nas). Un poste qui
    # portait les anciens noms ne doit pas se retrouver avec deux hooks et deux
    # timers faisant le même travail.
    systemctl disable --now nfs-network-check.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/nfs-network-check.service \
          /etc/systemd/system/nfs-network-check.timer \
          /etc/systemd/system/timers.target.wants/nfs-network-check.timer \
          /etc/systemd/system/multi-user.target.wants/nfs-network-check.timer \
          /etc/NetworkManager/dispatcher.d/98-eth-nfs-mac \
          /etc/NetworkManager/dispatcher.d/99-wifi-nfs-mount
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now nas-network-check.timer >/dev/null 2>&1 || true
fi

if ! command -v nmcli >/dev/null 2>&1; then
    echo "smart-mount: NetworkManager (nmcli) introuvable — les hooks de montage"
    echo "             ne seront jamais déclenchés. Installez NetworkManager."
fi

echo
echo "smart-mount est installé, mais aucun partage n'est configuré."
echo
echo "  1. questionnaire (écrit /etc/smart-mount/config) :"
echo "         sudo nas-smartmount.sh setup"
echo "  2. vérifier la décision sans rien monter :"
echo "         sudo SMARTMOUNT_DRY_RUN=1 nas-smartmount.sh apply"
echo "  3. état des montages :"
echo "         sudo nas-smartmount.sh show"
echo
echo "Sans MAC cible, un partage ne monte jamais (code 4) : la MAC se lit avec"
echo "  ip neigh show <IP_DU_SERVEUR>, ou dans les baux DHCP de la box."
echo
exit 0
