#!/usr/bin/env bash
set -euo pipefail
CONFIG_DIR="/etc/smart-mount"
CONFIG_FILE="${CONFIG_DIR}/config"
# Surchargeable pour les tests (même intention que SMARTMOUNT_CONFIG côté script).
FSTAB="${SMARTMOUNT_FSTAB:-/etc/fstab}"

# palette de couleurs whiptail
export NEWT_COLORS='
root=,black
window=white,black
border=white,black
title=yellow,black
textbox=white,black
acttextbox=black,yellow
entry=black,white
disentry=gray,black
button=black,lightgray
actbutton=black,cyan
compactbutton=white,black
listbox=white,black
actlistbox=black,yellow
checkbox=white,black
actcheckbox=black,yellow
'

main() {
    require_root
    require_cmd whiptail
    require_cmd nmcli
    require_cmd awk
    require_cmd ip

    DEFAULT_WIFI_NAME=""
    DEFAULT_WIFI_IFACE="wlan0"
    DEFAULT_LAN_IFACE="eth0"

    find_active_wifi_defaults
    find_active_lan_defaults
    find_lan_iface_fallback

    whiptail --title "smart-mount setup" --msgbox "smart-mount setup.

No /etc/fstab entry is needed: smart-mount does the mounting itself.
An existing entry only provides defaults, and gets the 'noauto' option if it
conflicts with a configured share (it must not mount at boot)." 14 78 || true

    COUNT="$(ask_count)"
    SHARES=()
    local i
    for (( i = 1; i <= COUNT; i++ )); do
        SHARES+=("$(ask_share "${i}")")
    done

    WIFI_NAME="$(ask_input "Network" "Wi-Fi SSID from which the shares are reachable" "${DEFAULT_WIFI_NAME}")"
    WIFI_IFACE="$(ask_input "Network" "Wi-Fi interface" "${DEFAULT_WIFI_IFACE}")"
    LAN_IFACE="$(ask_input "Network" "Ethernet/LAN interface" "${DEFAULT_LAN_IFACE}")"

    write_config
    rewrite_fstab
}

# **************************************************************************************************************************************

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Commande requise introuvable: $1" >&2
        exit 1
    }
}
# **************************************************************************************************************************************

require_root() {
    local root
    root=$(id -u)
    if [[ ${EUID:-${root}} -ne 0 ]]; then
        echo "Ce script doit être lancé en root." >&2
        exit 1
    fi
}
# **************************************************************************************************************************************

# Un partage est stocké comme sept champs séparés par '|' :
#   type|serveur|partage|point de montage|options|mac|fichier d'identifiants
share_spec() { # share_spec <type> <serveur> <partage>
    case "${1:-}" in
        cifs) printf '//%s/%s' "${2:-}" "${3#/}" ;;
        *)    printf '%s:%s' "${2:-}" "${3:-}" ;;
    esac
}
# **************************************************************************************************************************************

# Une entrée fstab existante, jamais obligatoire : elle sert de valeurs par défaut.
fstab_lookup() { # fstab_lookup <type> <serveur> <partage> -> "point|options"
    local spec
    spec="$(share_spec "$1" "$2" "$3")"
    awk -v spec="${spec}" '
        /^[[:space:]]*#/ || NF < 4 { next }
        $1 == spec { print $2 "|" $4; exit }' "${FSTAB}"
}
# **************************************************************************************************************************************

fstab_first_server() { # serveur de la première entrée fstab du type demandé
    awk -v want="${1:-nfs}" '
        /^[[:space:]]*#/ || NF < 4 { next }
        want == "cifs" && ($3 == "cifs" || $3 == "smb3" || $3 == "smbfs") {
            s = $1; sub(/^\/\//, "", s); sub(/\/.*/, "", s); print s; exit
        }
        want != "cifs" && ($3 == "nfs" || $3 == "nfs4") {
            s = $1; sub(/:.*/, "", s); print s; exit
        }' "${FSTAB}"
}
# **************************************************************************************************************************************

find_active_wifi_defaults() {
    local wifi_iface='' ssid=''
    # NAME dans `connection show` est le nom du profil de connexion, pas le
    # SSID : le script de montage compare des SSID, on prend donc le SSID réel
    # du lien actif (iw, à défaut la liste de scan de nmcli).
    wifi_iface="$(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null \
        | awk -F: '$2=="wifi" && $3=="connected"{print $1; exit}')" || true

    if [[ -z "${wifi_iface}" ]]; then
        return 0
    fi

    DEFAULT_WIFI_IFACE="${wifi_iface}"

    if command -v iw >/dev/null 2>&1; then
        ssid="$(iw dev "${wifi_iface}" link 2>/dev/null \
            | sed -n 's/^[[:space:]]*SSID:[[:space:]]*//p' | head -n1)" || true
    fi

    if [[ -z "${ssid}" ]]; then
        ssid="$(LC_ALL=C nmcli -t -f ACTIVE,SSID device wifi list ifname "${wifi_iface}" 2>/dev/null \
            | awk -F: '$1=="yes"{ sub(/^[^:]*:/, ""); print; exit }')" || true
        # nmcli échappe les ':' d'un SSID en mode -t : on écrit le SSID réel.
        ssid="${ssid//\\:/:}"
    fi

    if [[ -n "${ssid}" ]]; then
        DEFAULT_WIFI_NAME="${ssid}"
    fi
}
# **************************************************************************************************************************************

find_active_lan_defaults() {
    local lan_iface
    lan_iface="$(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null | awk -F: '$2=="ethernet" && $3=="connected"{print $1; exit}')"
    if [[ -n "${lan_iface}" ]]; then
        DEFAULT_LAN_IFACE="${lan_iface}"
    fi
}
# **************************************************************************************************************************************

find_lan_iface_fallback() {
    local class iface
    for iface in /sys/class/net/*; do
        iface="${iface##*/}"
        [[ "${iface}" == "lo" ]] && continue
        [[ -d "/sys/class/net/${iface}/wireless" ]] && continue
        class=$(readlink -f "/sys/class/net/${iface}")
        [[ "${class}" == *"/virtual/"* ]] && continue
        break
    done
    if [[ -n "${iface:-}" ]] && [[ "${DEFAULT_LAN_IFACE}" = "eth0" ]]; then
        DEFAULT_LAN_IFACE="${iface}"
    fi
}
# **************************************************************************************************************************************

# Lit la MAC dans la table ARP (couche 2 : le montage n'a rien à voir).
# La table est consultée d'abord : elle suffit quand le serveur a parlé
# récemment, et un serveur qui filtre l'ICMP reste détectable. Le ping n'est
# qu'un secours.
arp_mac_of() {
    local ip="$1"
    local out

    out="$(ip neigh show "${ip}" 2>/dev/null)" || return 0

    # `ip neigh show <ip>` imprime « IP dev IF lladdr MAC ETAT » ; selon les
    # versions et les filtres, la position de la MAC varie. On se place donc
    # après le mot-clé, jamais sur un numéro de champ.
    printf '%s\n' "${out}" \
        | awk '{ for (i = 1; i < NF; i++) if ($i == "lladdr") { print $(i + 1); exit } }'
    return 0
}

get_server_mac() {
    local ip="$1"
    local mac=''

    mac="$(arp_mac_of "${ip}")"

    if [[ -z "${mac}" ]]; then
        ping -c 2 -i 0.2 -W 1 "${ip}" >/dev/null 2>&1 || true
        mac="$(arp_mac_of "${ip}")"
    fi

    if [[ -n "${mac}" ]]; then
        printf '%s\n' "${mac}"
    fi
    return 0
}
# **************************************************************************************************************************************

# Les caractères refusés casseraient le fichier de configuration, qui est un
# script bash lu en root : c'est aussi ce qui ferme l'injection par valeur saisie.
safe_field() {
    local value="${1:-}"
    local bad=''

    for bad in '|' '"' '$' '`' "\\"; do
        case "${value}" in
            *"${bad}"*) return 1 ;;
        esac
    done

    return 0
}

ask_input() {
    local title="$1"
    local prompt="$2"
    local default_value="$3"
    local result

    while :; do
        result="$(whiptail --title "${title}" --inputbox "${prompt}" 10 78 "${default_value}" 3>&1 1>&2 2>&3)" || exit 1

        if safe_field "${result}"; then
            printf '%s' "${result}"
            return 0
        fi

        whiptail --title "${title}" --msgbox "Forbidden characters: | \" \$ \` \\

The configuration file is a bash script read as root: these characters are
dangerous there. Please enter another value." 12 78 || true
        default_value="${result}"
    done
}

ask_password() {
    local title="$1"
    local prompt="$2"
    local result

    result="$(whiptail --title "${title}" --passwordbox "${prompt}" 10 78 3>&1 1>&2 2>&3)" || exit 1
    printf '%s' "${result}"
}

ask_menu() {
    local title="$1"
    local prompt="$2"
    shift 2
    local result

    result="$(whiptail --title "${title}" --menu "${prompt}" 15 78 4 "$@" 3>&1 1>&2 2>&3)" || exit 1
    printf '%s' "${result}"
}
# **************************************************************************************************************************************

ask_count() {
    local n
    n="$(ask_input "Shares" "How many shares do you want to configure? (1-9)" "1")"

    while [[ ! "${n}" =~ ^[1-9]$ ]]; do
        n="$(ask_input "Shares" "Invalid number. How many shares? (1-9)" "1")"
    done

    printf '%s' "${n}"
}
# **************************************************************************************************************************************

default_mount_for() { # default_mount_for <partage> -> /media/<dernier élément>
    local base="${1##*/}"
    [[ -n "${base}" ]] || base="share"
    printf '/media/%s' "${base}"
}
# **************************************************************************************************************************************

# Identifiants CIFS : jamais dans la configuration ni sur la ligne de commande,
# mais dans un fichier 0600 référencé par l'option credentials=.
ask_cifs_creds() { # ask_cifs_creds <numéro> <serveur> ; -> chemin du fichier ou vide
    local num="$1"
    local server="$2"
    local user='' pass='' domain='' file=''

    user="$(ask_input "Share ${num}" "SMB user (leave empty for guest access)" "")"
    if [[ -z "${user}" ]]; then
        return 0
    fi

    pass="$(ask_password "Share ${num}" "Password for ${user} on ${server}")"
    domain="$(ask_input "Share ${num}" "Domain / workgroup (optional)" "")"

    file="${CONFIG_DIR}/credentials-${num}"
    umask 077
    {
        printf 'username=%s\n' "${user}"
        printf 'password=%s\n' "${pass}"
        if [[ -n "${domain}" ]]; then
            printf 'domain=%s\n' "${domain}"
        fi
    } > "${file}"
    chmod 600 "${file}"

    printf '%s' "${file}"
}
# **************************************************************************************************************************************

ask_share() { # ask_share <numéro> -> "type|serveur|partage|point|options|mac|creds"
    local num="$1"
    local type server path mount opts mac creds=''
    local default_server='' defaults='' mount_default='' opts_default=''

    type="$(ask_menu "Share ${num}" "Type of share ${num}" \
        "nfs" "NFS (Linux, NAS)" \
        "cifs" "CIFS / SMB (Windows, NAS)")"

    default_server="$(fstab_first_server "${type}")"

    if [[ "${type}" = "cifs" ]]; then
        server="$(ask_input "Share ${num}" "SMB server name or IP address" "${default_server}")"
        path="$(ask_input "Share ${num}" "SMB share name (e.g. public)" "")"
        opts_default="vers=3.0,iocharset=utf8,nodev,nosuid,noexec"
    else
        server="$(ask_input "Share ${num}" "NFS server IP address" "${default_server}")"
        path="$(ask_input "Share ${num}" "Exported path (e.g. /volume1/share)" "")"
        opts_default="nodev,nosuid,noexec,noatime,lazytime"
    fi

    # Une entrée fstab qui correspond déjà fournit le point de montage et les
    # options : c'est le seul rôle de fstab dans ce questionnaire.
    defaults="$(fstab_lookup "${type}" "${server}" "${path}")"
    mount_default="${defaults%%|*}"
    if [[ -n "${defaults}" ]]; then
        opts_default="${defaults#*|}"
    fi
    if [[ -z "${mount_default}" ]]; then
        mount_default="$(default_mount_for "${path}")"
    fi

    mount="$(ask_input "Share ${num}" "Mount point" "${mount_default}")"
    opts="$(ask_input "Share ${num}" "Mount options" "${opts_default}")"

    if [[ "${type}" = "cifs" ]]; then
        creds="$(ask_cifs_creds "${num}" "${server}")"
    fi

    mac="$(get_server_mac "${server}")"
    mac="$(ask_input "Share ${num}" "MAC address of ${server} (mandatory: without it the share is never mounted)" "${mac}")"

    if [[ -z "${mac}" ]]; then
        whiptail --title "Share ${num}" --msgbox "No MAC address detected for ${server}.

The server did not answer: its MAC address cannot be read. This share will NOT
be mounted until a target MAC is configured, over Wi-Fi as well as Ethernet.

To find it:
  - while the server is reachable:  ip neigh show ${server}
  - or in the NAS administration interface, or in the router's DHCP leases

Then fill in the 6th field of that share in ${CONFIG_FILE}
(or re-run: sudo make install)." 22 78 || true
    fi

    # 8e champ : réseaux autorisés pour CE partage. Vide = le SSID global, ce qui
    # reproduit exactement le comportement d'avant.
    nets="$(ask_input "Share ${num}" "Accepted networks, separated by ; (empty = the global SSID, * = any)" "")"

    printf '%s|%s|%s|%s|%s|%s|%s|%s' "${type}" "${server}" "${path}" "${mount}" "${opts}" "${mac}" "${creds}" "${nets}"
}
# **************************************************************************************************************************************

write_config() {
    local backup='no'
    local backup_file=''
    local share=''

    mkdir -p "${CONFIG_DIR}"

    if [[ -f "${CONFIG_FILE}" ]]; then
        backup_file="${CONFIG_FILE}.bak.$(date +%d_%m_%Y-%H.%M.%S)"
        cp -a "${CONFIG_FILE}" "${backup_file}"
        backup='yes'
    fi

    {
        printf '# smart-mount — %s\n' "$(date '+%Y-%m-%d %H:%M')"
        printf '#\n'
        printf '# Links: a single home network.\n'
        printf 'WIFI_NAME="%s"\n' "${WIFI_NAME}"
        printf 'WIFI_IFACE="%s"\n' "${WIFI_IFACE}"
        printf 'LAN_IFACE="%s"\n' "${LAN_IFACE}"
        printf '\n'
        printf '# Shares: one record per share, fields separated by |\n'
        printf '#   type|server|share|mount point|options|mac|credentials|networks\n'
        printf 'SHARES=(\n'
        for share in "${SHARES[@]}"; do
            printf '  "%s"\n' "${share}"
        done
        printf ')\n'
    } > "${CONFIG_FILE}"

    # 0640 root:root : identique à 0600 pour tout autre utilisateur, mais un
    # groupe dédié (SMARTMOUNT_GROUP=smartmount) permet à `show` de lire la
    # configuration sans sudo, sans donner accès aux identifiants CIFS qui sont
    # dans des fichiers séparés.
    chmod 0640 "${CONFIG_FILE}"
    chgrp "${SMARTMOUNT_GROUP:-root}" "${CONFIG_FILE}" 2>/dev/null || true

    if [[ "${backup}" = "yes" ]]; then
        whiptail --title "smart-mount setup" --msgbox "Configuration written to ${CONFIG_FILE}

Previous configuration kept in:
${backup_file}" 12 78 || true
    else
        whiptail --title "smart-mount setup" --msgbox "Configuration written to ${CONFIG_FILE}" 10 78 || true
    fi
}
# **************************************************************************************************************************************

# fstab : jamais lu pour monter, jamais utilisé pour un montage ou un démontage.
# On neutralise seulement les entrées qui feraient double emploi avec smart-mount
# (montage au démarrage derrière son dos), en une seule passe et avec sauvegarde.
rewrite_fstab() {
    local pairs=''
    local share='' type='' server='' path='' mount=''
    local remote=''
    local tmp_file='' backup_file=''

    for share in "${SHARES[@]}"; do
        IFS='|' read -r type server path mount _ _ _ <<< "${share}"
        remote="$(share_spec "${type}" "${server}" "${path}")"
        pairs="${pairs}${remote}|${mount}"$'\n'
    done

    if [[ -z "${pairs}" ]]; then
        return 0
    fi

    tmp_file="$(mktemp)"
    awk -v pairs="${pairs}" '
    function trim(s) {
        sub(/^[[:space:]]+/, "", s)
        sub(/[[:space:]]+$/, "", s)
        return s
    }

    function rebuild_opts(opts,    n,i,a,out,seen_noauto) {
        n = split(opts, a, ",")
        out = ""
        seen_noauto = 0

        for (i = 1; i <= n; i++) {
            a[i] = trim(a[i])
            if (a[i] == "" || a[i] == "x-systemd.automount") {
                continue
            }
            if (a[i] == "noauto") {
                seen_noauto = 1
            }
            if (out == "") out = a[i]
            else out = out "," a[i]
        }

        if (!seen_noauto) {
            if (out == "") out = "noauto"
            else out = out ",noauto"
        }

        return out
    }

    BEGIN {
        k = 0
        n = split(pairs, lines, "\n")
        for (i = 1; i <= n; i++) {
            if (lines[i] == "") continue
            c = index(lines[i], "|")
            if (c == 0) continue
            k++
            wremote[k] = substr(lines[i], 1, c - 1)
            wmount[k] = substr(lines[i], c + 1)
        }
    }

    /^[[:space:]]*#/ || NF < 4 {
        print
        next
    }

    {
        for (j = 1; j <= k; j++) {
            if ($1 == wremote[j] && $2 == wmount[j]) {
                $4 = rebuild_opts($4)
                break
            }
        }
        print
    }
    ' "${FSTAB}" > "${tmp_file}"

    if cmp -s "${FSTAB}" "${tmp_file}"; then
        rm -f "${tmp_file}"
        return 0
    fi

    backup_file="${FSTAB}.smart-mount.bak.$(date +%d_%m_%Y-%H.%M.%S)"
    cp -a "${FSTAB}" "${backup_file}"
    cp -f "${tmp_file}" "${FSTAB}"
    rm -f "${tmp_file}"

    whiptail --title "smart-mount setup" --msgbox "One or more ${FSTAB} entries matching your shares received the 'noauto' option (and lost 'x-systemd.automount').

They will no longer mount at boot: smart-mount does it, from the network hook
and the timer.

Backup: ${backup_file}" 14 78 || true
}
# **************************************************************************************************************************************
# **************************************************************************************************************************************

main "$@"
