#!/usr/bin/env bash
set -euo pipefail
CONFIG_DIR="/etc/smart-mount"
CONFIG_FILE="${CONFIG_DIR}/config"

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

    DEFAULT_NFS_SERVER_IP=""
    DEFAULT_NFS_SHAREDPATH=""
    DEFAULT_MOUNT_POINT="/media/NAS"
    DEFAULT_NFS_OPTS="nodev,nosuid,noexec,noatime,lazytime"

    DEFAULT_WIFI_NAME=""
    DEFAULT_WIFI_IFACE="wlan0"

    DEFAULT_NFS_SERVER_MAC=""
    DEFAULT_LAN_IFACE="eth0"

    find_fstab_nfs_defaults
    find_active_wifi_defaults
    find_active_lan_defaults
	find_lan_iface_fallback

    whiptail --title "smart-mount setup" --msgbox "Configuration de smart-mount.\n\nLes valeurs par défaut sont récupérées depuis /etc/fstab et la connexion Wi-Fi active quand c'est possible." 12 78

    NFS_SERVER_IP="$(ask_input "NFS" "Adresse IP du serveur NFS" "${DEFAULT_NFS_SERVER_IP}")"
    NFS_SHAREDPATH="$(ask_input "NFS" "Chemin exporté par le serveur NFS" "${DEFAULT_NFS_SHAREDPATH}")"
    MOUNT_POINT="$(ask_input "NFS" "Point de montage local" "${DEFAULT_MOUNT_POINT}")"
    NFS_OPTS="$(ask_input "NFS" "Options de montage NFS" "${DEFAULT_NFS_OPTS}")"

    WIFI_NAME="$(ask_input "WIFI" "Nom du réseau Wi-Fi (SSID)" "${DEFAULT_WIFI_NAME}")"
    WIFI_IFACE="$(ask_input "WIFI" "Interface Wi-Fi" "${DEFAULT_WIFI_IFACE}")"

	# shellcheck disable=SC2310
	DEFAULT_NFS_SERVER_MAC="$(get_nfs_server_mac "${NFS_SERVER_IP}" || true)"
    NFS_SERVER_MAC="$(ask_input "LAN" "Adresse MAC du serveur NFS" "${DEFAULT_NFS_SERVER_MAC}")"
    LAN_IFACE="$(ask_input "LAN" "Interface LAN" "${DEFAULT_LAN_IFACE}")"

    mkdir -p "${CONFIG_DIR}"
	local backup="no"
	local backup_file
	if [[ -f "${CONFIG_FILE}" ]]; then
		backup_file="${CONFIG_FILE}.bak.$(date +%d_%m_%Y-%H.%M.%S)"
		cp -a "${CONFIG_FILE}" "${backup_file}"
		backup="yes"
	fi
	
    cat > "${CONFIG_FILE}" <<EOF
# NFS
NFS_SERVER_IP="${NFS_SERVER_IP}"
NFS_SHAREDPATH="${NFS_SHAREDPATH}"
MOUNT_POINT="${MOUNT_POINT}"
NFS_OPTS="${NFS_OPTS}"

# WIFI
WIFI_NAME="${WIFI_NAME}"
WIFI_IFACE="${WIFI_IFACE}"

# LAN
NFS_SERVER_MAC="${NFS_SERVER_MAC}"
LAN_IFACE="${LAN_IFACE}"
EOF

    chmod 600 "${CONFIG_FILE}"
	if [[ "${backup}" = "no" ]]; then
    	whiptail --title "smart-mount setup" --msgbox "Configuration enregistrée dans ${CONFIG_FILE}" 10 78
    elif [[ "${backup}" = "yes" ]]; then
        whiptail --title "smart-mount setup" --msgbox "Configuration enregistrée dans ${CONFIG_FILE}\n\nPrécédente configuration enregistrée dans ${backup_file}." 10 78
	fi
	
	sanitize_fstab_nfs_entry

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

find_fstab_nfs_defaults() {
    local line remote mountpoint opts server share
    line="$(awk '
        $0 !~ /^[[:space:]]*#/ &&
        NF >= 4 &&
        ($3 == "nfs" || $3 == "nfs4") {
            print $1 "|" $2 "|" $3 "|" $4
            exit
        }
    ' /etc/fstab)"

    if [[ -n "${line}" ]]; then
        IFS='|' read -r remote mountpoint _ opts <<< "${line}"
        server="${remote%%:*}"
        share="${remote#*:}"

        DEFAULT_NFS_SERVER_IP="${server}"
        DEFAULT_NFS_SHAREDPATH="${share}"
        DEFAULT_MOUNT_POINT="${mountpoint}"
        DEFAULT_NFS_OPTS="${opts}"
    fi
}
# **************************************************************************************************************************************

find_active_wifi_defaults() {
    local wifi_line wifi_name wifi_iface
    wifi_line="$(nmcli -t -f NAME,DEVICE,TYPE connection show --active 2>/dev/null | awk -F: '$3=="802-11-wireless"{print; exit}')"

    if [[ -n "${wifi_line}" ]]; then
        IFS=':' read -r wifi_name wifi_iface _ <<< "${wifi_line}"
        DEFAULT_WIFI_NAME="${wifi_name}"
        DEFAULT_WIFI_IFACE="${wifi_iface}"
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
	local class
    for iface in /sys/class/net/*; do
        iface="${iface##*/}"
        [[ "${iface}" == "lo" ]] && continue
        [[ -d "/sys/class/net/${iface}/wireless" ]] && continue
        class=$(readlink -f "/sys/class/net/${iface}")
        [[ "${class}" == *"/virtual/"* ]] && continue
        break
    done
    if [[ -n "${iface}" ]] && [[ "${DEFAULT_LAN_IFACE}" = "eth0" ]]; then
        DEFAULT_LAN_IFACE="${iface}"
    fi
}
# **************************************************************************************************************************************

get_nfs_server_mac() {
    local ip="$1"
    local mac

    # Essayer de remplir le cache ARP
    ping -c 1 -W 1 "${ip}" >/dev/null 2>&1 || return 1

    # Récupérer la MAC via ARP
    mac="$(ip -o neigh show "${ip}" | awk '$6 == "REACHABLE" || $6 == "STALE" {print $5}')" || return 1

    [[ -n "${mac}" ]] && printf '%s\n' "${mac}" || return 1
}
# **************************************************************************************************************************************

ask_input() {
    local title="$1"
    local prompt="$2"
    local default_value="$3"
    local result

    result="$(whiptail --title "${title}" --inputbox "${prompt}" 10 78 "${default_value}" 3>&1 1>&2 2>&3)" || exit 1

    printf '%s' "${result}"
}
# **************************************************************************************************************************************

sanitize_fstab_nfs_entry() {
    local wanted_remote="${NFS_SERVER_IP}:${NFS_SHAREDPATH}"
    local need_change=0
    local backup_file tmp_file

    need_change="$(awk -v wanted_remote="${wanted_remote}" -v wanted_mount="${MOUNT_POINT}" '
    /^[[:space:]]*#/ || NF < 4 { next }
    ($3 == "nfs" || $3 == "nfs4") && $1 == wanted_remote && $2 == wanted_mount {
        has_noauto = ($4 ~ /(^|,)noauto(,|$)/)
        has_automount = ($4 ~ /(^|,)x-systemd\.automount(,|$)/)
        if (has_automount || !has_noauto) {
            print 1
            exit
        }
    }
    END {
        if (NR >= 0) print 0
    }' /etc/fstab | head -n1)"

    [[ "${need_change}" == "1" ]] || return 0

    backup_file="/etc/fstab.smart-mount.bak.$(date +%d_%m_%Y-%H.%M.%S)"
    tmp_file="$(mktemp)"

    awk -v wanted_remote="${wanted_remote}" -v wanted_mount="${MOUNT_POINT}" '
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

    /^[[:space:]]*#/ || NF < 4 {
        print
        next
    }

    {
        if (($3 == "nfs" || $3 == "nfs4") && $1 == wanted_remote && $2 == wanted_mount) {
            $4 = rebuild_opts($4)
        }
        print
    }
    ' /etc/fstab > "${tmp_file}"

    cp -a /etc/fstab "${backup_file}"
    cp -f "${tmp_file}" /etc/fstab
    rm -f "${tmp_file}"

    whiptail --title "smart-mount setup" \
        --msgbox "Entrée fstab ajustée pour éviter un conflit avec smart-mount.\n\nSauvegarde: ${backup_file}" \
        12 78
}
# **************************************************************************************************************************************
# **************************************************************************************************************************************

main "$@"
