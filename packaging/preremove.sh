#!/bin/bash
# prerm (deb) / %preun (rpm) : arrête le timer avant que ses fichiers disparaissent.
# La configuration /etc/smart-mount/ n'appartient pas au paquet : elle reste en place.
set -e

if [ -d /run/systemd/system ]; then
    systemctl disable --now nas-network-check.timer >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
fi

exit 0
