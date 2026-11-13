#!/usr/bin/env bash
# Non-regression tests for nas-smartmount.sh.
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

# Les messages suivent la locale : la suite les fige en anglais pour rester
# déterministe, et les cas qui testent le français la surchargent explicitement.
export LC_ALL=C
unset LANG LANGUAGE LC_MESSAGES || true

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/nas-smartmount.sh"
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
    mkdir -p "${CASE_DIR}/bin" "${CASE_DIR}/mnt" "${CASE_DIR}/mnt2"
    CALLS="${CASE_DIR}/calls"
    FLAG="${CASE_DIR}/flag"
    FINDTAB="${CASE_DIR}/findtab"
    CASE_DEPS=""
    : > "${CALLS}"
    : > "${FINDTAB}"
    rm -f "${FLAG}"
    export CALLS FLAG FINDTAB

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
    # findmnt : répond depuis ${FINDTAB} ("TARGET SOURCE FSTYPE OPTIONS"), en
    # respectant la projection demandée par -o/-no (sinon un appel à
    # `-no FSTYPE` renverrait quatre colonnes et le test validerait une sortie
    # que le vrai findmnt ne produit jamais), et échoue quand -M cible un point
    # absent, comme le vrai.
    cat > "${CASE_DIR}/bin/findmnt" <<'STUB'
#!/bin/sh
printf 'findmnt %s\n' "$*" >> "$CALLS"
target=''
cols='TARGET,SOURCE,FSTYPE,OPTIONS'
prev=''
for a in "$@"; do
    [ "$prev" = '-M' ] && target="$a"
    case "$a" in
        *,*)                          cols="$a" ;;
        TARGET|SOURCE|FSTYPE|OPTIONS) cols="$a" ;;
    esac
    prev="$a"
done

project() {
    awk -v cols="$cols" '
        BEGIN {
            n = split(cols, a, ",")
            for (i = 1; i <= n; i++) {
                idx[i] = 1
                if (a[i] == "SOURCE") idx[i] = 2
                if (a[i] == "FSTYPE") idx[i] = 3
                if (a[i] == "OPTIONS") idx[i] = 4
            }
        }
        {
            out = ""
            for (i = 1; i <= n; i++) out = out (i > 1 ? " " : "") $idx[i]
            print out
        }
    '
}

if [ -n "$target" ]; then
    line="$(grep -F -- "$target " "${FINDTAB}" 2>/dev/null)" || exit 1
    printf '%s\n' "$line" | project
    exit 0
fi

project < "${FINDTAB}"
STUB
    chmod +x "${CASE_DIR}/bin/findmnt"
    stub iw         'printf "iw %s\n" "$*" >> "$CALLS"; printf "Connected to aa:bb:cc:dd:ee:ff (on wlan0)\n\tSSID: Maison\n\tfreq: 5180\n"'

    CASE_SHARES=("nfs|192.168.1.10|/share|${CASE_DIR}/mnt|nodev,nosuid,noexec|aa:bb:cc:dd:ee:ff|")
    CASE_WIFI_NAME="Maison"
    CASE_WIFI_IFACE="wlan0"
    CASE_LAN_IFACE="eth0"
    write_config
}

write_config() { # écrit la configuration à partir des variables du cas
    local rec=''
    {
        printf 'WIFI_NAME="%s"\n' "${CASE_WIFI_NAME}"
        printf 'WIFI_IFACE="%s"\n' "${CASE_WIFI_IFACE}"
        printf 'LAN_IFACE="%s"\n' "${CASE_LAN_IFACE}"
        printf 'SHARES=(\n'
        for rec in "${CASE_SHARES[@]}"; do
            printf '  "%s"\n' "${rec}"
        done
        printf ')\n'
    } > "${CASE_DIR}/config"
}

set_share_mac() { # set_share_mac <mac> : remplace la MAC du premier partage
    CASE_SHARES[0]="$(printf '%s' "${CASE_SHARES[0]}" \
        | awk -v m="$1" -F'|' 'BEGIN{OFS="|"} { $6=m; print }')"
    write_config
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

called_count() { # called_count <pattern> -> nombre d'occurrences
    grep -c -- "$1" "${CALLS}" || true
}

set_mount_table() { # set_mount_table "TARGET SOURCE FSTYPE OPTIONS" ...
    printf '%s\n' "$@" > "${FINDTAB}"
}

run_show() { # run_show -> stdout du verbe show
    ( PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_CONFIG="${CASE_DIR}/config" \
        SMARTMOUNT_DEPS="${CASE_DEPS-}" bash "${SCRIPT}" show 2>/dev/null )
}

run_show_json() { # run_show_json -> stdout de `show --json`
    ( PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_CONFIG="${CASE_DIR}/config" \
        SMARTMOUNT_DEPS="${CASE_DEPS-}" bash "${SCRIPT}" show --json 2>/dev/null )
}

contains() { # contains <texte> <motif> -> oui/non
    case "$1" in
        *"$2"*) echo oui ;;
        *)      echo non ;;
    esac
}

lacks() { # lacks <texte> <motif> -> oui si absent
    case "$1" in
        *"$2"*) echo non ;;
        *)      echo oui ;;
    esac
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
check "sain : journalise l'état sain" oui "$(called 'already mounted and healthy')"

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
check "ssid illisible : journalise l'abstention" oui "$(called 'SSID unreadable')"

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
check "serveur injoignable : journalise l injoignabilité" oui "$(called "unreachable")"

# 12. Échec transitoire du test de santé : le montage est conservé.
new_case health_flaky
set_neighbor aa:bb:cc:dd:ee:ff
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
stub stat 'printf "stat\n" >> "$CALLS"; [ -f "$FLAG" ] && exit 0; : > "$FLAG"; exit 1'
rc="$(run_script apply)"
check "santé instable : code 0" 0 "${rc}"
check "santé instable : aucun umount" oui "$(not_called '^umount')"
check "santé instable : aucun remontage" oui "$(not_called 'mount -t nfs')"
check "santé instable : montage conservé" oui "$(called 'second check')"

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
check "eth + wifi coupé : ethernet confirmé" oui "$(called "confirmed on Ethernet")"

# 21. Wi-Fi étranger mais Ethernet domestique : on garde le montage (l'ancien
# hook Wi-Fi démontait, l'ancien hook Ethernet montait : ils se battaient).
new_case eth_trusted_wifi_foreign
stub iw 'printf "iw %s\n" "$*" >> "$CALLS"; printf "Connected to aa:bb:cc:dd:ee:ff\n\tSSID: CafeDuCoin\n"'
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
set_neighbor aa:bb:cc:dd:ee:ff
rc="$(run_script apply)"
check "eth + wifi étranger : code 0" 0 "${rc}"
check "eth + wifi étranger : aucun démontage" oui "$(not_called '^umount')"
check "eth + wifi étranger : ethernet confirmé" oui "$(called "confirmed on Ethernet")"

# 22. Wi-Fi domestique mais MAC Ethernet étrangère : on garde aussi le montage.
new_case wifi_trusted_eth_foreign
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
neighbors aa:bb:cc:dd:ee:ff aa:bb:cc:dd:ee:01
rc="$(run_script apply)"
check "wifi ok + eth étranger : code 0" 0 "${rc}"
check "wifi ok + eth étranger : aucun démontage" oui "$(not_called '^umount')"
check "wifi ok + eth étranger : wi-fi ciblé" oui "$(called "targeted Wi-Fi")"

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
set_share_mac "AA:BB:CC:DD:EE:FF"
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
check "dry-run montage : décision journalisée" oui "$(called '\[dry-run\] mount')"

new_case dry_run_unmount
stub iw 'printf "iw %s\n" "$*" >> "$CALLS"; printf "Not connected.\n"'
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
rc="$( SMARTMOUNT_DRY_RUN=1; export SMARTMOUNT_DRY_RUN
       PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_CONFIG="${CASE_DIR}/config" \
         SMARTMOUNT_DEPS="" bash "${SCRIPT}" apply >/dev/null 2>&1; echo $? )"
check "dry-run démontage : code 0" 0 "${rc}"
check "dry-run démontage : aucun umount réel" oui "$(not_called '^umount')"
check "dry-run démontage : décision journalisée" oui "$(called '\[dry-run\] unmount')"

# 35-38. La MAC cible est l'identité du serveur, exigée sur les deux liens.
new_case mac_missing_apply
set_share_mac ""
set_neighbor aa:bb:cc:dd:ee:ff
rc="$(run_script apply)"
check "sans MAC (apply) : code 4" 4 "${rc}"
check "sans MAC (apply) : aucun montage" oui "$(not_called 'mount -t nfs')"
check "sans MAC (apply) : message dédié" oui "$(called 'no target MAC')"

new_case mac_missing_mount
set_share_mac ""
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
check "wifi sans voisin : identité non vérifiée" oui "$(called 'identity not verified')"

# Wi-Fi ciblé mais MAC différente : identité refusée.
new_case wifi_ssid_ok_mac_wrong
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
set_neighbor aa:bb:cc:dd:ee:01
rc="$(run_script apply)"
check "wifi MAC fausse : code 0" 0 "${rc}"
check "wifi MAC fausse : aucun montage" oui "$(not_called 'mount -t nfs')"
check "wifi MAC fausse : démontage" oui "$(called '^umount')"
check "wifi MAC fausse : identité refusée" oui "$(called 'identity rejected')"

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

# 42-47. Plusieurs partages, deux types de montage, et l'ancien format de config.
new_case multi_share_one_present
# Seul le serveur du premier partage est présent dans la table ARP.
neighbors aa:bb:cc:dd:ee:ff ""
CASE_SHARES=(
    "nfs|192.168.1.10|/share|${CASE_DIR}/mnt|nodev|aa:bb:cc:dd:ee:ff|"
    "nfs|192.168.1.20|/share2|${CASE_DIR}/mnt2|nodev|11:22:33:44:55:66|"
)
write_config
rc="$(run_script apply)"
check "multi : code 0" 0 "${rc}"
check "multi : partage présent monté" oui "$(called '192.168.1.10:/share ')"
check "multi : partage absent non monté" oui "$(not_called '192.168.1.20:/share2')"
check "multi : identité du second refusée" oui "$(called 'identity not verified')"

new_case multi_share_both_present
# Les deux serveurs sont dans la table ARP : les deux partages doivent être montés.
set_neighbor aa:bb:cc:dd:ee:ff
CASE_SHARES=(
    "nfs|192.168.1.10|/share|${CASE_DIR}/mnt|nodev|aa:bb:cc:dd:ee:ff|"
    "cifs|192.168.1.10|public|${CASE_DIR}/mnt2|vers=3.0|aa:bb:cc:dd:ee:ff|"
)
write_config
rc="$(run_script apply)"
check "multi deux présents : code 0" 0 "${rc}"
check "multi deux présents : nfs monté" oui "$(called '192.168.1.10:/share')"
check "multi deux présents : cifs monté" oui "$(called '//192.168.1.10/public')"

new_case cifs_mount
neighbors aa:bb:cc:dd:ee:ff ""
CASE_SHARES=(
    "cifs|192.168.1.30|public|${CASE_DIR}/mnt|vers=3.0,iocharset=utf8|aa:bb:cc:dd:ee:ff|"
)
write_config
rc="$(run_script apply)"
check "cifs : code 0" 0 "${rc}"
check "cifs : montage en -t cifs" oui "$(called 'mount -t cifs')"
check "cifs : spécification //serveur/partage" oui "$(called '//192.168.1.30/public')"
check "cifs : options transmises" oui "$(called 'vers=3.0,iocharset=utf8')"

new_case cifs_credentials
neighbors aa:bb:cc:dd:ee:ff ""
CASE_CREDS="${CASE_DIR}/credentials-1"
printf 'username=u\npassword=p\n' > "${CASE_CREDS}"
chmod 600 "${CASE_CREDS}"
CASE_SHARES=(
    "cifs|192.168.1.30|public|${CASE_DIR}/mnt|vers=3.0|aa:bb:cc:dd:ee:ff|${CASE_CREDS}"
)
write_config
rc="$(run_script apply)"
check "cifs + identifiants : code 0" 0 "${rc}"
check "cifs + identifiants : option credentials" oui "$(called "credentials=${CASE_CREDS}")"

new_case cifs_credentials_no_duplicate
neighbors aa:bb:cc:dd:ee:ff ""
CASE_CREDS="${CASE_DIR}/credentials-1"
printf 'username=u\npassword=p\n' > "${CASE_CREDS}"
CASE_SHARES=(
    "cifs|192.168.1.30|public|${CASE_DIR}/mnt|vers=3.0,credentials=/deja/la|aa:bb:cc:dd:ee:ff|${CASE_CREDS}"
)
write_config
rc="$(run_script apply)"
check "cifs : pas de doublon credentials" 1 "$(called_count 'credentials=')"

new_case legacy_flat_config
# Ancien fichier de configuration (un seul partage NFS, variables à plat).
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
set_neighbor aa:bb:cc:dd:ee:ff
rc="$(run_script apply)"
check "ancien format : code 0" 0 "${rc}"
check "ancien format : montage" oui "$(called '192.168.1.10:/share')"

new_case bad_share_type
neighbors aa:bb:cc:dd:ee:ff ""
CASE_SHARES=("smb|192.168.1.10|/share|${CASE_DIR}/mnt|opts|aa:bb:cc:dd:ee:ff|")
write_config
rc="$(run_script apply)"
check "type inconnu : code 3" 3 "${rc}"
check "type inconnu : aucun montage" oui "$(not_called 'mount -t')"

new_case no_shares
CASE_SHARES=()
write_config
rc="$(run_script apply)"
check "aucun partage : code 122" 122 "${rc}"

# 48-52. Verbe `show` : lecture seule, tableau aligné, montages hors config.
new_case show_both_mounted
# Les options du noyau portent des marqueurs propres (rsize) : elles ne doivent
# pas apparaître, seules les options retenues par l'utilisateur sont affichées.
set_mount_table "${CASE_DIR}/mnt 192.168.1.10:/share nfs4 rw,rsize=1048576" \
                "${CASE_DIR}/mnt2 //192.168.1.30/public cifs rw,rsize=1048576"
CASE_SHARES=(
    "nfs|192.168.1.10|/share|${CASE_DIR}/mnt|nodev|aa:bb:cc:dd:ee:ff|"
    "cifs|192.168.1.30|public|${CASE_DIR}/mnt2|vers=3.0|aa:bb:cc:dd:ee:ff|"
)
write_config
out="$(run_show)"
check "show : en-tête" oui "$(contains "${out}" 'MOUNT POINT')"
check "show : partage nfs monté et sain" oui "$(contains "${out}" 'mounted, healthy')"
check "show : les deux points listés" oui "$(contains "${out}" "${CASE_DIR}/mnt2")"
check "show : aucun montage hors config" oui "$(lacks "${out}" 'not in configuration')"
check "show : options retenues (nfs)" oui "$(contains "${out}" 'nodev')"
check "show : options retenues (cifs)" oui "$(contains "${out}" 'vers=3.0')"
check "show : options du noyau masquées" oui "$(lacks "${out}" 'rsize')"

new_case show_one_unmounted
set_mount_table "${CASE_DIR}/mnt 192.168.1.10:/share nfs4 rw,nodev"
CASE_SHARES=(
    "nfs|192.168.1.10|/share|${CASE_DIR}/mnt|nodev|aa:bb:cc:dd:ee:ff|"
    "cifs|192.168.1.30|public|${CASE_DIR}/mnt2|vers=3.0|aa:bb:cc:dd:ee:ff|"
)
write_config
out="$(run_show)"
check "show : partage démonté signalé" oui "$(contains "${out}" 'not mounted')"
check "show : source configurée affichée" oui "$(contains "${out}" '//192.168.1.30/public')"

new_case show_foreign_mount
set_mount_table "${CASE_DIR}/mnt 192.168.1.10:/share nfs4 rw,nodev" \
                "/media/AUTRE //192.168.1.99/x cifs rw"
write_config
out="$(run_show)"
check "show : montage hors configuration signalé" oui "$(contains "${out}" 'mounted (not in configuration)')"

new_case show_unhealthy
set_mount_table "${CASE_DIR}/mnt 192.168.1.10:/share nfs4 rw,nodev"
stub stat 'printf "stat\n" >> "$CALLS"; exit 1'
stub ls 'printf "ls\n" >> "$CALLS"; exit 1'
write_config
out="$(run_show)"
check "show : montage muet signalé" oui "$(contains "${out}" 'mounted, NOT RESPONDING')"

# Chemin de configuration inutilisable : un répertoire. Déterministe, alors
# qu'un chmod 000 serait sans effet quand la suite tourne en root.
new_case show_config_unreadable
set_mount_table "/media/NAS 192.168.1.10:/share nfs4 rw,nodev"
rm -f "${CASE_DIR}/config"
mkdir -p "${CASE_DIR}/config"
out="$(run_show)"
check "show : montages réels affichés sans config" oui "$(contains "${out}" '/media/NAS')"
check "show : note sur la config illisible" oui "$(contains "${out}" 'Configuration not readable')"
rmdir "${CASE_DIR}/config"

# 53-54. Serveur muet : `umount` attend ses RPC, `umount -f` les abandonne. Ce
# repli ne doit être tenté que sur NFS (sur CIFS il n'a pas cet effet).
new_case unmount_forced_nfs
set_mount_table "${CASE_DIR}/mnt 192.168.1.10:/share nfs4 rw,hard"
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
stub umount 'printf "umount %s\n" "$*" >> "$CALLS"; case "$*" in *-f*) exit 0 ;; *) exit 1 ;; esac'
write_config
rc="$(run_script unmount)"
check "démontage forcé (nfs) : code 0" 0 "${rc}"
# Motifs ancrés sur la commande : le journal dit aussi « repli forcé (umount -f …) »
# et une recherche libre validerait le log au lieu de l'appel.
check "démontage forcé (nfs) : umount -f appelé" oui "$(called '^umount -f')"
check "démontage forcé (nfs) : pas de repli paresseux" oui "$(not_called '^umount .*-l')"

new_case unmount_no_force_cifs
set_mount_table "${CASE_DIR}/mnt //192.168.1.30/public cifs rw"
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
stub umount 'printf "umount %s\n" "$*" >> "$CALLS"; case "$*" in *-l*) exit 0 ;; *) exit 1 ;; esac'
write_config
rc="$(run_script unmount)"
check "cifs : pas de démontage forcé" oui "$(not_called '^umount -f')"
check "cifs : repli paresseux" oui "$(called '^umount .*-l')"
check "cifs : code 0" 0 "${rc}"

# 55-57. Réseaux autorisés par partage (8e champ) : un partage peut refuser le
# Wi-Fi domestique, en accepter plusieurs, ou ne dépendre que de la MAC.
new_case nets_reject
stub mountpoint 'printf "mountpoint\n" >> "$CALLS"; exit 0'
CASE_SHARES=("nfs|192.168.1.10|/share|${CASE_DIR}/mnt|nodev|aa:bb:cc:dd:ee:ff||AutreReseau")
write_config
rc="$(run_script apply)"
check "réseaux : SSID non autorisé, code 0" 0 "${rc}"
check "réseaux : SSID non autorisé, pas de montage" oui "$(not_called 'mount -t nfs')"
check "réseaux : SSID non autorisé, démontage" oui "$(called '^umount')"

new_case nets_accept_multi
neighbors aa:bb:cc:dd:ee:ff ""
CASE_SHARES=("nfs|192.168.1.10|/share|${CASE_DIR}/mnt|nodev|aa:bb:cc:dd:ee:ff||AutreReseau;Maison")
write_config
rc="$(run_script apply)"
check "réseaux : liste, code 0" 0 "${rc}"
check "réseaux : liste, montage" oui "$(called 'mount -t nfs')"

new_case nets_star_foreign_ssid
stub iw 'printf "iw %s\n" "$*" >> "$CALLS"; printf "Connected to aa:bb:cc:dd:ee:ff (on wlan0)\n\tSSID: CafeDuCoin\n"'
neighbors aa:bb:cc:dd:ee:ff ""
CASE_SHARES=("nfs|192.168.1.10|/share|${CASE_DIR}/mnt|nodev|aa:bb:cc:dd:ee:ff||*")
write_config
rc="$(run_script apply)"
check "réseaux : * ignore le SSID, code 0" 0 "${rc}"
check "réseaux : * montage si MAC confirmée" oui "$(called 'mount -t nfs')"

# 58-59. `show --json` : sortie machine pour un script ou une interface.
new_case show_json
set_mount_table "${CASE_DIR}/mnt 192.168.1.10:/share nfs4 rw,nodev"
CASE_CREDS="${CASE_DIR}/credentials-1"
printf 'username=u\npassword=p\n' > "${CASE_CREDS}"
CASE_SHARES=(
    "nfs|192.168.1.10|/share|${CASE_DIR}/mnt|nodev|aa:bb:cc:dd:ee:ff|"
    "cifs|192.168.1.30|public|${CASE_DIR}/mnt2|vers=3.0|aa:bb:cc:dd:ee:ff|${CASE_CREDS}"
)
write_config
out="$(run_show_json)"
if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "${out}" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        valid=oui
    else
        valid=non
    fi
else
    valid="$(contains "${out}" '"shares": [')"
fi
check "show --json : JSON valide" oui "${valid}"
check "show --json : config lisible" oui "$(contains "${out}" '"config_readable": true')"
check "show --json : partage monté" oui "$(contains "${out}" '"mounted": true')"
check "show --json : partage démonté" oui "$(contains "${out}" '"mounted": false')"
check "show --json : santé renseignée" oui "$(contains "${out}" '"healthy": true')"
check "show --json : chemin des identifiants absent" oui "$(lacks "${out}" 'credentials-1')"
check "show --json : état lisible" oui "$(contains "${out}" 'not mounted')"
check "show --json : options retenues" oui "$(contains "${out}" '"options": "nodev')"
check "show --json : options du noyau à part" oui "$(contains "${out}" '"runtime_options": "rw,nodev')"
check "show --json : options du noyau jamais en tête" oui "$(lacks "${out}" '"options": "rw,nodev')"

new_case show_json_config_unreadable
set_mount_table "/media/NAS 192.168.1.10:/share nfs4 rw,nodev"
rm -f "${CASE_DIR}/config"
mkdir -p "${CASE_DIR}/config"
out="$(run_show_json)"
check "show --json sans config : config_readable false" oui "$(contains "${out}" '"config_readable": false')"
check "show --json sans config : montage listé" oui "$(contains "${out}" '"mountpoint": "/media/NAS"')"
if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "${out}" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        valid=oui
    else
        valid=non
    fi
else
    valid="$(contains "${out}" '"foreign": [')"
fi
check "show --json sans config : JSON valide" oui "${valid}"
rmdir "${CASE_DIR}/config"

# 60-61. `--help` (en français) et alignement du tableau quand un chemin porte un
# accent : la largeur d'une colonne se compte en caractères, pas en octets.
new_case help_flag
out="$( PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_CONFIG="${CASE_DIR}/absent" \
        bash "${SCRIPT}" --help 2>&1 )"
rc=$?
check "--help : code 0" 0 "${rc}"
check "--help : décrit les verbes" oui "$(contains "${out}" 'nas-smartmount.sh show')"
check "--help : renvoie à la page de man" oui "$(contains "${out}" 'man 8 nas-smartmount')"
check "--help : ne lit pas la configuration" oui "$(lacks "${out}" 'Configuration missing')"

new_case version_flag
expected_version="$(sed -n 's/^VER=//p' "${SCRIPT}")"
out="$( PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_CONFIG="${CASE_DIR}/absent" \
        bash "${SCRIPT}" --version 2>&1 )"
rc=$?
check "--version : code 0" 0 "${rc}"
check "--version : une seule ligne" 1 "$(printf '%s\n' "${out}" | wc -l | tr -d ' ')"
check "--version : nom et version" oui "$(contains "${out}" "smart-mount ${expected_version}")"
check "--version : ne lit pas la configuration" oui "$(lacks "${out}" 'Configuration missing')"

new_case version_short_flag
expected_version="$(sed -n 's/^VER=//p' "${SCRIPT}")"
out="$( PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_CONFIG="${CASE_DIR}/absent" \
        bash "${SCRIPT}" -V 2>&1 )"
check "-V : même sortie" oui "$(contains "${out}" "smart-mount ${expected_version}")"

new_case show_alignment_accented
set_mount_table "${CASE_DIR}/Montréal 192.168.1.10:/share nfs4 rw,rsize=1" \
                "${CASE_DIR}/mnt2 //192.168.1.30/public cifs rw,rsize=1"
CASE_SHARES=(
    "nfs|192.168.1.10|/share|${CASE_DIR}/Montréal|nodev|aa:bb:cc:dd:ee:ff|"
    "cifs|192.168.1.30|public|${CASE_DIR}/mnt2|vers=3.0|aa:bb:cc:dd:ee:ff|"
)
write_config
out="$(run_show)"
if command -v python3 >/dev/null 2>&1; then
    aligned="$(printf '%s\n' "${out}" | python3 -c '
import sys
rows = [l for l in sys.stdin.read().splitlines()
        if l.startswith("nfs") or l.startswith("cifs")]
print("oui" if len(rows) == 2 and len({r.find("mounted") for r in rows}) == 1 else "non")
')"
else
    aligned=oui
fi
check "show : colonnes alignées avec un chemin accentué" oui "${aligned}"

# 65-68. La langue des messages suit la locale ; les valeurs de --json, non.
new_case lang_french_help
out="$( PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_CONFIG="${CASE_DIR}/absent" \
        LC_ALL=fr_FR.UTF-8 bash "${SCRIPT}" --help 2>&1 )"
check "locale fr : aide en français" oui "$(contains "${out}" 'Usage :')"
check "locale fr : verbes décrits en français" oui "$(contains "${out}" 'montages actifs')"

new_case lang_english_help
out="$( PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_CONFIG="${CASE_DIR}/absent" \
        LC_ALL=C.UTF-8 bash "${SCRIPT}" --help 2>&1 )"
check "locale en : aide en anglais" oui "$(contains "${out}" 'Usage:')"

new_case lang_french_log
set_neighbor aa:bb:cc:dd:ee:ff
rc="$( PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_CONFIG="${CASE_DIR}/config" \
        SMARTMOUNT_DEPS="" LC_ALL=fr_FR.UTF-8 bash "${SCRIPT}" apply >/dev/null 2>&1; echo $? )"
check "locale fr : code 0" 0 "${rc}"
check "locale fr : journal en français" oui "$(called 'montage attendu')"

new_case lang_french_show
set_mount_table "${CASE_DIR}/mnt 192.168.1.10:/share nfs4 rw,rsize=1"
write_config
out="$( PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_CONFIG="${CASE_DIR}/config" \
        SMARTMOUNT_DEPS="" LC_ALL=fr_FR.UTF-8 bash "${SCRIPT}" show 2>/dev/null )"
check "locale fr : en-tête traduit" oui "$(contains "${out}" 'POINT DE MONTAGE')"
check "locale fr : état traduit" oui "$(contains "${out}" 'monté, sain')"

new_case lang_json_stable
set_mount_table "${CASE_DIR}/mnt 192.168.1.10:/share nfs4 rw,rsize=1"
write_config
out="$( PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_CONFIG="${CASE_DIR}/config" \
        SMARTMOUNT_DEPS="" LC_ALL=fr_FR.UTF-8 bash "${SCRIPT}" show --json 2>/dev/null )"
check "--json : état non traduit" oui "$(contains "${out}" '"state": "mounted, healthy"')"
check "--json : pas de traduction française" oui "$(lacks "${out}" 'monté')"

new_case lang_override
out="$( PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_CONFIG="${CASE_DIR}/absent" \
        LC_ALL=fr_FR.UTF-8 SMARTMOUNT_LANG=en bash "${SCRIPT}" --help 2>&1 )"
check "SMARTMOUNT_LANG=en prime sur la locale" oui "$(contains "${out}" 'Usage:')"

# 69-72. `setup` : le questionnaire vit dans le script principal, et les fonctions
# fstab — les seules qui écrivent dans un fichier système — sont enfin couvertes.
new_case setup_requires_root
stub id 'printf "1000\n"'
# Verbe interactif : le refus doit être visible sur stderr, pas seulement au journal.
out="$( PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_CONFIG="${CASE_DIR}/config" \
        bash "${SCRIPT}" setup 2>&1 >/dev/null )"
rc=$?
check "setup : refus sans root (code 1)" 1 "${rc}"
check "setup : message sur stderr" oui "$(contains "${out}" 'requires root')"

new_case setup_needs_whiptail
stub id 'printf "0\n"'
bash_bin="$(command -v bash)"
out="$( PATH="${CASE_DIR}/bin" SMARTMOUNT_CONFIG="${CASE_DIR}/config" \
        "${bash_bin}" "${SCRIPT}" setup 2>&1 )"
rc=$?
check "setup : code 1 sans whiptail" 1 "${rc}"
check "setup : nomme la commande manquante" oui "$(contains "${out}" 'whiptail')"

new_case fstab_lookup_hit
printf '192.168.1.10:/share  /mnt/nfs  nfs4  rw,noauto  0 0\n' > "${CASE_DIR}/fstab"
out="$( SMARTMOUNT_FSTAB="${CASE_DIR}/fstab" SMARTMOUNT_CONFIG="${CASE_DIR}/config" \
        PATH="${CASE_DIR}/bin:${PATH}" bash -c \
        'source "$1" >/dev/null 2>&1; fstab_lookup nfs 192.168.1.10 /share' _ "${SCRIPT}" )"
check "fstab : point de montage par défaut" oui "$(contains "${out}" '/mnt/nfs')"
check "fstab : options par défaut" oui "$(contains "${out}" 'rw,noauto')"

new_case fstab_rewrite_noauto
printf '# commentaire\n192.168.1.10:/share  /mnt/nfs  nfs4  rw,relatime,x-systemd.automount  0 0\n192.168.1.20:/autre  /mnt/autre  nfs4  rw  0 0\n' > "${CASE_DIR}/fstab"
stub whiptail 'printf "whiptail %s\n" "$*" >> "$CALLS"; exit 0'
cat > "${CASE_DIR}/driver.sh" <<'DRV'
#!/usr/bin/env bash
records=("$@")
script="${records[0]}"
records=("${records[@]:1}")
set --
# shellcheck disable=SC1090
source "${script}" >/dev/null 2>&1
SHARES=("${records[@]}")
rewrite_fstab
DRV
chmod +x "${CASE_DIR}/driver.sh"
PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_FSTAB="${CASE_DIR}/fstab" \
    SMARTMOUNT_CONFIG="${CASE_DIR}/config" \
    bash "${CASE_DIR}/driver.sh" "${SCRIPT}" \
    "nfs|192.168.1.10|/share|/mnt/nfs|nodev|aa:bb:cc:dd:ee:ff|" >/dev/null 2>&1
fstab_now="$(cat "${CASE_DIR}/fstab")"
backups="$(find "${CASE_DIR}" -maxdepth 1 -name 'fstab.smart-mount.bak.*' | wc -l | tr -d ' ')"
check "fstab : noauto ajouté" oui "$(contains "${fstab_now}" 'rw,relatime,noauto')"
check "fstab : automount retiré" oui "$(lacks "${fstab_now}" 'x-systemd.automount')"
check "fstab : entrée non concernée intacte" oui "$(contains "${fstab_now}" '192.168.1.20:/autre  /mnt/autre  nfs4  rw')"
check "fstab : commentaire conservé" oui "$(contains "${fstab_now}" '# commentaire')"
check "fstab : une seule sauvegarde" 1 "${backups}"

new_case fstab_rewrite_untouched
printf '192.168.1.99:/autre  /mnt/autre  nfs4  rw  0 0\n' > "${CASE_DIR}/fstab"
before="$(cat "${CASE_DIR}/fstab")"
stub whiptail 'printf "whiptail %s\n" "$*" >> "$CALLS"; exit 0'
PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_FSTAB="${CASE_DIR}/fstab" \
    SMARTMOUNT_CONFIG="${CASE_DIR}/config" \
    bash "${CASE_DIR}/driver.sh" "${SCRIPT}" \
    "nfs|192.168.1.10|/share|/mnt/nfs|nodev|aa:bb:cc:dd:ee:ff|" >/dev/null 2>&1
after="$(cat "${CASE_DIR}/fstab")"
backups="$(find "${CASE_DIR}" -maxdepth 1 -name 'fstab.smart-mount.bak.*' | wc -l | tr -d ' ')"
check "fstab : aucune correspondance, fichier intact" oui "$(contains "${after}" "${before}")"
check "fstab : aucune sauvegarde inutile" 0 "${backups}"

# 78-80. nodev,nosuid,noexec : complétés sans doublon, quel que soit ce que
# l'utilisateur a saisi (ce sont des drapeaux du noyau, valables aussi en CIFS).
new_case safe_opts_empty
out="$( bash -c 'source "$1" >/dev/null 2>&1; ensure_safe_opts ""' _ "${SCRIPT}" 2>/dev/null )"
check "options vides : les trois ajoutés" "nodev,nosuid,noexec" "${out}"

new_case safe_opts_partial
out="$( bash -c 'source "$1" >/dev/null 2>&1; ensure_safe_opts "guest,vers=3.0,noexec"' _ "${SCRIPT}" 2>/dev/null )"
check "options partielles : complétées à la fin" "guest,vers=3.0,noexec,nodev,nosuid" "${out}"

new_case safe_opts_complete
out="$( bash -c 'source "$1" >/dev/null 2>&1; ensure_safe_opts "nodev,nosuid,noexec,uid=1000"' _ "${SCRIPT}" 2>/dev/null )"
check "options complètes : inchangées" "nodev,nosuid,noexec,uid=1000" "${out}"

# 81. Le questionnaire, exercé de bout en bout avec un whiptail simulé : c'est ce
# qui aurait attrapé un appel malformé (whiptail --title sans option de boîte
# affiche son propre mode d'emploi au lieu de la fenêtre).
new_case setup_runs_end_to_end
cat > "${CASE_DIR}/bin/whiptail" <<'STUB'
#!/bin/sh
printf 'WHIPTAIL: %s\n' "$*" >> "${CALLS}"
# Une réponse par type de boîte : whiptail écrit sur le descripteur 3.
case "$*" in
    *--msgbox*|*--yesno*|*--infobox*) printf 'window\n' >&2; exit 0 ;;
    *--menu*)                         printf 'nfs\n' >&3; exit 0 ;;
    *--inputbox*|*--passwordbox*)     printf '1\n' >&3; exit 0 ;;
esac
STUB
chmod +x "${CASE_DIR}/bin/whiptail"
stub id 'printf "0\n"'
: > "${CASE_DIR}/fstab"
printf '#!/bin/sh\nexit 0\n' > "${CASE_DIR}/bin/nmcli"; chmod +x "${CASE_DIR}/bin/nmcli"
out="$( PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_CONFIG="${CASE_DIR}/config" \
        SMARTMOUNT_FSTAB="${CASE_DIR}/fstab" SMARTMOUNT_LANG=en \
        bash "${SCRIPT}" setup 2>&1 )"
rc=$?
calls="$(cat "${CALLS}")"
check "questionnaire : code 0" 0 "${rc}"
check "questionnaire : configuration écrite" 1 "$([[ -f "${CASE_DIR}/config" ]] && echo 1 || echo 0)"
check "questionnaire : drapeaux durcis proposés" oui "$(contains "${calls}" 'nodev,nosuid,noexec')"
# Toute invocation doit porter une option de boîte en premier argument utile.
bad=0
while IFS= read -r line; do
    case "${line}" in
        'WHIPTAIL:'*)
            case "${line}" in
                *--msgbox*|*--yesno*|*--infobox*|*--inputbox*|*--passwordbox*|*--menu*) : ;;
                *) bad=$(( bad + 1 )) ;;
            esac
            ;;
    esac
done <<< "${calls}"
check "questionnaire : aucun appel whiptail malformé" 0 "${bad}"
# Les fenêtres vont sur stderr : rien du questionnaire ne doit atterrir sur stdout,
# qui est capturé par les appelants.
check "questionnaire : rien sur stdout" oui "$(lacks "${out}" 'WHIPTAIL:')"

# 82-86. Propriétaire local d'un partage CIFS : le compte SMB (username=) est une
# autre identité que uid=/gid=. Sans uid=, mount.cifs monte en uid=0 et seul root
# peut écrire dans le partage — constaté sur la machine.
new_case owner_opts_added
out="$( bash -c 'source "$1" >/dev/null 2>&1; ensure_owner_opts "guest,vers=3.0" 1000:1000' _ "${SCRIPT}" 2>/dev/null )"
check "propriétaire : uid et gid ajoutés" "guest,vers=3.0,uid=1000,gid=1000" "${out}"

new_case owner_opts_present
out="$( bash -c 'source "$1" >/dev/null 2>&1; ensure_owner_opts "uid=1000,gid=1000,nodev" 1000:1000' _ "${SCRIPT}" 2>/dev/null )"
check "propriétaire : aucun doublon" "uid=1000,gid=1000,nodev" "${out}"

new_case owner_opts_partial
out="$( bash -c 'source "$1" >/dev/null 2>&1; ensure_owner_opts "uid=0,guest" 1000:1000' _ "${SCRIPT}" 2>/dev/null )"
check "propriétaire : gid complété sans toucher uid" "uid=0,guest,gid=1000" "${out}"

new_case owner_opts_invalid
out="$( bash -c 'source "$1" >/dev/null 2>&1; ensure_owner_opts "guest" nawak' _ "${SCRIPT}" 2>/dev/null )"
check "propriétaire : saisie invalide ignorée" "guest" "${out}"

new_case owner_current
out="$( bash -c 'source "$1" >/dev/null 2>&1; SUDO_UID=1000 current_owner' _ "${SCRIPT}" 2>/dev/null )"
check "propriétaire : SUDO_UID honoré" "1000:1000" "${out}"

# Le chemin CIFS de bout en bout : menu -> cifs, propriétaire 1000:1000.
new_case setup_cifs_owner
cat > "${CASE_DIR}/bin/whiptail" <<'STUB'
#!/bin/sh
printf 'WHIPTAIL: %s\n' "$*" >> "${CALLS}"
case "$*" in
    *--menu*)                         printf 'cifs\n' >&3; exit 0 ;;
    *uid:gid*)                        printf '1000:1000\n' >&3; exit 0 ;;
    *file_mode:dir_mode*)             printf '0644:0755\n' >&3; exit 0 ;;
    *--inputbox*|*--passwordbox*)     printf '1\n' >&3; exit 0 ;;
    *--msgbox*|*--yesno*|*--infobox*) printf 'window\n' >&2; exit 0 ;;
esac
STUB
chmod +x "${CASE_DIR}/bin/whiptail"
stub id 'printf "0\n"'
: > "${CASE_DIR}/fstab"
out="$( PATH="${CASE_DIR}/bin:${PATH}" SMARTMOUNT_CONFIG="${CASE_DIR}/config" \
        SMARTMOUNT_FSTAB="${CASE_DIR}/fstab" SMARTMOUNT_LANG=en \
        bash "${SCRIPT}" setup 2>&1 )"
rc=$?
cfg="$(cat "${CASE_DIR}/config" 2>/dev/null)"
check "questionnaire cifs : code 0" 0 "${rc}"
check "questionnaire cifs : enregistrement cifs" oui "$(contains "${cfg}" 'cifs|')"
check "questionnaire cifs : uid/gid dans les options" oui "$(contains "${cfg}" 'uid=1000,gid=1000')"
check "questionnaire cifs : identifiants dans un fichier à part" oui "$(contains "${cfg}" 'credentials-1')"
check "questionnaire cifs : permissions écrites" oui "$(contains "${cfg}" 'file_mode=0644,dir_mode=0755')"
check "questionnaire cifs : actimeo proposé et écrit" oui "$(contains "${cfg}" 'actimeo=60')"

# 87-89. Permissions des fichiers montés : complétées comme le reste, sans doublon.
new_case modes_added
out="$( bash -c 'source "$1" >/dev/null 2>&1; ensure_mode_opts "guest,vers=3.0" 0644:0755' _ "${SCRIPT}" 2>/dev/null )"
check "modes : ajoutés" "guest,vers=3.0,file_mode=0644,dir_mode=0755" "${out}"

new_case modes_present
out="$( bash -c 'source "$1" >/dev/null 2>&1; ensure_mode_opts "file_mode=0600,dir_mode=0700" 0644:0755' _ "${SCRIPT}" 2>/dev/null )"
check "modes : aucun doublon" "file_mode=0600,dir_mode=0700" "${out}"

new_case modes_invalid
out="$( bash -c 'source "$1" >/dev/null 2>&1; ensure_mode_opts "guest" nawak' _ "${SCRIPT}" 2>/dev/null )"
check "modes : saisie invalide ignorée" "guest" "${out}"

# 90-92. L'état Wi-Fi fait partie de la décision : il s'affiche avec les montages.
new_case show_wifi_connected
set_mount_table "${CASE_DIR}/mnt 192.168.1.10:/share nfs4 rw,rsize=1"
write_config
out="$(run_show)"
check "show : ssid affiché, sans attendu" oui "$(contains "${out}" 'Wi-Fi wlan0: Maison')"
check "show : plus de mention d'attendu" oui "$(lacks "${out}" 'expected')"
check "show : le tableau suit la ligne wifi" oui "$(contains "${out}" 'MOUNT POINT')"

new_case show_wifi_disconnected
stub iw 'printf "iw %s\n" "$*" >> "$CALLS"; printf "Not connected.\n"'
write_config
out="$(run_show)"
check "show : wifi coupé signalé" oui "$(contains "${out}" 'not connected')"

new_case show_wifi_json
write_config
out="$(run_show_json)"
check "--json : bloc wifi" oui "$(contains "${out}" '"wifi": {"iface": "wlan0"')"
check "--json : état wifi non traduit" oui "$(contains "${out}" '"state": "connected"')"

# 93-95. Chaque partage a son propre réseau : le tableau le montre, --json donne le verdict.
new_case show_networks_column
set_mount_table "${CASE_DIR}/mnt 192.168.1.10:/share nfs4 rw,rsize=1"
CASE_SHARES=(
    "nfs|192.168.1.10|/share|${CASE_DIR}/mnt|nodev|aa:bb:cc:dd:ee:ff||Maison;ChezPapa"
    "nfs|192.168.1.20|/x|${CASE_DIR}/mnt2|nodev|11:22:33:44:55:66||Atelier"
)
write_config
out="$(run_show)"
check "show : réseaux propres au partage" oui "$(contains "${out}" 'Maison;ChezPapa')"
check "show : réseaux non autorisés listés aussi" oui "$(contains "${out}" 'Atelier')"
check "show : en-tête RÉSEAUX" oui "$(contains "${out}" 'NETWORKS')"

new_case show_networks_global
write_config
out="$(run_show)"
check "show : réseau hérité affiché avec (global)" oui "$(contains "${out}" 'Maison (global)')"

new_case show_networks_json
CASE_SHARES=(
    "nfs|192.168.1.10|/share|${CASE_DIR}/mnt|nodev|aa:bb:cc:dd:ee:ff||Maison"
    "nfs|192.168.1.20|/x|${CASE_DIR}/mnt2|nodev|11:22:33:44:55:66||Atelier"
)
write_config
out="$(run_show_json)"
check "--json : réseau autorisé" oui "$(contains "${out}" '"network_allowed": true')"
check "--json : réseau refusé" oui "$(contains "${out}" '"network_allowed": false')"

# 96-97. cache des attributs : ajouté quand il manque, jamais dupliqué.
new_case actimeo_added
out="$( bash -c 'source "$1" >/dev/null 2>&1; ensure_actimeo "guest,uid=1000"' _ "${SCRIPT}" 2>/dev/null )"
check "actimeo : ajouté" "guest,uid=1000,actimeo=60" "${out}"

new_case actimeo_present
out="$( bash -c 'source "$1" >/dev/null 2>&1; ensure_actimeo "guest,actimeo=30"' _ "${SCRIPT}" 2>/dev/null )"
check "actimeo : valeur existante respectée" "guest,actimeo=30" "${out}"

# ---------------------------------------------------------------- summary

printf '\n%d test(s) ok, %d échec(s)\n' "${PASS}" "${FAIL}"
[[ ${FAIL} -eq 0 ]]
