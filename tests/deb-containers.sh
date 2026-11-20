#!/usr/bin/env bash
# shellcheck shell=bash
#
# Installe le .deb dans un conteneur d'une distribution Debian-like et vérifie ce
# qu'un utilisateur verrait : résolution des dépendances, fichiers installés, sortie
# du script de post-installation, binaire exécutable, désinstallation propre.
#
#   tests/deb-containers.sh dist/smart-mount_1.29.1-1_all.deb ubuntu:24.04
#
set -euo pipefail

pkg=${1:?chemin du .deb}
image=${2:?image, ex. ubuntu:24.04}

pkg=$(readlink -f "$pkg")
name=$(basename "$pkg")

podman run --rm -v "${pkg}:/tmp/${name}:ro,Z" "${image}" bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive
echo '### distribution :'; grep PRETTY_NAME /etc/os-release
echo '### paquets présents avant :'
for c in nmcli fuser whiptail ping mount.cifs logger; do
  printf '  %-12s %s\n' \"\$c\" \"\$(command -v \$c || echo absent)\"
done
apt-get -qq update >/dev/null
echo '### installation :'
apt-get -y install /tmp/${name} 2>&1 | tail -4
echo '### paquet :'; dpkg-query -W -f='  \${Package} \${Version} \${Architecture}\n' smart-mount
echo '### dépendances déclarées :'; dpkg-query -W -f='  Depends: \${Depends}\n' smart-mount
echo '### fichiers :'
for f in /usr/bin/nas-smartmount.sh /usr/bin/smart-mount-setup \
         /etc/NetworkManager/dispatcher.d/98-eth-nas-mac \
         /etc/NetworkManager/dispatcher.d/99-wifi-nas-mount \
         /etc/systemd/system/nas-network-check.service \
         /etc/systemd/system/nas-network-check.timer \
         /usr/share/man/man8/nas-smartmount.8.gz \
         /usr/share/man/fr/man8/nas-smartmount.8.gz; do
  [ -e \"\$f\" ] && printf '  ok   %s\n' \"\$f\" || printf '  MANQUE %s\n' \"\$f\"
done
echo '### man lisible :'
man -P cat 8 nas-smartmount 2>/dev/null | head -2 | sed 's/^/  /'
echo '### binaire :'; /usr/bin/nas-smartmount.sh --version | sed 's/^/  /'
echo '### état (aucun partage configuré) :'
/usr/bin/nas-smartmount.sh show 2>&1 | head -5 | sed 's/^/  /'
echo '### désinstallation :'
apt-get -y remove smart-mount 2>&1 | tail -3
dpkg -l smart-mount 2>/dev/null | tail -1 || echo '  paquet retiré'
"
