#!/usr/bin/env bash
# Rejoue localement les contrôles que fait le job deb-rpm.
set -euo pipefail
cd "$(dirname "$0")/.."

debs=(dist/*.deb); rpms=(dist/*.rpm)
deb=${debs[0]}
rpm=${rpms[0]}
echo "deb : $deb"
echo "rpm : $rpm"

member=$(ar t "$deb" | grep '^data\.tar' | head -1)
ctrl=$(ar t "$deb" | grep '^control\.tar' | head -1)

printf 'binaire dans le deb      : %s\n' "$(ar p "$deb" "$member" | bsdtar tf - | grep -c 'usr/bin/nas-smartmount.sh')"
printf 'hook dans le rpm         : %s\n' "$(bsdtar tf "$rpm" | grep -c 'dispatcher.d/98-eth-nas-mac')"
printf 'man FR dans le rpm       : %s\n' "$(bsdtar tf "$rpm" | grep -c 'man/fr/man8/nas-smartmount.8.gz')"
printf 'VER dans le binaire deb  : %s\n' "$(ar p "$deb" "$member" | bsdtar xOf - ./usr/bin/nas-smartmount.sh | grep -c 'VER=1.28')"

echo '--- depends du deb :'
ar p "$deb" "$ctrl" | bsdtar xOf - ./control | grep -E '^(Depends|Recommends|Architecture)'
echo '--- requires du rpm (chaînes exactes) :'
for dep in bash coreutils util-linux iproute2 iputils nfs-utils NetworkManager systemd newt; do
  printf '  %-16s %s\n' "$dep" "$(strings "$rpm" | grep -cx "$dep")"
done
echo '--- scriptlets :'
ar p "$deb" "$ctrl" | bsdtar tf - | grep -E 'postinst|prerm' | tr '\n' ' '
