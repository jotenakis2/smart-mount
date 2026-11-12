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

run_script() { # run_script <verb> ; echoes the exit code
    ( PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_CONFIG="${CASE_DIR}/config" \
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
rc="$(run_script apply)"
check "nominal : code 0" 0 "${rc}"
check "nominal : mount -t nfs appelé" oui "$(called 'mount -t nfs')"
check "nominal : aucun umount" oui "$(not_called '^umount')"

# 2. Déjà monté et sain : aucune action, pas de montage en double.
new_case healthy_noop
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
rc="$(run_script apply)"
check "sain : code 0" 0 "${rc}"
check "sain : pas de mount" oui "$(not_called 'mount -t nfs')"
check "sain : pas de umount" oui "$(not_called '^umount')"
check "sain : journalise l'état sain" oui "$(called 'sain')"

# 3. NAS redémarré : le point est monté mais muet -> démonter puis remonter.
new_case nas_rebooted
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
stub ping 'printf "ping %s\n" "$*" >> "$CALLS"; exit 1'
rc="$(run_script apply)"
check "serveur injoignable : code 127" 127 "${rc}"
check "serveur injoignable : pas de mount" oui "$(not_called 'mount -t nfs')"
check "serveur injoignable : journalise le ping" oui "$(called 'ping test')"

# 12. Échec transitoire du test de santé : le montage est conservé.
new_case health_flaky
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
stub stat 'printf "stat\n" >> "$CALLS"; [ -f "$FLAG" ] && exit 0; : > "$FLAG"; exit 1'
rc="$(run_script apply)"
check "santé instable : code 0" 0 "${rc}"
check "santé instable : aucun umount" oui "$(not_called '^umount')"
check "santé instable : aucun remontage" oui "$(not_called 'mount -t nfs')"
check "santé instable : montage conservé" oui "$(called 'second essai')"

# 13. Montage muet ET point occupé : la réparation doit passer par umount -l.
new_case repair_needs_lazy
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
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 124'
stub umount 'printf "umount %s\n" "$*" >> "$CALLS"; exit 1'
rc="$(run_script apply)"
check "mountpoint expiré : code 0" 0 "${rc}"
check "mountpoint expiré : montage tenté" oui "$(called 'mount -t nfs')"

# 15. `iw` indisponible : repli nmcli restreint à l'interface configurée.
new_case iw_unavailable
stub iw 'printf "iw %s\n" "$*" >> "$CALLS"; exit 1'
stub nmcli 'printf "nmcli %s\n" "$*" >> "$CALLS"; printf "yes:Maison\n"'
rc="$(run_script apply)"
check "sans iw : code 0" 0 "${rc}"
check "sans iw : montage" oui "$(called 'mount -t nfs')"
check "sans iw : nmcli filtré sur l'interface" oui "$(called 'ifname wlan0')"

# 16. SSID contenant ':' : nmcli l'échappe, on doit le restituer avant comparaison.
new_case ssid_with_colon
set_config WIFI_IFACE ""
set_config WIFI_NAME "A:B"
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
rc="$(run_script mount)"
check "mount + ssid ciblé : code 0" 0 "${rc}"
check "mount + ssid ciblé : montage" oui "$(called 'mount -t nfs')"

# 19. `stat` répond mais la lecture du répertoire échoue : c'est bien un montage muet.
new_case health_ls_only
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
stub ls 'printf "ls\n" >> "$CALLS"; exit 1'
rc="$(run_script apply)"
check "ls seul en échec : code 0" 0 "${rc}"
check "ls seul en échec : réparation" oui "$(called '^umount')"
check "ls seul en échec : remontage" oui "$(called 'mount -t nfs')"

# ---------------------------------------------------------------- summary

printf '\n%d test(s) ok, %d échec(s)\n' "${PASS}" "${FAIL}"
[[ ${FAIL} -eq 0 ]]
