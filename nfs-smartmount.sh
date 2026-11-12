#!/usr/bin/env bash

# shellcheck disable=SC2034
VER=1.0
# Surchargeable uniquement pour les tests (tests/run.sh). Ni NetworkManager ni
# le timer ne definissent cette variable : en production le chemin reste /etc.
readonly CONFIG="${SMARTMOUNT_CONFIG:-/etc/smart-mount/config}"
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
        3)   str="${SCRIPT_NAME} syntax error - valid usage is : ${SCRIPT_NAME} {mount|unmount|apply}" ;;
        122) str="Missing config file (${CONFIG})";;
        127) str="Error ping test (${NFS_SERVER_IP}) before mounting ${NFS_SERVER_IP}:${NFS_SHAREDPATH} in ${MOUNT_POINT}";;
        *)   str="Unknown error";;
    esac
    log_err "${str}"
}

#-------------------------------------------------------------------------------------------------



mount_nfs() {
    local nfs_spec="${NFS_SERVER_IP}:${NFS_SHAREDPATH}"
    local mountpoint_rc=0

    if [[ ! -d "${MOUNT_POINT}" ]]; then
        if mkdir -p -- "${MOUNT_POINT}" 2>/dev/null; then
            log_info "Point de montage crée: ${MOUNT_POINT}"
        else
            log_err "Impossible de créer le point de montage: ${MOUNT_POINT}"
            return 1
        fi
    fi

    # `mountpoint` interroge le serveur quand les attributs ne sont plus en
    # cache : on le borne, sinon un NAS mort fige le timer. 124 = expiré.
    timeout 5 mountpoint -q -- "${MOUNT_POINT}" >/dev/null 2>&1 || mountpoint_rc=$?

    if [[ ${mountpoint_rc} -eq 0 ]]; then
        if mount_is_healthy; then
            log_notice "Deja monté et sain: ${MOUNT_POINT}"
            return 0
        fi
        # Un test de santé peut échouer sur une coupure Wi-Fi de deux secondes :
        # on confirme avant de détruire un montage qui fonctionne.
        sleep 2
        if mount_is_healthy; then
            log_notice "Deja monté et sain au second essai: ${MOUNT_POINT}"
            return 0
        fi
        log_warning "Montage présent mais muet (${MOUNT_POINT}): réparation"
        if ! unmount_nfs; then
            log_err "Réparation impossible: ${MOUNT_POINT} reste monté et muet"
            return 1
        fi
    elif [[ ${mountpoint_rc} -eq 124 ]]; then
        log_warning "Vérification de ${MOUNT_POINT} expirée: réparation"
        # Si rien n'est monté, `umount -l` échoue : ce n'est pas une raison de
        # renoncer au montage, on laisse la tentative suivante trancher.
        if ! umount_lazy_nfs; then
            log_warning "Rien à démonter paresseusement (${MOUNT_POINT}), tentative de montage"
        fi
    fi

    if ping -c 1 -i 0.2 -W 2 -w 3 "${NFS_SERVER_IP}" &>/dev/null; then
        if mount -t nfs -o "${NFS_OPTS}" -- "${nfs_spec}" "${MOUNT_POINT}" 2>/dev/null; then
            log_info "Montage réussi: ${nfs_spec} -> ${MOUNT_POINT}"
            return 0
        else
            return 1
        fi
    else
        return 127
    fi
}

# Un montage NFS peut survivre au serveur : le point existe, mais plus aucune
# requête n'aboutit. On teste les deux appels qui touchent réellement le
# serveur (statfs puis lecture du répertoire), bornés par timeout.
mount_is_healthy() {
    # Sans `timeout` (coreutils), un test de santé sur un serveur mort peut se
    # bloquer : dans le doute, on ne conclut pas et on ne démonte rien.
    if ! command -v timeout >/dev/null 2>&1; then
        return 0
    fi
    timeout 5 stat -f -- "${MOUNT_POINT}" >/dev/null 2>&1 || return 1
    timeout 5 ls -- "${MOUNT_POINT}" >/dev/null 2>&1 || return 1
    return 0
}

unmount_nfs() {
    local mountpoint_rc=0

    timeout 5 mountpoint -q -- "${MOUNT_POINT}" >/dev/null 2>&1 || mountpoint_rc=$?

    # 1 = franchement pas monté. 0 = monté. 124 = expiré, on tente quand même.
    if [[ ${mountpoint_rc} -eq 1 ]]; then
        log_notice "OK, déjà démonté: ${MOUNT_POINT}"
        return 0
    fi

    if timeout 10 umount -- "${MOUNT_POINT}" 2>/dev/null; then
        log_info "Démontage réussi: ${MOUNT_POINT}"
        return 0
    fi

    # Cas courant : un shell ou un IDE ouvert dans le partage. Sans ce repli le
    # portable part avec un montage dur actif et fige au prochain accès.
    log_warning "Démontage bloqué (point de montage occupé ?), repli paresseux"
    if umount_lazy_nfs; then
        return 0
    fi

    return 2
}

# Repli quand le point est occupé (shell ou IDE ouvert dans le partage) : sans
# lui le portable part avec un montage dur actif et fige au prochain accès.
umount_lazy_nfs() {
    if timeout 10 umount -l -- "${MOUNT_POINT}" 2>/dev/null; then
        log_notice "Démontage paresseux effectué: ${MOUNT_POINT}"
        return 0
    fi
    return 2
}

# L'état Wi-Fi est distingué en trois cas : sinon une lecture ratée (cache de
# scan vide, interface absente) serait confondue avec « pas le bon réseau » et
# provoquerait un démontage destructeur.
#   0 = connecté, le SSID est écrit sur la sortie standard
#   1 = pas connecté (état certain)
#   2 = inconnu (lecture impossible)
get_current_wifi() {
    local iface="${WIFI_IFACE:-}"
    local link_output='' ssid=''

    if [[ -n "${iface}" ]] && command -v iw >/dev/null 2>&1; then
        if link_output="$(iw dev "${iface}" link 2>/dev/null)"; then
            if [[ "${link_output}" == *"Not connected"* ]]; then
                return 1
            fi
            ssid="$(printf '%s\n' "${link_output}" \
                | sed -n 's/^[[:space:]]*SSID:[[:space:]]*//p' | head -n1)"
            if [[ -n "${ssid}" ]]; then
                printf '%s\n' "${ssid}"
                return 0
            fi
            # L'interface répond mais le SSID n'est pas lisible : ne pas deviner
            # via la liste globale, qui peut décrire une autre interface.
            return 2
        fi
    fi

    if command -v nmcli >/dev/null 2>&1; then
        if [[ -n "${iface}" ]]; then
            ssid="$(LC_ALL=C nmcli -t -f ACTIVE,SSID device wifi list ifname "${iface}" 2>/dev/null \
                | awk -F: '$1 == "yes" { sub(/^[^:]*:/, ""); print; exit }')"
        else
            ssid="$(LC_ALL=C nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null \
                | awk -F: '$1 == "yes" { sub(/^[^:]*:/, ""); print; exit }')"
        fi
        # nmcli échappe les ':' d'un SSID en mode -t : on les restitue.
        ssid="${ssid//\\:/:}"
        if [[ -n "${ssid}" ]]; then
            printf '%s\n' "${ssid}"
            return 0
        fi
    fi

    return 2
}

# Politique complète : monter si le réseau ciblé est actif, démonter sinon, ne
# rien faire si l'état est inconnu. C'est le seul verbe que le timer doit
# appeler, pour que le système converge dans les deux sens.
apply_policy() {
    local ssid='' state=0

    ssid="$(get_current_wifi)"
    state=$?

    case "${state}" in
        0)
            if [[ "${ssid}" == "${WIFI_NAME}" ]]; then
                log_info "Réseau ciblé (${ssid}): montage attendu"
                mount_nfs
            else
                log_info "Réseau non ciblé (${ssid} ≠ ${WIFI_NAME}): montage non attendu"
                unmount_nfs
            fi
            ;;
        1)
            log_info "Wi-Fi non connecté: montage non attendu"
            unmount_nfs
            ;;
        *)
            log_warning "SSID illisible: politique non applicable, aucune action"
            return 0
            ;;
    esac
}

main() {
    local action="${1:-}"
    local ssid='' state=0

    if [[ -f "${CONFIG}" ]]; then
        # shellcheck disable=SC1090
        source "${CONFIG}"
    else
        return 122
    fi

    case "${action}" in
        mount)
            # Verbe historique, conservé pour les hooks : ne monte que si le
            # Wi-Fi ciblé est actif.
            ssid="$(get_current_wifi)"
            state=$?
            if [[ ${state} -ne 0 ]]; then
                log_info "Réseau ciblé non confirmé (état ${state}), pas de NFS à monter"
                return 0
            fi
            if [[ "${ssid}" == "${WIFI_NAME}" ]]; then
                mount_nfs
            else
                log_info "WiFi non ciblé (${ssid} ≠ ${WIFI_NAME}), pas de NFS à monter"
                return 0
            fi
            ;;
        unmount) unmount_nfs ;;
        apply)   apply_policy ;;
        *)       return 3 ;;
    esac
}

main "$@"
