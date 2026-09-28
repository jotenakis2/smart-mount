#!/usr/bin/env bash

# shellcheck disable=SC2034
VER=0.9
readonly CONFIG="/etc/smart-mount/config"
readonly SCRIPT_NAME="${0##*/}"
trap 'trap_err "$?"' ERR

#-helpers --------------------------------------------------------------------------------------------
log_info() {
	# shellcheck disable=SC2015
    [[ -t 1 ]] && echo "$*" || logger -t "${SCRIPT_NAME}" -p user.info -- "$*"
}

log_notice() {
	# shellcheck disable=SC2015
    [[ -t 1 ]] && echo "$*" || logger -t "${SCRIPT_NAME}" -p user.notice -- "$*"
}

log_warning() {
	# shellcheck disable=SC2015
    [[ -t 1 ]] && echo "$*" || logger -t "${SCRIPT_NAME}" -p user.warning -- "$*"
}

log_err() {
	# shellcheck disable=SC2015
    [[ -t 1 ]] && echo "$*" || logger -t "${SCRIPT_NAME}" -p user.err -- "$*"
}

trap_err() {
    local exit_code="${1}"
    local str=''
    case "${exit_code}" in
    	1)   str="Error mounting ${NFS_SERVER_IP}:${NFS_SHAREDPATH} in ${MOUNT_POINT}";;
    	2)   str="Error unmounting ${MOUNT_POINT}";;
    	3)   str="${SCRIPT_NAME} syntax error - valid usage is : ${SCRIPT_NAME} {mount|unmount}" ;;
    	122) str="Missing config file (${CONFIG})";;
    	127) str="Error ping test (${NFS_SERVER_IP}) before mounting ${NFS_SERVER_IP}:${NFS_SHAREDPATH} in ${MOUNT_POINT}";;
    	*)   str="Unknown error";;
    esac
    log_err "${str}"
}

#-------------------------------------------------------------------------------------------------



mount_nfs() {
    local nfs_spec="${NFS_SERVER_IP}:${NFS_SHAREDPATH}"

    if [[ ! -d "${MOUNT_POINT}" ]]; then
        mkdir -p -- "${MOUNT_POINT}" && log_info "Point de montage crée: ${MOUNT_POINT}"
    fi

    if mountpoint -q -- "${MOUNT_POINT}"; then
        log_notice "Deja monté: ${MOUNT_POINT}"
        return 0
    fi
    
	if ping -i 0.2 -w 1 "${NFS_SERVER_IP}" &>/dev/null; then
		if mount -t nfs -o "${NFS_OPTS}" -- "${nfs_spec}" "${MOUNT_POINT}" &>/dev/null; then
			log_info "Montage réussi: ${nfs_spec} -> ${MOUNT_POINT}"
			return 0
		else
			return 1
		fi
	else
		return 127
	fi
}

unmount_nfs() {
    if mountpoint -q -- "${MOUNT_POINT}"; then
        if umount -- "${MOUNT_POINT}" &>/dev/null; then
        	log_info "Démontage réussi: ${MOUNT_POINT}"
        	return 0
        else
        	return 2
        fi
    else
        log_notice "OK, déjà démonté: ${MOUNT_POINT}"
        return 0
    fi
}

get_current_wifi() {
    if command -v nmcli >/dev/null 2>&1; then
        LC_ALL=C nmcli -t -f ACTIVE,SSID dev wifi | awk -F: '$1 == "yes" { print $2; exit }'
        return 0
    fi

    if command -v iwgetid >/dev/null 2>&1; then
        iwgetid -r
        return 0
    fi

    return 1
}

main() {
    local action="${1:-}"
	current_wifi=""
	current_wifi="$(get_current_wifi || true)"
	
	if [[ -f "${CONFIG}" ]]; then
		# shellcheck disable=SC1090
		source "${CONFIG}" 
	else
		return 122
	fi
	
    case "${action}" in
        mount)   
			if [[ "${current_wifi:-}" == "${WIFI_NAME}" ]]; then
				mount_nfs
			else
				log_info "WiFi non ciblé (${current_wifi} ≠ ${WIFI_NAME}), pas de NFS à monter"
				return 0
			fi
			;;
        unmount) unmount_nfs ;;
        *)       return 3 ;;
    esac
}

main "$@"
