#!/usr/bin/env bash

# shellcheck disable=SC2034
VER=1.8
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
        3)   str="${SCRIPT_NAME} syntax error - valid usage is : ${SCRIPT_NAME} {show [--json]|mount|unmount|apply}" ;;
        4)   str="No target MAC for a share: refusing to mount (see the log above)";;
        5)   str="Missing dependency: ${MISSING_DEPS} — see README, Requirements";;
        122) str="Configuration missing or without any share (${CONFIG})";;
        127) str="A server does not answer ping (see the share in the journal)";;
        *)   str="Unknown error";;
    esac
    log_err "${str}"
}

# Le seul texte volontairement en français avec le journal de l'ancienne version :
# l'aide s'adresse à un humain devant le terminal. Tout le reste — messages de
# journal, sortie de `show`, erreurs — est en anglais, parce que ces lignes finissent
# dans un rapport de bug ou dans une issue.
help_text() {
    cat <<'HELPEOF'
smart-mount — monte des partages NFS et CIFS seulement quand le bon serveur est
joignable sur le bon réseau, les répare, et les démonte sinon.

Usage :
  nfs-smartmount.sh show [--json]   montages actifs et options retenues
  nfs-smartmount.sh apply           applique la politique à tous les partages
  nfs-smartmount.sh mount           monte ce qui est légitime, ne démonte jamais
  nfs-smartmount.sh unmount         démonte tous les points de montage configurés
  nfs-smartmount.sh --help          ce texte

Configuration : /etc/smart-mount/config (root, 0640)
  WIFI_NAME, WIFI_IFACE, LAN_IFACE
  SHARES=("type|serveur|partage|point|options|mac|identifiants|réseaux" …)
  réseaux : SSID séparés par ; — vide = le SSID global, * = n'importe quel réseau

Variables d'environnement :
  SMARTMOUNT_DRY_RUN=1   calcule et journalise la décision sans rien monter
  SMARTMOUNT_CONFIG      autre chemin de configuration (tests)

Codes de sortie : 0 ok · 1 échec de montage · 2 échec de démontage · 3 usage
invalide · 4 MAC cible absente · 5 dépendance manquante · 122 configuration
absente · 127 serveur injoignable

Détail : man 8 nfs-smartmount
HELPEOF
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
        log_info "${ip_addr} absent from the ARP table of ${iface}: identity not verified"
        return 1
    fi

    if [[ "${mac,,}" != "${want,,}" ]]; then
        log_notice "MAC ${mac} sur ${iface} for ${ip_addr}, expected ${want}: identity rejected"
        return 1
    fi

    log_notice "Server confirmed: ${ip_addr} on ${iface} (${mac})"
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
        log_notice "[${mount}] lazy unmount done"
        return 0
    fi
    return 2
}

# `umount -f` n'a de sens que sur NFS : il abandonne les RPC en attente, donc il
# rend la main immédiatement quand le serveur ne répond plus — c'est le cas qui
# fige un shell, et `umount` simple y attend le timeout complet. Sur CIFS il n'a
# pas cet effet et peut échouer là où `umount -l` réussit : on ne le tente que
# si findmnt confirme un montage nfs.
umount_forced() { # umount_forced <point>
    local mount="${1:-}"
    local fstype=''

    fstype="$(timeout 5 findmnt -M "${mount}" -no FSTYPE 2>/dev/null)"
    case "${fstype}" in
        nfs*) : ;;
        *)    return 1 ;;
    esac

    log_warning "[${mount}] server unresponsive, forcing unmount (umount -f: pending RPCs abandoned)"
    if timeout 10 umount -f -- "${mount}" 2>/dev/null; then
        log_notice "[${mount}] forced unmount done"
        return 0
    fi
    return 1
}


unmount_one() { # unmount_one <point>
    local mount="${1:-}"
    local mountpoint_rc=0

    timeout 5 mountpoint -q -- "${mount}" >/dev/null 2>&1 || mountpoint_rc=$?

    # 1 = franchement pas monté. 0 = monté. 124 = expiré, on tente quand même.
    if [[ ${mountpoint_rc} -eq 1 ]]; then
        log_notice "[${mount}] already unmounted"
        return 0
    fi

    if dry_run; then
        log_notice "[dry-run] unmount of ${mount} not performed"
        return 0
    fi

    if timeout 10 umount -- "${mount}" 2>/dev/null; then
        log_info "[${mount}] unmount succeeded"
        return 0
    fi

    # Avant le repli paresseux : si le serveur est muet, `umount` vient de perdre
    # dix secondes à attendre des RPC. `-f` les abandonne et libère le montage.
    if umount_forced "${mount}"; then
        return 0
    fi

    # Cas courant : un shell ou un IDE ouvert dans le partage. Sans ce repli le
    # portable part avec un montage dur actif et fige au prochain accès.
    log_warning "[${mount}] unmount blocked (busy mount point?), trying lazy unmount"
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
            log_info "[${mount}] mount point created"
        else
            log_err "[${mount}] cannot create the mount point"
            return 1
        fi
    fi

    # `mountpoint` interroge le serveur quand les attributs ne sont plus en cache :
    # on le borne, sinon un serveur mort fige le timer. 124 = expiré.
    timeout 5 mountpoint -q -- "${mount}" >/dev/null 2>&1 || mountpoint_rc=$?

    if [[ ${mountpoint_rc} -eq 0 ]]; then
        if mount_is_healthy "${mount}"; then
            log_notice "[${mount}] already mounted and healthy"
            return 0
        fi
        # Un test de santé peut échouer sur une coupure de deux secondes : on
        # confirme avant de détruire un montage qui fonctionne.
        sleep 2
        if mount_is_healthy "${mount}"; then
            log_notice "[${mount}] already mounted and healthy on second check"
            return 0
        fi
        log_warning "[${mount}] mounted but not responding: repairing"
        if ! unmount_one "${mount}"; then
            log_err "[${mount}] repair failed: still mounted and not responding"
            return 1
        fi
    elif [[ ${mountpoint_rc} -eq 124 ]]; then
        log_warning "[${mount}] check timed out: repairing"
        # Si rien n'est monté, `umount -l` échoue : ce n'est pas une raison de
        # renoncer au montage, on laisse la tentative suivante trancher.
        if ! umount_lazy "${mount}"; then
            log_warning "[${mount}] nothing to unmount lazily, attempting mount"
        fi
    fi

    if ! ping -c 1 -i 0.2 -W 2 -w 3 "${server}" >/dev/null 2>&1; then
        log_info "[${mount}] ${server} unreachable, not mounting"
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
        log_notice "[dry-run] mount ${spec} -> ${mount} not performed"
        return 0
    fi

    local -a args=(-t "${type}")
    [[ -n "${opts}" ]] && args+=(-o "${opts}")
    args+=(-- "${spec}" "${mount}")

    if mount "${args[@]}" 2>/dev/null; then
        log_info "[${mount}] mount succeeded: ${spec}"
        return 0
    fi

    log_err "[${mount}] failed to mount ${spec}"
    return 1
}

# Réseaux autorisés pour un partage (8e champ, `;` ou `,` comme séparateur) :
#   vide  -> le SSID global WIFI_NAME (comportement d'avant la 1.7)
#   *     -> n'importe quel réseau, l'identité du serveur (MAC) fait foi seule
# Un SSID ne doit donc pas contenir `;` ni `,` : c'est la limite du format.
net_matches() { # net_matches <réseaux> <ssid>
    local nets="${1-}"
    local ssid="${2-}"
    local item=''
    local -a items=()

    if [[ -z "${nets}" ]]; then
        [[ "${ssid}" == "${WIFI_NAME}" ]]
        return
    fi

    mapfile -t items < <(printf '%s' "${nets}" | tr ';,' '\n')
    for item in "${items[@]}"; do
        if [[ "${item}" == '*' || "${item}" == "${ssid}" ]]; then
            return 0
        fi
    done
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

    local type='' server='' path='' mount='' opts='' mac='' creds='' nets=''
    type="$(share_field "${record}" 1)"
    server="$(share_field "${record}" 2)"
    path="$(share_field "${record}" 3)"
    mount="$(share_field "${record}" 4)"
    opts="$(share_field "${record}" 5)"
    mac="$(share_field "${record}" 6)"
    creds="$(share_field "${record}" 7)"
    nets="$(share_field "${record}" 8)"

    if [[ -z "${type}" || -z "${server}" || -z "${path}" || -z "${mount}" ]]; then
        log_err "Invalid share record: ${record}"
        return 3
    fi

    if [[ "${type}" != "nfs" && "${type}" != "cifs" ]]; then
        log_err "[${mount}] unknown share type: ${type}"
        return 3
    fi

    # L'identité du serveur ne se devine pas : sans MAC cible, pas de montage.
    if [[ -z "${mac}" ]]; then
        log_err "[${mount}] no target MAC: refusing to mount"
        return 4
    fi

    if [[ ${state} -eq 0 ]] && net_matches "${nets}" "${ssid}" \
        && neighbor_is_target "${WIFI_IFACE:-}" "${server}" "${mac}"; then
        log_info "[${mount}] targeted Wi-Fi (${ssid}) and ${server} confirmed: mount expected"
        mount_one "${type}" "${server}" "${path}" "${mount}" "${opts}" "${creds}"
        return
    fi

    if neighbor_is_target "${LAN_IFACE:-}" "${server}" "${mac}"; then
        log_info "[${mount}] ${server} confirmed on Ethernet: mount expected"
        mount_one "${type}" "${server}" "${path}" "${mount}" "${opts}" "${creds}"
        return
    fi

    if [[ ${state} -eq 2 ]]; then
        log_warning "[${mount}] SSID unreadable and ${server} not confirmed: no action"
        return 0
    fi

    if [[ "${mode}" == "mount" ]]; then
        log_info "[${mount}] no link confirmed, not mounting"
        return 0
    fi

    if [[ ${state} -eq 0 ]] && net_matches "${nets}" "${ssid}"; then
        log_info "[${mount}] targeted Wi-Fi but ${server} not confirmed: mount not expected"
    else
        log_info "[${mount}] unrecognised network for ${server}: mount not expected"
    fi
    unmount_one "${mount}"
}

run_policy() { # run_policy <apply|mount>
    local mode="${1:-apply}"
    local ssid='' state=0 rc=0 share=''

    require_runtime "$(share_extra_deps)" || return 5

    if [[ ${#SHARES[@]} -eq 0 ]]; then
        log_err "No share configured in ${CONFIG}"
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

# Affiche les montages actifs, partage par partage, et signale tout montage
# nfs/cifs qui ne vient pas de la configuration. Lecture seule : n'appelle que
# findmnt (borné) et le test de santé. Fonctionne aussi sans les droits root :
# la configuration est alors illisible et seule la partie « montages réels »
# s'affiche, avec une note.

# ------------------------------------------------------------------- show
# `show` décrit ce qui est monté, jamais la décision : aucune fonction de
# politique n'est appelée, rien n'est monté ni démonté, et aucun log n'est émis.
# Deux rendus pour une seule collecte : un tableau pour l'œil, du JSON pour un
# script ou une interface.
# Les colonnes se comptent en CARACTÈRES : sans locale UTF-8, bash compte des octets
# et `printf %-*s` remplit en octets, si bien que chaque accent décalait le tableau
# d'une colonne. On force donc une locale UTF-8 quand la machine en propose une (les
# appels nmcli gardent leur LC_ALL=C explicite), et on remplit avec des espaces
# calculées au lieu de la largeur de printf.
utf8_setup() {
    [[ "${SMARTMOUNT_UTF8:-0}" -eq 1 ]] && return 0
    if [[ "$(locale charmap 2>/dev/null)" == UTF-8 ]]; then
        SMARTMOUNT_UTF8=1
        return 0
    fi

    local candidate=''
    for candidate in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
        if [[ "$(LC_ALL="${candidate}" locale charmap 2>/dev/null)" == UTF-8 ]]; then
            export LC_ALL="${candidate}"
            SMARTMOUNT_UTF8=1
            return 0
        fi
    done
    return 0
}

pad() { # pad <texte> <largeur en caractères>
    local text="${1-}"
    local width="${2:-0}"
    local n=$(( width - ${#text} ))
    (( n > 0 )) || n=0
    printf '%s%*s' "${text}" "${n}" ''
}

json_escape() { # json_escape <texte>
    local s="${1-}"

    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '%s' "${s}"
}

# Une ligne de SHOW_ROWS, onze champs :
#   point|type|serveur|partage|réseaux|source|fstype|options du noyau|état|configuré|options retenues
# Les « options retenues » sont celles de l'enregistrement : c'est la décision de
# l'utilisateur, stable et lisible, alors que les options du noyau (rsize, addr,
# proto, sec…) changent à chaque montage et noient l'information.
collect_mounts() {
    SHOW_ROWS=()
    SHOW_HAVE_CONFIG=0

    load_config && SHOW_HAVE_CONFIG=1

    local rec='' type='' server='' path='' mount='' spec='' nets='' opts=''
    local target='' source='' fstype='' mopts='' state=''
    local known=0 point=''
    local -a configured=()

    for rec in "${SHARES[@]}"; do
        type="$(share_field "${rec}" 1)"
        server="$(share_field "${rec}" 2)"
        path="$(share_field "${rec}" 3)"
        mount="$(share_field "${rec}" 4)"
        opts="$(share_field "${rec}" 5)"
        nets="$(share_field "${rec}" 8)"
        spec="$(share_spec "${type}" "${server}" "${path}")"
        configured+=("${mount}")

        target='' source='' fstype='' mopts=''
        if read -r target source fstype mopts \
            < <(timeout 5 findmnt -M "${mount}" -no TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null) \
            && [[ -n "${target}" ]]; then
            if mount_is_healthy "${mount}"; then
                state='mounted, healthy'
            else
                state='mounted, NOT RESPONDING'
            fi
            SHOW_ROWS+=("$(printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
                "${mount}" "${type}" "${server}" "${path}" "${nets}" \
                "${source}" "${fstype}" "${mopts}" "${state}" '1' "${opts}")")
        else
            # Non monté : la source et les options affichées sont celles que le
            # partage aurait eues, pour que l'écart soit lisible.
            SHOW_ROWS+=("$(printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
                "${mount}" "${type}" "${server}" "${path}" "${nets}" \
                "${spec}" '' '' 'not mounted' '1' "${opts}")")
        fi
    done

    # Montages nfs/cifs qui ne viennent pas de la configuration : c'est le signal
    # d'un second mécanisme (fstab, montage manuel, automount) sur le même point.
    while read -r target source fstype mopts; do
        [[ -n "${target}" ]] || continue
        known=0
        for point in "${configured[@]}"; do
            [[ "${point}" == "${target}" ]] && known=1
        done
        [[ ${known} -eq 1 ]] && continue
        if [[ ${SHOW_HAVE_CONFIG} -eq 1 ]]; then
            state='mounted (not in configuration)'
        else
            state='mounted'
        fi
        SHOW_ROWS+=("$(printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
            "${target}" "${fstype}" '' '' '' "${source}" "${fstype}" "${mopts}" "${state}" '0' '')")
    done < <(timeout 5 findmnt -t nfs,nfs4,cifs -no TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null)
}

render_table() {
    local row='' point='' type='' server='' path='' nets='' source='' fstype=''
    local mopts='' state='' conf='' copts=''
    local h_type='TYPE' h_point='MOUNT POINT' h_source='SOURCE' h_state='STATE' h_opts='OPTIONS'
    local w_type=${#h_type} w_point=${#h_point} w_source=${#h_source} w_state=${#h_state}
    local -a cells=()

    for row in "${SHOW_ROWS[@]}"; do
        IFS='|' read -r point type server path nets source fstype mopts state conf copts <<< "${row}"
        cells+=("${type}|${point}|${source}|${state}|${copts}")
        (( ${#type} > w_type )) && w_type=${#type}
        (( ${#point} > w_point )) && w_point=${#point}
        (( ${#source} > w_source )) && w_source=${#source}
        (( ${#state} > w_state )) && w_state=${#state}
    done

    printf '%s  %s  %s  %s  %s\n' \
        "$(pad "${h_type}" "${w_type}")" "$(pad "${h_point}" "${w_point}")" \
        "$(pad "${h_source}" "${w_source}")" "$(pad "${h_state}" "${w_state}")" "${h_opts}"
    for row in "${cells[@]}"; do
        IFS='|' read -r type point source state copts <<< "${row}"
        printf '%s  %s  %s  %s  %s\n' \
            "$(pad "${type}" "${w_type}")" "$(pad "${point}" "${w_point}")" \
            "$(pad "${source}" "${w_source}")" "$(pad "${state}" "${w_state}")" "${copts:--}"
    done

    if [[ ${#SHOW_ROWS[@]} -eq 0 ]]; then
        echo '(no active nfs/cifs mount)'
    fi

    if [[ ${SHOW_HAVE_CONFIG} -eq 0 ]]; then
        echo
        echo "Configuration not readable (${CONFIG}): run with sudo to compare it with the real mounts."
    fi
}

print_json_array() { # print_json_array <nom> <virgule finale 0|1> <élément…>
    local name="${1:-}"
    local comma="${2:-0}"
    local count=0
    local item=''
    shift 2 || true
    count=$#

    if [[ ${count} -eq 0 ]]; then
        if [[ ${comma} -eq 1 ]]; then
            printf '  "%s": [],\n' "${name}"
        else
            printf '  "%s": []\n' "${name}"
        fi
        return 0
    fi

    printf '  "%s": [\n' "${name}"
    local i=0
    for item in "$@"; do
        i=$(( i + 1 ))
        if [[ ${i} -lt ${count} ]]; then
            printf '    %s,\n' "${item}"
        else
            printf '    %s\n' "${item}"
        fi
    done
    if [[ ${comma} -eq 1 ]]; then
        printf '  ],\n'
    else
        printf '  ]\n'
    fi
}

render_json() {
    local row='' point='' type='' server='' path='' nets='' source='' fstype=''
    local mopts='' state='' conf='' copts=''
    local mounted='' healthy=''
    local -a shares=() foreign=()

    for row in "${SHOW_ROWS[@]}"; do
        IFS='|' read -r point type server path nets source fstype mopts state conf copts <<< "${row}"

        if [[ "${state}" == 'not mounted' ]]; then
            mounted='false'
        else
            mounted='true'
        fi
        if [[ "${state}" == 'mounted, healthy' ]]; then
            healthy='true'
        elif [[ "${state}" == 'mounted, NOT RESPONDING' ]]; then
            healthy='false'
        else
            healthy='null'
        fi

        if [[ "${conf}" == '1' ]]; then
            shares+=("$(printf '{"type": "%s", "server": "%s", "share": "%s", "mountpoint": "%s", "networks": "%s", "source": "%s", "fstype": "%s", "options": "%s", "runtime_options": "%s", "state": "%s", "mounted": %s, "healthy": %s}' \
                "$(json_escape "${type}")" "$(json_escape "${server}")" "$(json_escape "${path}")" \
                "$(json_escape "${point}")" "$(json_escape "${nets}")" "$(json_escape "${source}")" \
                "$(json_escape "${fstype}")" "$(json_escape "${copts}")" "$(json_escape "${mopts}")" \
                "$(json_escape "${state}")" "${mounted}" "${healthy}")")
        else
            foreign+=("$(printf '{"mountpoint": "%s", "source": "%s", "fstype": "%s", "runtime_options": "%s"}' \
                "$(json_escape "${point}")" "$(json_escape "${source}")" \
                "$(json_escape "${fstype}")" "$(json_escape "${mopts}")")")
        fi
    done

    if [[ ${SHOW_HAVE_CONFIG} -eq 1 ]]; then
        printf '{\n'
        printf '  "version": "%s",\n' "$(json_escape "${VER}")"
        printf '  "config": "%s",\n' "$(json_escape "${CONFIG}")"
        printf '  "config_readable": true,\n'
    else
        printf '{\n'
        printf '  "version": "%s",\n' "$(json_escape "${VER}")"
        printf '  "config": "%s",\n' "$(json_escape "${CONFIG}")"
        printf '  "config_readable": false,\n'
    fi
    print_json_array shares 1 "${shares[@]}"
    print_json_array foreign 0 "${foreign[@]}"
    printf '}\n'
}

show_mounts() { # show_mounts [table|json]
    local mode="${1:-table}"

    utf8_setup
    collect_mounts
    case "${mode}" in
        json) render_json ;;
        *)    render_table ;;
    esac
    return 0
}


load_config() {
    SHARES=()

    [[ -f "${CONFIG}" ]] || return 1
    # shellcheck disable=SC1090
    source "${CONFIG}" 2>/dev/null || return 1

    # Compatibilité : un fichier de configuration antérieur (un seul partage NFS,
    # variables à plat) reste lisible sans migration préalable.
    if [[ ${#SHARES[@]} -eq 0 && -n "${NFS_SERVER_IP:-}" ]]; then
        SHARES=("nfs|${NFS_SERVER_IP}|${NFS_SHAREDPATH:-}|${MOUNT_POINT:-}|${NFS_OPTS:-}|${NFS_SERVER_MAC:-}|")
    fi

    return 0
}

main() {
    local action="${1:-}"

    case "${action}" in
        -h|--help) help_text; return 0 ;;
        show)
            case "${2:-}" in
                '')     show_mounts table ;;
                --json) show_mounts json ;;
                *)      return 3 ;;
            esac
            return
            ;;
        mount|unmount|apply) ;;
        *) return 3 ;;
    esac

    load_config || return 122

    case "${action}" in
        mount)   run_policy mount ;;
        unmount) unmount_all ;;
        apply)   run_policy apply ;;
    esac
}

main "$@"
