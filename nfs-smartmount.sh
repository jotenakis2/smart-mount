#!/usr/bin/env bash

# shellcheck disable=SC2034
VER=1.5
# Surchargeable uniquement pour les tests (tests/run.sh). Ni NetworkManager ni
# le timer ne definissent cette variable : en production le chemin reste /etc.
readonly CONFIG="${SMARTMOUNT_CONFIG:-/etc/smart-mount/config}"
readonly SCRIPT_NAME="${0##*/}"
trap 'trap_err "$?"' ERR

# Dépendances dures : sans elles, monter est impossible, ou la décision perd sa
# sûreté (ip pour l'identité, timeout pour borner, ping pour la joignabilité).
# Vide = aucune vérification ; c'est ce que fait tests/run.sh pour ne pas dépendre
# des paquets installés sur la machine de test.
SMARTMOUNT_DEPS="${SMARTMOUNT_DEPS-mount.nfs ip ping timeout}"

# Renseignée par require_runtime, lue par trap_err (une seule ligne de journal).
MISSING_DEPS=''

require_runtime() {
    local extra="${1:-}"
    local -a deps=()
    local dep=''

    [[ -n "${SMARTMOUNT_DEPS}" ]] || return 0

    MISSING_DEPS=''
    read -r -a deps <<< "${SMARTMOUNT_DEPS} ${extra}"
    for dep in "${deps[@]}"; do
        [[ -n "${dep}" ]] || continue
        command -v "${dep}" >/dev/null 2>&1 || MISSING_DEPS="${MISSING_DEPS} ${dep}"
    done
    MISSING_DEPS="${MISSING_DEPS# }"

    [[ -z "${MISSING_DEPS}" ]] || return 5
    return 0
}

#-helpers --------------------------------------------------------------------------------------------
# Canal de log : stdout dans un terminal, sinon syslog. `logger` est une
# dépendance molle : sans lui on écrit sur stderr plutôt que de perdre le message
# (et plutôt que de faire échouer un hook qui tourne sous set -e).
_log() {
    local priority="${1}"
    shift

    if [[ -t 1 ]]; then
        echo "$*"
    elif command -v logger >/dev/null 2>&1; then
        logger -t "${SCRIPT_NAME}" -p "user.${priority}" -- "$*"
    else
        printf '%s\n' "$*" >&2
    fi
}

log_info() { _log info "$@"; }

log_notice() { _log notice "$@"; }

log_warning() { _log warning "$@"; }

log_err() { _log err "$@"; }

trap_err() {
    local exit_code="${1}"
    local str=''
    case "${exit_code}" in
        1)   str="Error mounting a share (see the log lines above)";;
        2)   str="Error unmounting a mount point (see the log lines above)";;
        3)   str="${SCRIPT_NAME} syntax error - valid usage is : ${SCRIPT_NAME} {mount|unmount|apply}" ;;
        4)   str="MAC cible absente pour un partage: refus de monter (voir README)";;
        5)   str="Dépendance(s) manquante(s): ${MISSING_DEPS} — voir README, section Requirements";;
        122) str="Configuration absente ou sans partage (${CONFIG})";;
        127) str="Un serveur ne répond pas au ping (voir le partage concerné dans le journal)";;
        *)   str="Unknown error";;
    esac
    log_err "${str}"
}

# SMARTMOUNT_DRY_RUN=1 évalue la politique et journalise la décision sans monter
# ni démonter : le seul moyen de contrôler un chemin réseau sur une machine qui
# n'en a pas.
dry_run() {
    [[ "${SMARTMOUNT_DRY_RUN:-0}" != "0" ]]
}

#-------------------------------------------------------------------------------------------------

# Un partage est une ligne de SHARES : sept champs séparés par '|'
#   type|serveur|partage|point de montage|options|mac|fichier d'identifiants
# Les champs sont lus par position, jamais réassemblés.

share_field() { # share_field <record> <index 1..7>
    local -a f=()
    IFS='|' read -r -a f <<< "${1:-}"
    local idx=$(( ${2:-1} - 1 ))
    printf '%s' "${f[${idx}]:-}"
}

share_spec() { # share_spec <type> <serveur> <partage>
    case "${1:-}" in
        cifs) printf '//%s/%s' "${2:-}" "${3#/}" ;;
        *)    printf '%s:%s' "${2:-}" "${3:-}" ;;
    esac
}

# `mount -t cifs` demande mount.cifs : on ne l'exige que si un partage CIFS existe.
share_extra_deps() {
    local share=''
    for share in "${SHARES[@]}"; do
        case "${share}" in
            cifs\|*) printf 'mount.cifs'; return 0 ;;
        esac
    done
}

# L'état Wi-Fi est distingué en trois cas : sinon une lecture ratée (cache de scan
# vide, interface absente) serait confondue avec « pas le bon réseau » et
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

get_neighbor_mac() { # get_neighbor_mac <ip> <iface>
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

    # La position de la MAC change selon les arguments : `ip neigh show IP` imprime
    # « IP dev IF lladdr MAC ETAT » alors que `... IP dev IF` imprime
    # « IP lladdr MAC ETAT ». On se place donc après le mot-clé, jamais sur $5.
    printf '%s\n' "${out}" \
        | awk '{ for (i = 1; i < NF; i++) if ($i == "lladdr") { print $(i + 1); exit } }'
}

refresh_neighbor() {
    ping -c 1 -i 0.2 -W 2 -w 3 "${1:-}" >/dev/null 2>&1 || true
}

# Identité du serveur sur un lien : le voisin à son adresse doit porter la MAC
# cible. On l'exige sur les deux liens : le SSID seul n'identifie pas un serveur.
# Sans entrée ARP on réveille le voisinage une fois puis on relit. Pas d'entrée du
# tout = identité non vérifiée, donc pas de montage pour ce partage.
# Limite connue : si le serveur est derrière un routeur (autre sous-réseau ou
# VLAN), la MAC lue est celle du routeur ; c'est cette MAC qu'il faut configurer.
neighbor_is_target() { # neighbor_is_target <iface> <ip> <mac attendue>
    local iface="${1:-}"
    local ip_addr="${2:-}"
    local want="${3:-}"
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
        log_info "${ip_addr} absent de la table ARP de ${iface}: identité non vérifiée"
        return 1
    fi

    if [[ "${mac,,}" != "${want,,}" ]]; then
        log_notice "MAC ${mac} sur ${iface} pour ${ip_addr}, attendue ${want}: identité refusée"
        return 1
    fi

    log_notice "Serveur confirmé: ${ip_addr} sur ${iface} (${mac})"
    return 0
}

# Un montage peut survivre au serveur : le point existe, mais plus aucune requête
# n'aboutit. On teste les deux appels qui touchent réellement le serveur (statfs
# puis lecture du répertoire), bornés par timeout.
mount_is_healthy() { # mount_is_healthy <point>
    # Sans `timeout` (coreutils), un test de santé sur un serveur mort peut se
    # bloquer : dans le doute, on ne conclut pas et on ne démonte rien.
    if ! command -v timeout >/dev/null 2>&1; then
        return 0
    fi
    timeout 5 stat -f -- "${1:-}" >/dev/null 2>&1 || return 1
    timeout 5 ls -- "${1:-}" >/dev/null 2>&1 || return 1
    return 0
}

umount_lazy() { # umount_lazy <point>
    local mount="${1:-}"
    if timeout 10 umount -l -- "${mount}" 2>/dev/null; then
        log_notice "[${mount}] démontage paresseux effectué"
        return 0
    fi
    return 2
}

unmount_one() { # unmount_one <point>
    local mount="${1:-}"
    local mountpoint_rc=0

    timeout 5 mountpoint -q -- "${mount}" >/dev/null 2>&1 || mountpoint_rc=$?

    # 1 = franchement pas monté. 0 = monté. 124 = expiré, on tente quand même.
    if [[ ${mountpoint_rc} -eq 1 ]]; then
        log_notice "[${mount}] déjà démonté"
        return 0
    fi

    if dry_run; then
        log_notice "[dry-run] démontage de ${mount} non effectué"
        return 0
    fi

    if timeout 10 umount -- "${mount}" 2>/dev/null; then
        log_info "[${mount}] démontage réussi"
        return 0
    fi

    # Cas courant : un shell ou un IDE ouvert dans le partage. Sans ce repli le
    # portable part avec un montage dur actif et fige au prochain accès.
    log_warning "[${mount}] démontage bloqué (point occupé ?), repli paresseux"
    if umount_lazy "${mount}"; then
        return 0
    fi

    return 2
}

mount_one() { # mount_one <type> <serveur> <partage> <point> <options> <identifiants>
    local type="${1:-}"
    local server="${2:-}"
    local path="${3:-}"
    local mount="${4:-}"
    local opts="${5:-}"
    local creds="${6:-}"
    local spec='' mountpoint_rc=0

    spec="$(share_spec "${type}" "${server}" "${path}")"

    if [[ ! -d "${mount}" ]]; then
        if mkdir -p -- "${mount}" 2>/dev/null; then
            log_info "[${mount}] point de montage créé"
        else
            log_err "[${mount}] impossible de créer le point de montage"
            return 1
        fi
    fi

    # `mountpoint` interroge le serveur quand les attributs ne sont plus en cache :
    # on le borne, sinon un serveur mort fige le timer. 124 = expiré.
    timeout 5 mountpoint -q -- "${mount}" >/dev/null 2>&1 || mountpoint_rc=$?

    if [[ ${mountpoint_rc} -eq 0 ]]; then
        if mount_is_healthy "${mount}"; then
            log_notice "[${mount}] déjà monté et sain"
            return 0
        fi
        # Un test de santé peut échouer sur une coupure de deux secondes : on
        # confirme avant de détruire un montage qui fonctionne.
        sleep 2
        if mount_is_healthy "${mount}"; then
            log_notice "[${mount}] déjà monté et sain au second essai"
            return 0
        fi
        log_warning "[${mount}] montage muet: réparation"
        if ! unmount_one "${mount}"; then
            log_err "[${mount}] réparation impossible: reste monté et muet"
            return 1
        fi
    elif [[ ${mountpoint_rc} -eq 124 ]]; then
        log_warning "[${mount}] vérification expirée: réparation"
        # Si rien n'est monté, `umount -l` échoue : ce n'est pas une raison de
        # renoncer au montage, on laisse la tentative suivante trancher.
        if ! umount_lazy "${mount}"; then
            log_warning "[${mount}] rien à démonter paresseusement, tentative de montage"
        fi
    fi

    if ! ping -c 1 -i 0.2 -W 2 -w 3 "${server}" >/dev/null 2>&1; then
        log_info "[${mount}] ${server} injoignable, pas de montage"
        return 127
    fi

    # Les identifiants CIFS passent par un fichier 0600, jamais par -o : la ligne
    # de commande est lisible par tous les utilisateurs (ps).
    if [[ -n "${creds}" && -f "${creds}" ]]; then
        case ",${opts}," in
            *,credentials=*) : ;;
            *) opts="${opts:+${opts},}credentials=${creds}" ;;
        esac
    fi

    if dry_run; then
        log_notice "[dry-run] montage ${spec} -> ${mount} non effectué"
        return 0
    fi

    local -a args=(-t "${type}")
    [[ -n "${opts}" ]] && args+=(-o "${opts}")
    args+=(-- "${spec}" "${mount}")

    if mount "${args[@]}" 2>/dev/null; then
        log_info "[${mount}] montage réussi: ${spec}"
        return 0
    fi

    log_err "[${mount}] échec du montage de ${spec}"
    return 1
}

# Politique d'un partage : chaque lien doit être à la fois le bon réseau ET le bon
# serveur. Il suffit que l'un des deux le soit pour monter ; il faut que les deux
# soient écartés sans ambiguïté pour démonter. En mode `mount` on ne démonte jamais.
apply_share() { # apply_share <record> <ssid> <état wifi> <apply|mount>
    local record="${1:-}"
    local ssid="${2:-}"
    local state="${3:-2}"
    local mode="${4:-apply}"

    local type='' server='' path='' mount='' opts='' mac='' creds=''
    type="$(share_field "${record}" 1)"
    server="$(share_field "${record}" 2)"
    path="$(share_field "${record}" 3)"
    mount="$(share_field "${record}" 4)"
    opts="$(share_field "${record}" 5)"
    mac="$(share_field "${record}" 6)"
    creds="$(share_field "${record}" 7)"

    if [[ -z "${type}" || -z "${server}" || -z "${path}" || -z "${mount}" ]]; then
        log_err "Enregistrement de partage invalide: ${record}"
        return 3
    fi

    if [[ "${type}" != "nfs" && "${type}" != "cifs" ]]; then
        log_err "[${mount}] type de partage inconnu: ${type}"
        return 3
    fi

    # L'identité du serveur ne se devine pas : sans MAC cible, pas de montage.
    if [[ -z "${mac}" ]]; then
        log_err "[${mount}] MAC cible absente: refus de monter"
        return 4
    fi

    if [[ ${state} -eq 0 && "${ssid}" == "${WIFI_NAME}" ]] \
        && neighbor_is_target "${WIFI_IFACE:-}" "${server}" "${mac}"; then
        log_info "[${mount}] Wi-Fi ciblé (${ssid}) et ${server} confirmé: montage attendu"
        mount_one "${type}" "${server}" "${path}" "${mount}" "${opts}" "${creds}"
        return
    fi

    if neighbor_is_target "${LAN_IFACE:-}" "${server}" "${mac}"; then
        log_info "[${mount}] ${server} confirmé sur Ethernet: montage attendu"
        mount_one "${type}" "${server}" "${path}" "${mount}" "${opts}" "${creds}"
        return
    fi

    if [[ ${state} -eq 2 ]]; then
        log_warning "[${mount}] SSID illisible et ${server} non confirmé: aucune action"
        return 0
    fi

    if [[ "${mode}" == "mount" ]]; then
        log_info "[${mount}] aucun lien confirmé, pas de montage"
        return 0
    fi

    if [[ ${state} -eq 0 && "${ssid}" == "${WIFI_NAME}" ]]; then
        log_info "[${mount}] Wi-Fi ciblé mais ${server} non confirmé: montage non attendu"
    else
        log_info "[${mount}] réseau non reconnu pour ${server}: montage non attendu"
    fi
    unmount_one "${mount}"
}

run_policy() { # run_policy <apply|mount>
    local mode="${1:-apply}"
    local ssid='' state=0 rc=0 share=''

    require_runtime "$(share_extra_deps)" || return 5

    if [[ ${#SHARES[@]} -eq 0 ]]; then
        log_err "Aucun partage configuré dans ${CONFIG}"
        return 122
    fi

    ssid="$(get_current_wifi)"
    state=$?

    for share in "${SHARES[@]}"; do
        apply_share "${share}" "${ssid}" "${state}" "${mode}" || rc=$?
    done

    return ${rc}
}

unmount_all() {
    local rc=0 share=''
    for share in "${SHARES[@]}"; do
        unmount_one "$(share_field "${share}" 4)" || rc=$?
    done
    return ${rc}
}

main() {
    local action="${1:-}"

    SHARES=()

    if [[ -f "${CONFIG}" ]]; then
        # shellcheck disable=SC1090
        source "${CONFIG}"
    else
        return 122
    fi

    # Compatibilité : un fichier de configuration antérieur (un seul partage NFS,
    # variables à plat) reste lisible sans migration préalable.
    if [[ ${#SHARES[@]} -eq 0 && -n "${NFS_SERVER_IP:-}" ]]; then
        SHARES=("nfs|${NFS_SERVER_IP}|${NFS_SHAREDPATH:-}|${MOUNT_POINT:-}|${NFS_OPTS:-}|${NFS_SERVER_MAC:-}|")
    fi

    case "${action}" in
        mount)   run_policy mount ;;
        unmount) unmount_all ;;
        apply)   run_policy apply ;;
        *)       return 3 ;;
    esac
}

main "$@"
