#!/usr/bin/env bash

# shellcheck disable=SC2034
VER=1.2
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
        4)   str="MAC cible absente de ${CONFIG}: aucun montage possible, renseigner NFS_SERVER_MAC (voir README)";;
        122) str="Missing config file (${CONFIG})";;
        127) str="Error ping test (${NFS_SERVER_IP}) before mounting ${NFS_SERVER_IP}:${NFS_SHAREDPATH} in ${MOUNT_POINT}";;
        *)   str="Unknown error";;
    esac
    log_err "${str}"
}

# SMARTMOUNT_DRY_RUN=1 évalue la politique et journalise la décision sans monter
# ni démonter : le seul moyen de contrôler le chemin Ethernet sur une machine
# qui n'en a pas.
dry_run() {
    [[ "${SMARTMOUNT_DRY_RUN:-0}" != "0" ]]
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
        if dry_run; then
            log_notice "[dry-run] montage ${nfs_spec} -> ${MOUNT_POINT} non effectué"
            return 0
        fi
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

    if dry_run; then
        log_notice "[dry-run] démontage de ${MOUNT_POINT} non effectué"
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

get_neighbor_mac() {
    local ip_addr="${1:-}"
    local iface="${2:-}"
    local out=''

    [[ -n "${ip_addr}" ]] || return 1
    command -v ip >/dev/null 2>&1 || return 1

    if [[ -n "${iface}" ]]; then
        out="$(ip neigh show "${ip_addr}" dev "${iface}" 2>/dev/null)"
    else
        out="$(ip neigh show "${ip_addr}" 2>/dev/null)"
    fi

    # La position de la MAC change selon les arguments : `ip neigh show IP`
    # imprime « IP dev IF lladdr MAC ETAT » alors que `... IP dev IF` imprime
    # « IP lladdr MAC ETAT ». On se place donc après le mot-clé, jamais sur $5.
    printf '%s\n' "${out}" \
        | awk '{ for (i = 1; i < NF; i++) if ($i == "lladdr") { print $(i + 1); exit } }'
}

refresh_neighbor() {
    ping -c 1 -i 0.2 -W 2 -w 3 "${1:-}" >/dev/null 2>&1 || true
}

# Identité du serveur sur un lien : le voisin à l'adresse du NAS doit porter la
# MAC cible. On l'exige sur les deux liens (Wi-Fi comme Ethernet) : le SSID seul
# n'identifie pas un serveur, n'importe quel réseau du même nom ferait monter.
# Sans entrée ARP on réveille le voisinage une fois puis on relit. Pas d'entrée
# du tout = identité non vérifiée, donc pas de montage.
# Limite connue : si le NAS est derrière un routeur (autre sous-réseau ou VLAN),
# la MAC lue est celle du routeur ; c'est alors cette MAC qu'il faut configurer.
neighbor_is_target() {
    local iface="${1:-}"
    local ip_addr="${NFS_SERVER_IP:-}"
    local want="${NFS_SERVER_MAC:-}"
    local mac=''

    if [[ -z "${iface}" || -z "${ip_addr}" || -z "${want}" ]]; then
        return 1
    fi

    mac="$(get_neighbor_mac "${ip_addr}" "${iface}")"
    if [[ -z "${mac}" ]]; then
        refresh_neighbor "${ip_addr}"
        mac="$(get_neighbor_mac "${ip_addr}" "${iface}")"
    fi

    if [[ -z "${mac}" ]]; then
        log_info "Aucun voisin à ${ip_addr} sur ${iface}: identité non vérifiée"
        return 1
    fi

    if [[ "${mac,,}" != "${want,,}" ]]; then
        log_notice "MAC détectée ${mac} sur ${iface}, attendue ${want}: identité refusée"
        return 1
    fi

    log_notice "NAS confirmé: ${ip_addr} sur ${iface} (${mac})"
    return 0
}

# Une seule décision pour les deux liens : chaque lien doit être à la fois le bon
# réseau ET le bon serveur ; il suffit que l'un des deux le soit pour monter, et
# il faut que les deux soient écartés sans ambiguïté pour démonter. Avant, chaque
# hook décidait de son côté et pouvait défaire le travail de l'autre.
apply_policy() {
    local ssid='' state=0

    # Sans MAC cible, l'identité du serveur ne peut pas être vérifiée : on refuse
    # de monter plutôt que de monter sur un inconnu. Code dédié (4).
    if [[ -z "${NFS_SERVER_MAC:-}" ]]; then
        return 4   # message dédié par trap_err
    fi

    ssid="$(get_current_wifi)"
    state=$?

    if [[ ${state} -eq 0 && "${ssid}" == "${WIFI_NAME}" ]]; then
        if neighbor_is_target "${WIFI_IFACE:-}"; then
            log_info "Wi-Fi ciblé (${ssid}) et NAS confirmé: montage attendu"
            mount_nfs
            return
        fi
        log_notice "Wi-Fi ciblé (${ssid}) mais NAS non confirmé: on regarde l'Ethernet"
    fi

    if neighbor_is_target "${LAN_IFACE:-}"; then
        log_info "NAS confirmé sur Ethernet: montage attendu"
        mount_nfs
        return
    fi

    if [[ ${state} -eq 2 ]]; then
        log_warning "SSID illisible et NAS non confirmé: aucune action"
        return 0
    fi

    if [[ ${state} -eq 1 ]]; then
        log_info "Ni Wi-Fi ciblé ni NAS confirmé sur Ethernet: montage non attendu"
    elif [[ "${ssid}" == "${WIFI_NAME}" ]]; then
        log_info "Wi-Fi ciblé (${ssid}) mais NAS non confirmé: montage non attendu"
    else
        log_info "Wi-Fi étranger (${ssid}) et NAS non confirmé sur Ethernet: montage non attendu"
    fi
    unmount_nfs
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
            # Verbe historique : monte si l'un des deux liens est à la fois le
            # bon réseau et le bon serveur, mais ne démonte jamais.
            if [[ -z "${NFS_SERVER_MAC:-}" ]]; then
                return 4   # message dédié par trap_err
            fi
            ssid="$(get_current_wifi)"
            state=$?
            if [[ ${state} -eq 0 && "${ssid}" == "${WIFI_NAME}" ]] \
                && neighbor_is_target "${WIFI_IFACE:-}"; then
                mount_nfs
            elif neighbor_is_target "${LAN_IFACE:-}"; then
                mount_nfs
            else
                log_info "Aucun lien confirmé, pas de NFS à monter"
                return 0
            fi
            ;;
        unmount) unmount_nfs ;;
        apply)   apply_policy ;;
        *)       return 3 ;;
    esac
}

main "$@"
