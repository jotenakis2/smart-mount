#!/usr/bin/env bash
set -euo pipefail

VER=0.6
readonly CONFIG="/etc/smart-mount/config"
if [[ -f "${CONFIG}" ]]; then
	source "${CONFIG}" 
else
	echo "config manquante"
	exit 1
fi

readonly SCRIPT_NAME="nfs-smartmount"

log_info() {
    logger -t "${SCRIPT_NAME}" -p user.info -- "$*"
}

log_notice() {
    logger -t "${SCRIPT_NAME}" -p user.notice -- "$*"
}

log_warning() {
    logger -t "${SCRIPT_NAME}" -p user.warning -- "$*"
}

log_err() {
    logger -t "${SCRIPT_NAME}" -p user.err -- "$*"
}

trap_err() {
    local exit_code="${1}"
    local line_number="${2}"
    log_err "Erreur ligne ${line_number}, code ${exit_code}"
}

trap 'trap_err "$?" "${LINENO}"' ERR

mount_nfs() {
    local nfs_spec="${NFS_SERVER_IP}:${NFS_SHAREDPATH}"

    if [[ ! -d "${MOUNT_POINT}" ]]; then
        mkdir -p -- "${MOUNT_POINT}"
        log_info "Point de montage cree: ${MOUNT_POINT}"
    fi

    if mountpoint -q -- "${MOUNT_POINT}"; then
        log_notice "Deja monte: ${MOUNT_POINT}"
        echo "Deja monte: ${MOUNT_POINT}"
        return 0
    fi

    mount -t nfs -o "${NFS_OPTS}" -- "${nfs_spec}" "${MOUNT_POINT}"
    log_info "Montage reussi: ${nfs_spec} -> ${MOUNT_POINT}"
    echo "Montage reussi: ${nfs_spec} -> ${MOUNT_POINT}"
}

unmount_nfs() {
    if mountpoint -q -- "${MOUNT_POINT}"; then
        umount -- "${MOUNT_POINT}"
        log_info "Demontage reussi: ${MOUNT_POINT}"
        echo "Demontage reussi: ${MOUNT_POINT}"
    else
        log_notice "Deja demonte: ${MOUNT_POINT}"
        echo "Deja demonte: ${MOUNT_POINT}"
    fi
}

main() {
    local action="${1:-}"

    case "${action}" in
        mount)
            mount_nfs
            ;;
        unmount)
            unmount_nfs
            ;;
        *)
            log_warning "Usage invalide: ${0} {mount|unmount}"
			echo "smartmount v${VER}"
            printf 'Usage: %s {mount|unmount}\n' "${0}" >&2
            exit 2
            ;;
    esac
}

main "$@"
