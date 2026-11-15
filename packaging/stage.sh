#!/usr/bin/env bash
# shellcheck enable=all
#
# Prépare l'arbre utilisé par nfpm pour les paquets deb et rpm.
#
# Deux raisons de ne pas empaqueter les fichiers du dépôt tels quels :
#   - les hooks et l'unité appellent /usr/local/bin/nas-smartmount.sh, alors qu'un
#     paquet système installe dans /usr/bin (le Makefile fait la même réécriture
#     pour `make install PREFIX=/usr`) ;
#   - les pages de man doivent être compressées dans l'arbre, sinon dpkg et rpm
#     installent un fichier .8 non compressé et man(1) ne le trouve pas.

set -euo pipefail

out="${1:-dist/stage}"
rm -rf "${out}"
mkdir -p "${out}"

for f in 98-eth-nas-mac 99-wifi-nas-mount nas-network-check.service; do
  sed 's|/usr/local/bin/|/usr/bin/|' "${f}" >"${out}/${f}"
done
cp nas-network-check.timer "${out}/"

install -m 0755 nas-smartmount.sh setup.sh "${out}/"
gzip -9nc nas-smartmount.en.8 >"${out}/nas-smartmount.8.gz"
gzip -9nc nas-smartmount.fr.8 >"${out}/nas-smartmount.fr.8.gz"
cp LICENSE packaging-key.asc "${out}/"

echo "arbre prêt : ${out}"
