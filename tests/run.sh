#!/usr/bin/env bash
# Non-regression tests for nfs-smartmount.sh.
#
# Nothing here touches the real system: every external command the script uses
# (iw, nmcli, mountpoint, mount, umount, ping, stat, ls, logger) is a stub put
# first in PATH, and the config is a temporary file selected through
# SMARTMOUNT_CONFIG. Each case asserts on observable behaviour -- the exit code
# and the external calls that were actually issued -- never on the source text.
# Les corps de stubs passés à `stub` sont volontairement entre apostrophes : ils
# doivent être écrits tels quels dans le fichier généré, puis développés à
# l'exécution de ce fichier. SC2016 serait un faux positif ici.
# shellcheck disable=SC2016

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/nfs-smartmount.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT

PASS=0
FAIL=0
CASE_DIR=""
CALLS=""

# ---------------------------------------------------------------- helpers

stub() { # stub <name> <body>
    printf '#!/bin/sh\n%s\n' "$2" > "${CASE_DIR}/bin/$1"
    chmod +x "${CASE_DIR}/bin/$1"
}

new_case() { # new_case <name>
    CASE_DIR="${TMP}/$1"
    mkdir -p "${CASE_DIR}/bin" "${CASE_DIR}/mnt"
    CALLS="${CASE_DIR}/calls"
    FLAG="${CASE_DIR}/flag"
    CASE_DEPS=""
    : > "${CALLS}"
    rm -f "${FLAG}"
    export CALLS FLAG

    # Defaults: a home Wi-Fi in range, nothing mounted, everything reachable.
    stub logger     'printf "LOG %s\n" "$*" >> "$CALLS"'
    stub ping       'printf "ping %s\n" "$*" >> "$CALLS"; exit 0'
    stub mount      'printf "mount %s\n" "$*" >> "$CALLS"; exit 0'
    stub umount     'printf "umount %s\n" "$*" >> "$CALLS"; exit 0'
    stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 1'
    stub stat       'printf "stat\n" >> "$CALLS"; exit 0'
    stub ls         'printf "ls\n" >> "$CALLS"; exit 0'
    stub nmcli      'printf "nmcli %s\n" "$*" >> "$CALLS"; exit 0'
    stub ip         'printf "ip %s\n" "$*" >> "$CALLS"; exit 0'
    stub iw         'printf "iw %s\n" "$*" >> "$CALLS"; printf "Connected to aa:bb:cc:dd:ee:ff (on wlan0)\n\tSSID: Maison\n\tfreq: 5180\n"'

    cat > "${CASE_DIR}/config" <<EOF
NFS_SERVER_IP="192.168.1.10"
NFS_SHAREDPATH="/share"
MOUNT_POINT="${CASE_DIR}/mnt"
NFS_OPTS="nodev,nosuid,noexec"
WIFI_NAME="Maison"
WIFI_IFACE="wlan0"
NFS_SERVER_MAC="aa:bb:cc:dd:ee:ff"
LAN_IFACE="eth0"
EOF
}

set_config() { # set_config <KEY> <VALUE>
    sed -i "s|^$1=.*|$1=\"$2\"|" "${CASE_DIR}/config"
}

# Simule la table ARP : chaque interface interrogée répond, ou non, avec sa MAC.
# Format réel de `ip neigh show <ip> dev <iface>` : pas de champ « dev ».
neighbors() { # neighbors <mac sur wlan0> <mac sur eth0>   (vide = pas de voisin)
    local on_wifi="$1"
    local on_eth="$2"
    {
        printf '#!/bin/sh\n'
        printf 'printf "ip %%s\\n" "$*" >> "$CALLS"\n'
        printf 'case "$*" in\n'
        # Le motif doit garder ses globs non quotés : *"dev wlan0"* et non
        # "*dev wlan0"*, sinon les étoiles deviennent littérales et rien ne matche.
        printf '*"dev wlan0"*) printf "%%s\\n" "%s" ;;\n' "${on_wifi:+192.168.1.10 lladdr ${on_wifi} REACHABLE}"
        printf '*"dev eth0"*) printf "%%s\\n" "%s" ;;\n' "${on_eth:+192.168.1.10 lladdr ${on_eth} REACHABLE}"
        printf 'esac\nexit 0\n'
    } > "${CASE_DIR}/bin/ip"
    chmod +x "${CASE_DIR}/bin/ip"
}

# Raccourci : le NAS est visible avec la même MAC sur les deux liens.
set_neighbor() { # set_neighbor <mac>
    neighbors "${1:-}" "${1:-}"
}

# Faux script principal pour tester les hooks sans toucher au vrai.
stub_main() {
    printf '#!/bin/sh\nprintf "MAIN %%s\\n" "$*" >> "$CALLS"\n' > "${CASE_DIR}/main.sh"
    chmod +x "${CASE_DIR}/main.sh"
}

run_hook() { # run_hook <fichier du hook> <device> <state> ; echoes the exit code
    ( PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_CONFIG="${CASE_DIR}/config" \
        SMARTMOUNT_MAIN="${CASE_DIR}/main.sh" bash "${ROOT}/$1" "$2" "$3" >/dev/null 2>&1 )
    echo $?
}

run_script() { # run_script <verb> ; echoes the exit code
    # SMARTMOUNT_DEPS vide par défaut : la suite ne doit pas dépendre des paquets
    # installés sur la machine qui la lance. Les cas dédiés le renseignent.
    ( PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_CONFIG="${CASE_DIR}/config" \
        SMARTMOUNT_DEPS="${CASE_DEPS-}" \
        bash "${SCRIPT}" "$1" >/dev/null 2>&1 )
    echo $?
}

check() { # check <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        PASS=$((PASS + 1))
        printf 'ok   - %s\n' "$1"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL - %s\n       attendu: %s\n       obtenu : %s\n' "$1" "$2" "$3"
    fi
}

called() { # called <pattern> -> "oui" / "non"
    if grep -q -- "$1" "${CALLS}"; then echo oui; else echo non; fi
}

not_called() { # not_called <pattern> -> "oui" si absent
    if grep -q -- "$1" "${CALLS}"; then echo non; else echo oui; fi
}

first_call_line() { # first_call_line <pattern>
    grep -n -m1 -e "$1" "${CALLS}" | cut -d: -f1
}

# ---------------------------------------------------------------- cases

# 1. Chez soi, pas encore monté : on monte.
new_case nominal_mount
set_neighbor aa:bb:cc:dd:ee:ff
rc="$(run_script apply)"
check "nominal : code 0" 0 "${rc}"
check "nominal : mount -t nfs appelé" oui "$(called 'mount -t nfs')"
check "nominal : aucun umount" oui "$(not_called '^umount')"

# 2. Déjà monté et sain : aucune action, pas de montage en double.
new_case healthy_noop
set_neighbor aa:bb:cc:dd:ee:ff
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
rc="$(run_script apply)"
check "sain : code 0" 0 "${rc}"
check "sain : pas de mount" oui "$(not_called 'mount -t nfs')"
check "sain : pas de umount" oui "$(not_called '^umount')"
check "sain : journalise l'état sain" oui "$(called 'sain')"

# 3. NAS redémarré : le point est monté mais muet -> démonter puis remonter.
new_case nas_rebooted
set_neighbor aa:bb:cc:dd:ee:ff
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
stub stat       'printf "stat\n" >> "$CALLS"; exit 1'
stub ls         'printf "ls\n" >> "$CALLS"; exit 1'
rc="$(run_script apply)"
unmount_line="$(first_call_line '^umount')"
mount_line="$(first_call_line '^mount -t nfs')"
check "nas redémarré : code 0" 0 "${rc}"
check "nas redémarré : umount tenté" oui "$(called '^umount')"
check "nas redémarré : remontage" oui "$(called 'mount -t nfs')"
if [[ -n "${unmount_line}" && -n "${mount_line}" && ${unmount_line} -lt ${mount_line} ]]; then
    order=oui
else
    order=non
fi
check "nas redémarré : démontage avant remontage" oui "${order}"

# 4. Point occupé : umount simple échoue, le repli paresseux réussit.
new_case share_busy
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
stub umount 'printf "umount %s\n" "$*" >> "$CALLS"; case "$*" in *-l*) exit 0 ;; *) exit 1 ;; esac'
rc="$(run_script unmount)"
check "partage occupé : code 0" 0 "${rc}"
check "partage occupé : repli umount -l" oui "$(called '^umount .*-l')"

# 5. Les deux démontages échouent : erreur franche (code 2).
new_case share_stuck
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
stub umount 'printf "umount %s\n" "$*" >> "$CALLS"; exit 1'
rc="$(run_script unmount)"
check "démontage impossible : code 2" 2 "${rc}"

# 6. SSID illisible : on ne touche à rien (surtout pas démonter).
new_case ssid_unknown
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
stub umount 'printf "umount %s\n" "$*" >> "$CALLS"; exit 0'
set_config WIFI_IFACE ""
set_config WIFI_NAME "Maison"
rc="$(run_script apply)"
check "ssid illisible : code 0" 0 "${rc}"
check "ssid illisible : aucun umount" oui "$(not_called '^umount')"
check "ssid illisible : aucun mount" oui "$(not_called 'mount -t nfs')"
check "ssid illisible : journalise l'abstention" oui "$(called 'SSID illisible')"

# 7. Wi-Fi déconnecté : état certain, on démonte.
new_case wifi_disconnected
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
stub iw 'printf "iw %s\n" "$*" >> "$CALLS"; printf "Not connected.\n"'
rc="$(run_script apply)"
check "wifi coupé : code 0" 0 "${rc}"
check "wifi coupé : umount appelé" oui "$(called '^umount')"
check "wifi coupé : pas de mount" oui "$(not_called 'mount -t nfs')"

# 8. Wi-Fi étranger : on démonte.
new_case wifi_foreign
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
stub iw 'printf "iw %s\n" "$*" >> "$CALLS"; printf "Connected to aa:bb:cc:dd:ee:ff (on wlan0)\n\tSSID: CafeDuCoin\n"'
rc="$(run_script apply)"
check "wifi étranger : code 0" 0 "${rc}"
check "wifi étranger : umount appelé" oui "$(called '^umount')"
check "wifi étranger : pas de mount" oui "$(not_called 'mount -t nfs')"

# 9. Verbe inconnu : code 3.
new_case bad_verb
rc="$(run_script frobnicate)"
check "verbe inconnu : code 3" 3 "${rc}"
check "verbe inconnu : journalise l'usage" oui "$(called 'valid usage')"

# 10. Config absente : code 122.
new_case missing_config
rc="$( PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_CONFIG="${CASE_DIR}/absent" \
        bash "${SCRIPT}" apply >/dev/null 2>&1; echo $? )"
check "config absente : code 122" 122 "${rc}"

# 11. NAS injoignable (ping échoue) : l'échec reste visible, code 127.
new_case server_unreachable
set_neighbor aa:bb:cc:dd:ee:ff
stub ping 'printf "ping %s\n" "$*" >> "$CALLS"; exit 1'
rc="$(run_script apply)"
check "serveur injoignable : code 127" 127 "${rc}"
check "serveur injoignable : pas de mount" oui "$(not_called 'mount -t nfs')"
check "serveur injoignable : journalise le ping" oui "$(called 'ping test')"

# 12. Échec transitoire du test de santé : le montage est conservé.
new_case health_flaky
set_neighbor aa:bb:cc:dd:ee:ff
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
stub stat 'printf "stat\n" >> "$CALLS"; [ -f "$FLAG" ] && exit 0; : > "$FLAG"; exit 1'
rc="$(run_script apply)"
check "santé instable : code 0" 0 "${rc}"
check "santé instable : aucun umount" oui "$(not_called '^umount')"
check "santé instable : aucun remontage" oui "$(not_called 'mount -t nfs')"
check "santé instable : montage conservé" oui "$(called 'second essai')"

# 13. Montage muet ET point occupé : la réparation doit passer par umount -l.
new_case repair_needs_lazy
set_neighbor aa:bb:cc:dd:ee:ff
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
stub stat 'printf "stat\n" >> "$CALLS"; exit 1'
stub ls 'printf "ls\n" >> "$CALLS"; exit 1'
stub umount 'printf "umount %s\n" "$*" >> "$CALLS"; case "$*" in *-l*) exit 0 ;; *) exit 1 ;; esac'
rc="$(run_script apply)"
check "réparation + occupé : code 0" 0 "${rc}"
check "réparation + occupé : repli umount -l" oui "$(called '^umount .*-l')"
check "réparation + occupé : remontage" oui "$(called 'mount -t nfs')"

# 14. `mountpoint` expiré alors que rien n'est monté : ne pas bloquer le montage.
new_case mountpoint_timeout
set_neighbor aa:bb:cc:dd:ee:ff
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 124'
stub umount 'printf "umount %s\n" "$*" >> "$CALLS"; exit 1'
rc="$(run_script apply)"
check "mountpoint expiré : code 0" 0 "${rc}"
check "mountpoint expiré : montage tenté" oui "$(called 'mount -t nfs')"

# 15. `iw` indisponible : repli nmcli restreint à l'interface configurée.
new_case iw_unavailable
set_neighbor aa:bb:cc:dd:ee:ff
stub iw 'printf "iw %s\n" "$*" >> "$CALLS"; exit 1'
stub nmcli 'printf "nmcli %s\n" "$*" >> "$CALLS"; printf "yes:Maison\n"'
rc="$(run_script apply)"
check "sans iw : code 0" 0 "${rc}"
check "sans iw : montage" oui "$(called 'mount -t nfs')"
check "sans iw : nmcli filtré sur l'interface" oui "$(called 'ifname wlan0')"

# 16. SSID contenant ':' : nmcli l'échappe, on doit le restituer avant comparaison.
new_case ssid_with_colon
# `iw` en échec force le repli nmcli ; WIFI_IFACE reste renseignée pour que la
# vérification d'identité (MAC) porte bien sur l'interface Wi-Fi.
stub iw 'printf "iw %s\n" "$*" >> "$CALLS"; exit 1'
set_config WIFI_NAME "A:B"
set_neighbor aa:bb:cc:dd:ee:ff
cat > "${CASE_DIR}/bin/nmcli" <<'STUB'
#!/bin/sh
printf 'nmcli %s\n' "$*" >> "$CALLS"
printf '%s\n' 'yes:A\:B'
STUB
chmod +x "${CASE_DIR}/bin/nmcli"
rc="$(run_script apply)"
check "ssid avec ':' : code 0" 0 "${rc}"
check "ssid avec ':' : reconnu et monté" oui "$(called 'mount -t nfs')"

# 17. Verbe `mount` historique (utilisé par le hook Ethernet) : SSID étranger -> rien.
new_case mount_verb_foreign
stub iw 'printf "iw %s\n" "$*" >> "$CALLS"; printf "Connected to aa:bb:cc:dd:ee:ff (on wlan0)\n\tSSID: CafeDuCoin\n"'
rc="$(run_script mount)"
check "mount + ssid étranger : code 0" 0 "${rc}"
check "mount + ssid étranger : pas de montage" oui "$(not_called 'mount -t nfs')"

# 18. Verbe `mount` historique : SSID ciblé -> montage.
new_case mount_verb_target
set_neighbor aa:bb:cc:dd:ee:ff
rc="$(run_script mount)"
check "mount + ssid ciblé : code 0" 0 "${rc}"
check "mount + ssid ciblé : montage" oui "$(called 'mount -t nfs')"

# 19. `stat` répond mais la lecture du répertoire échoue : c'est bien un montage muet.
new_case health_ls_only
set_neighbor aa:bb:cc:dd:ee:ff
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
stub ls 'printf "ls\n" >> "$CALLS"; exit 1'
rc="$(run_script apply)"
check "ls seul en échec : code 0" 0 "${rc}"
check "ls seul en échec : réparation" oui "$(called '^umount')"
check "ls seul en échec : remontage" oui "$(called 'mount -t nfs')"

# 20. Ethernet domestique confirmé, Wi-Fi éteint : c'est le cas qui ne
# fonctionnait pas du tout avant (le hook appelait un verbe qui exigeait le SSID).
new_case eth_trusted_wifi_off
stub iw 'printf "iw %s\n" "$*" >> "$CALLS"; printf "Not connected.\n"'
set_neighbor aa:bb:cc:dd:ee:ff
rc="$(run_script apply)"
check "eth + wifi coupé : code 0" 0 "${rc}"
check "eth + wifi coupé : montage" oui "$(called 'mount -t nfs')"
check "eth + wifi coupé : ethernet confirmé" oui "$(called "NAS confirmé sur Ethernet")"

# 21. Wi-Fi étranger mais Ethernet domestique : on garde le montage (l'ancien
# hook Wi-Fi démontait, l'ancien hook Ethernet montait : ils se battaient).
new_case eth_trusted_wifi_foreign
stub iw 'printf "iw %s\n" "$*" >> "$CALLS"; printf "Connected to aa:bb:cc:dd:ee:ff\n\tSSID: CafeDuCoin\n"'
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
set_neighbor aa:bb:cc:dd:ee:ff
rc="$(run_script apply)"
check "eth + wifi étranger : code 0" 0 "${rc}"
check "eth + wifi étranger : aucun démontage" oui "$(not_called '^umount')"
check "eth + wifi étranger : ethernet confirmé" oui "$(called "NAS confirmé sur Ethernet")"

# 22. Wi-Fi domestique mais MAC Ethernet étrangère : on garde aussi le montage.
new_case wifi_trusted_eth_foreign
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
neighbors aa:bb:cc:dd:ee:ff aa:bb:cc:dd:ee:01
rc="$(run_script apply)"
check "wifi ok + eth étranger : code 0" 0 "${rc}"
check "wifi ok + eth étranger : aucun démontage" oui "$(not_called '^umount')"
check "wifi ok + eth étranger : wi-fi ciblé" oui "$(called "Wi-Fi ciblé")"

# 23. Aucun des deux liens : on démonte.
new_case neither_trusted
stub iw 'printf "iw %s\n" "$*" >> "$CALLS"; printf "Connected to aa:bb:cc:dd:ee:ff\n\tSSID: CafeDuCoin\n"'
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
neighbors aa:bb:cc:dd:ee:01 aa:bb:cc:dd:ee:01
rc="$(run_script apply)"
check "aucun lien : code 0" 0 "${rc}"
check "aucun lien : démontage" oui "$(called '^umount')"
check "aucun lien : pas de montage" oui "$(not_called 'mount -t nfs')"

# 24. MAC comparée sans tenir compte de la casse (config en majuscules).
new_case mac_case_insensitive
stub iw 'printf "iw %s\n" "$*" >> "$CALLS"; printf "Not connected.\n"'
set_config NFS_SERVER_MAC "AA:BB:CC:DD:EE:FF"
set_neighbor aa:bb:cc:dd:ee:ff
rc="$(run_script apply)"
check "mac casse différente : code 0" 0 "${rc}"
check "mac casse différente : montage" oui "$(called 'mount -t nfs')"

# 25. Une IP qui répond au ping mais sans entrée ARP n'est pas le NAS : on ne
# monte pas « au cas où » (et un montage existant est démonté).
new_case no_neighbor_no_trust
stub iw 'printf "iw %s\n" "$*" >> "$CALLS"; printf "Not connected.\n"'
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
rc="$(run_script apply)"
check "sans voisin ARP : code 0" 0 "${rc}"
check "sans voisin ARP : pas de montage" oui "$(not_called 'mount -t nfs')"
check "sans voisin ARP : démontage" oui "$(called '^umount')"

# 26. LAN_IFACE vide (config ancienne) : la voie Ethernet est simplement absente.
new_case lan_iface_missing
stub iw 'printf "iw %s\n" "$*" >> "$CALLS"; printf "Not connected.\n"'
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
set_config LAN_IFACE ""
rc="$(run_script apply)"
check "LAN_IFACE vide : code 0" 0 "${rc}"
check "LAN_IFACE vide : démontage" oui "$(called '^umount')"

# 27. Verbe `mount` manuel : l'Ethernet suffit désormais à monter.
new_case mount_verb_eth
stub iw 'printf "iw %s\n" "$*" >> "$CALLS"; printf "Not connected.\n"'
set_neighbor aa:bb:cc:dd:ee:ff
rc="$(run_script mount)"
check "mount + eth : code 0" 0 "${rc}"
check "mount + eth : montage" oui "$(called 'mount -t nfs')"

# 28-32. Les hooks ne décident plus : ils déclenchent `apply`, y compris sur
# `down` — un démontage unilatéral défaisait le montage justifié par l'autre lien.
new_case hook_eth_up
stub_main
rc="$(run_hook 98-eth-nfs-mac eth0 up)"
check "hook eth up : code 0" 0 "${rc}"
check "hook eth up : apply" oui "$(called '^MAIN apply')"

new_case hook_eth_down
stub_main
rc="$(run_hook 98-eth-nfs-mac eth0 down)"
check "hook eth down : code 0" 0 "${rc}"
check "hook eth down : apply" oui "$(called '^MAIN apply')"
check "hook eth down : aucun démontage direct" oui "$(not_called '^MAIN unmount')"

new_case hook_wifi_down
stub_main
rc="$(run_hook 99-wifi-nfs-mount wlan0 down)"
check "hook wifi down : code 0" 0 "${rc}"
check "hook wifi down : apply" oui "$(called '^MAIN apply')"
check "hook wifi down : aucun démontage direct" oui "$(not_called '^MAIN unmount')"

new_case hook_wifi_dhcp
stub_main
rc="$(run_hook 99-wifi-nfs-mount wlan0 dhcp4-change)"
check "hook wifi dhcp4-change : code 0" 0 "${rc}"
check "hook wifi dhcp4-change : apply" oui "$(called '^MAIN apply')"

new_case hook_other_device
stub_main
rc="$(run_hook 98-eth-nfs-mac eth1 up)"
check "hook autre interface : code 0" 0 "${rc}"
check "hook autre interface : aucun appel" oui "$(not_called '^MAIN')"

# 33-34. Mode dry-run : la décision est calculée et journalisée, rien n'est
# monté ni démonté (seul moyen de contrôler le chemin Ethernet sans matériel).
new_case dry_run_mount
set_neighbor aa:bb:cc:dd:ee:ff
rc="$( SMARTMOUNT_DRY_RUN=1; export SMARTMOUNT_DRY_RUN
       PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_CONFIG="${CASE_DIR}/config" \
         SMARTMOUNT_DEPS="" bash "${SCRIPT}" apply >/dev/null 2>&1; echo $? )"
check "dry-run montage : code 0" 0 "${rc}"
check "dry-run montage : aucun mount réel" oui "$(not_called 'mount -t nfs')"
check "dry-run montage : décision journalisée" oui "$(called '\[dry-run\] montage')"

new_case dry_run_unmount
stub iw 'printf "iw %s\n" "$*" >> "$CALLS"; printf "Not connected.\n"'
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
rc="$( SMARTMOUNT_DRY_RUN=1; export SMARTMOUNT_DRY_RUN
       PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_CONFIG="${CASE_DIR}/config" \
         SMARTMOUNT_DEPS="" bash "${SCRIPT}" apply >/dev/null 2>&1; echo $? )"
check "dry-run démontage : code 0" 0 "${rc}"
check "dry-run démontage : aucun umount réel" oui "$(not_called '^umount')"
check "dry-run démontage : décision journalisée" oui "$(called '\[dry-run\] démontage')"

# 35-38. La MAC cible est l'identité du serveur, exigée sur les deux liens.
new_case mac_missing_apply
set_config NFS_SERVER_MAC ""
set_neighbor aa:bb:cc:dd:ee:ff
rc="$(run_script apply)"
check "sans MAC (apply) : code 4" 4 "${rc}"
check "sans MAC (apply) : aucun montage" oui "$(not_called 'mount -t nfs')"
check "sans MAC (apply) : message dédié" oui "$(called 'MAC cible absente')"

new_case mac_missing_mount
set_config NFS_SERVER_MAC ""
set_neighbor aa:bb:cc:dd:ee:ff
rc="$(run_script mount)"
check "sans MAC (mount) : code 4" 4 "${rc}"
check "sans MAC (mount) : aucun montage" oui "$(not_called 'mount -t nfs')"

# Wi-Fi ciblé mais aucun voisin ARP : l'identité n'est pas vérifiée, donc pas de
# montage — et le montage existant est défait (cas « SSID recopié ailleurs »).
new_case wifi_ssid_ok_no_neighbor
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
rc="$(run_script apply)"
check "wifi sans voisin : code 0" 0 "${rc}"
check "wifi sans voisin : aucun montage" oui "$(not_called 'mount -t nfs')"
check "wifi sans voisin : démontage" oui "$(called '^umount')"
check "wifi sans voisin : identité non vérifiée" oui "$(called 'identité non vérifiée')"

# Wi-Fi ciblé mais MAC différente : identité refusée.
new_case wifi_ssid_ok_mac_wrong
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
set_neighbor aa:bb:cc:dd:ee:01
rc="$(run_script apply)"
check "wifi MAC fausse : code 0" 0 "${rc}"
check "wifi MAC fausse : aucun montage" oui "$(not_called 'mount -t nfs')"
check "wifi MAC fausse : démontage" oui "$(called '^umount')"
check "wifi MAC fausse : identité refusée" oui "$(called 'identité refusée')"

# 39-41. Dépendances dures : refus nommé, mais le démontage reste toujours possible.
new_case deps_missing_apply
CASE_DEPS="commande-inexistante"
set_neighbor aa:bb:cc:dd:ee:ff
rc="$(run_script apply)"
check "dépendance absente (apply) : code 5" 5 "${rc}"
check "dépendance absente (apply) : aucun montage" oui "$(not_called 'mount -t nfs')"
check "dépendance absente : commande nommée" oui "$(called 'commande-inexistante')"

new_case deps_missing_mount
CASE_DEPS="commande-inexistante"
set_neighbor aa:bb:cc:dd:ee:ff
rc="$(run_script mount)"
check "dépendance absente (mount) : code 5" 5 "${rc}"
check "dépendance absente (mount) : aucun montage" oui "$(not_called 'mount -t nfs')"

new_case deps_missing_unmount
CASE_DEPS="commande-inexistante"
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
rc="$(run_script unmount)"
check "dépendance absente : démontage toujours possible" 0 "${rc}"
check "dépendance absente : umount appelé" oui "$(called '^umount')"

# ---------------------------------------------------------------- summary

printf '\n%d test(s) ok, %d échec(s)\n' "${PASS}" "${FAIL}"
[[ ${FAIL} -eq 0 ]]
