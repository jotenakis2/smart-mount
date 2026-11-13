#!/usr/bin/env bash

# shellcheck disable=SC2034
VER=1.11.1
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

# ------------------------------------------------------------------- langue
# La langue des messages suit la locale (SMARTMOUNT_LANG, puis LC_ALL,
# LC_MESSAGES, LANG : deux lettres suffisent). Anglais par défaut : c'est la
# langue dans laquelle un journal joint à une issue reste lisible. Les valeurs
# de `show --json` ne sont jamais traduites — un script ne doit pas dépendre de
# la locale de celui qui l'appelle.
smartmount_lang() {
    local loc="${SMARTMOUNT_LANG:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}"
    case "${loc}" in
        fr|fr_*|fr.*) printf 'fr' ;;
        *)            printf 'en' ;;
    esac
}

# msg <clé> [args…] : renvoie le message dans la langue courante, %s remplis.
msg() {
    local key="${1:-}"
    shift || true
    local text=''

    if [[ "${SMARTMOUNT_LANG}" == 'fr' ]]; then
        case "${key}" in
            arp_missing)          text='%s absent de la table ARP de %s : identité non vérifiée' ;;
            mac_rejected)         text='MAC %s sur %s pour %s, attendue %s : identité refusée' ;;
            server_confirmed)     text='Serveur confirmé : %s sur %s (%s)' ;;
            lazy_done)            text='[%s] démontage paresseux effectué' ;;
            force_try)            text='[%s] serveur muet, repli forcé (umount -f : RPC abandonnés)' ;;
            force_done)           text='[%s] démontage forcé effectué' ;;
            already_unmounted)    text='[%s] déjà démonté' ;;
            dry_unmount)          text='[dry-run] démontage de %s non effectué' ;;
            unmount_ok)           text='[%s] démontage réussi' ;;
            unmount_blocked)      text='[%s] démontage bloqué (point occupé ?), repli paresseux' ;;
            mp_created)           text='[%s] point de montage créé' ;;
            mp_failed)            text='[%s] impossible de créer le point de montage' ;;
            already_healthy)      text='[%s] déjà monté et sain' ;;
            healthy_second)       text='[%s] déjà monté et sain au second essai' ;;
            mute_repair)          text='[%s] montage muet : réparation' ;;
            repair_failed)        text='[%s] réparation impossible : reste monté et muet' ;;
            check_timeout)        text='[%s] vérification expirée : réparation' ;;
            nothing_to_lazy)      text='[%s] rien à démonter paresseusement, tentative de montage' ;;
            server_unreachable)   text='[%s] %s injoignable, pas de montage' ;;
            dry_mount)            text='[dry-run] montage %s -> %s non effectué' ;;
            mount_ok)             text='[%s] montage réussi : %s' ;;
            mount_failed)         text='[%s] échec du montage de %s' ;;
            bad_record)           text='Enregistrement de partage invalide : %s' ;;
            bad_type)             text='[%s] type de partage inconnu : %s' ;;
            no_mac)               text='[%s] MAC cible absente : refus de monter' ;;
            mount_expected_wifi)  text='[%s] Wi-Fi ciblé (%s) et %s confirmé : montage attendu' ;;
            mount_expected_eth)   text='[%s] %s confirmé sur Ethernet : montage attendu' ;;
            wifi_unreadable)      text='[%s] SSID illisible et %s non confirmé : aucune action' ;;
            no_link)              text='[%s] aucun lien confirmé, pas de montage' ;;
            wifi_not_confirmed)   text='[%s] Wi-Fi ciblé mais %s non confirmé : montage non attendu' ;;
            net_unrecognised)     text='[%s] réseau non reconnu pour %s : montage non attendu' ;;
            no_shares)            text='Aucun partage configuré dans %s' ;;
            err_mount)            text='Échec du montage d un partage (voir le journal ci-dessus)' ;;
            err_unmount)          text='Échec du démontage d un point de montage (voir le journal ci-dessus)' ;;
            err_usage)            text='%s : erreur de syntaxe - usage : %s {show [--json]|mount|unmount|apply|setup|--version|--help}' ;;
            err_mac)              text='MAC cible absente pour un partage : refus de monter (voir le journal)' ;;
            err_deps)             text='Dépendance manquante : %s - voir README, section Requirements' ;;
            err_config)           text='Configuration absente ou sans partage (%s)' ;;
            err_ping)             text='Un serveur ne répond pas au ping (voir le partage dans le journal)' ;;
            err_unknown)          text='Erreur inconnue' ;;
            st_healthy)           text='monté, sain' ;;
            st_mute)              text='monté, MUET' ;;
            st_unmounted)         text='démonté' ;;
            st_foreign)           text='monté (hors configuration)' ;;
            st_mounted)           text='monté' ;;
            h_type)               text='TYPE' ;;
            h_point)              text='POINT DE MONTAGE' ;;
            h_source)             text='SOURCE' ;;
            h_state)              text='ÉTAT' ;;
            h_opts)               text='OPTIONS' ;;
            no_mounts)            text='(aucun montage nfs/cifs actif)' ;;
            config_unreadable)    text='Configuration illisible (%s) : lancer avec sudo pour la comparer aux montages réels.' ;;
            ws_intro)             text='Configuration de smart-mount.\n\nAucune entrée /etc/fstab n'"'"'est nécessaire : le montage est fait par smart-mount.\nUne entrée existante sert seulement de valeurs par défaut, et reçoit l'"'"'option noauto\nsi elle entre en conflit avec un partage configuré.' ;;
            ws_network)           text='Réseau' ;;
            ws_shares)            text='Partages' ;;
            ws_share_title)       text='Partage %s' ;;
            ws_ssid)              text='SSID du Wi-Fi depuis lequel les partages sont joignables' ;;
            ws_wifi_iface)        text='Interface réseau Wi-Fi' ;;
            ws_lan_iface)         text='Interface réseau Ethernet/LAN' ;;
            ws_count)             text='Combien de partages voulez-vous configurer ? (1 à 9)' ;;
            ws_count_bad)         text='Nombre invalide. Combien de partages ? (1 à 9)' ;;
            ws_forbidden)         text='Caractères interdits : | " $ ` \\\n\nLe fichier de configuration est un script bash lu en root : ces caractères y sont\ndangereux. Merci de saisir une autre valeur.' ;;
            ws_smb_user)          text='Utilisateur SMB (vide = accès invité)' ;;
            ws_password)          text='Mot de passe pour %s sur %s' ;;
            ws_domain)            text='Domaine / groupe de travail (facultatif)' ;;
            ws_type)              text='Type du partage %s' ;;
            ws_smb_server)        text='Nom ou adresse IP du serveur SMB' ;;
            ws_smb_share)         text='Nom du partage SMB (ex : public)' ;;
            ws_nfs_server)        text='Adresse IP du serveur NFS' ;;
            ws_nfs_path)          text='Dossier exporté (ex : /volume1/share)' ;;
            ws_mount)             text='Point de montage' ;;
            ws_opts)              text='Options de montage' ;;
            ws_mac)               text='Adresse MAC de %s (obligatoire : sans elle, aucun montage)' ;;
            ws_mac_missing)       text='Aucune adresse MAC détectée pour %s.\n\nLe serveur n'"'"'a pas répondu : impossible de lire sa MAC. Ce partage ne sera PAS monté\ntant qu'"'"'aucune MAC cible n'"'"'est configurée, en Wi-Fi comme en Ethernet.\n\nPour la trouver :\n  - quand le serveur est joignable :  ip neigh show %s\n  - ou dans l'"'"'interface d'"'"'administration du NAS, ou les baux DHCP de la box\n\nRenseignez ensuite le 6e champ de ce partage dans /etc/smart-mount/config\n(ou relancez : sudo nas-smartmount.sh setup).' ;;
            ws_nets)              text='Réseaux autorisés, séparés par ; (vide = le SSID global, * = indifférent)' ;;
            ws_harden_opts)       text='Ajouter les protections nodev,nosuid,noexec ?\n\nSaisi  : %s\nProposé : %s\n\nCe sont des drapeaux du noyau, valables en NFS comme en CIFS : sans eux, un\npartage réseau peut servir à exécuter un binaire ou à monter un fichier setuid.' ;;
            ws_saved)             text='Configuration enregistrée dans %s' ;;
            ws_saved_backup)      text='Configuration enregistrée dans %s\n\nPrécédente configuration conservée dans :\n%s' ;;
            ws_fstab)             text='Une ou plusieurs entrées %s correspondant à vos partages ont reçu l'"'"'option noauto\n(et perdu x-systemd.automount).\n\nElles ne se montent plus au démarrage : c'"'"'est smart-mount qui s'"'"'en charge, depuis le\nhook réseau et le timer.\n\nSauvegarde : %s' ;;
            ws_cmd_missing)       text='Commande requise introuvable : %s' ;;
            ws_root_required)     text='Ce questionnaire doit être lancé en root (ou via pkexec).' ;;
            err_root)             text='Le verbe setup exige root : sudo nas-smartmount.sh setup' ;;
            *)                    text="msg:${key}" ;;
        esac
    else
        case "${key}" in
            arp_missing)          text='%s absent from the ARP table of %s: identity not verified' ;;
            mac_rejected)         text='MAC %s on %s for %s, expected %s: identity rejected' ;;
            server_confirmed)     text='Server confirmed: %s on %s (%s)' ;;
            lazy_done)            text='[%s] lazy unmount done' ;;
            force_try)            text='[%s] server unresponsive, forcing unmount (umount -f: pending RPCs abandoned)' ;;
            force_done)           text='[%s] forced unmount done' ;;
            already_unmounted)    text='[%s] already unmounted' ;;
            dry_unmount)          text='[dry-run] unmount of %s not performed' ;;
            unmount_ok)           text='[%s] unmount succeeded' ;;
            unmount_blocked)      text='[%s] unmount blocked (busy mount point?), trying lazy unmount' ;;
            mp_created)           text='[%s] mount point created' ;;
            mp_failed)            text='[%s] cannot create the mount point' ;;
            already_healthy)      text='[%s] already mounted and healthy' ;;
            healthy_second)       text='[%s] already mounted and healthy on second check' ;;
            mute_repair)          text='[%s] mounted but not responding: repairing' ;;
            repair_failed)        text='[%s] repair failed: still mounted and not responding' ;;
            check_timeout)        text='[%s] check timed out: repairing' ;;
            nothing_to_lazy)      text='[%s] nothing to unmount lazily, attempting mount' ;;
            server_unreachable)   text='[%s] %s unreachable, not mounting' ;;
            dry_mount)            text='[dry-run] mount %s -> %s not performed' ;;
            mount_ok)             text='[%s] mount succeeded: %s' ;;
            mount_failed)         text='[%s] failed to mount %s' ;;
            bad_record)           text='Invalid share record: %s' ;;
            bad_type)             text='[%s] unknown share type: %s' ;;
            no_mac)               text='[%s] no target MAC: refusing to mount' ;;
            mount_expected_wifi)  text='[%s] targeted Wi-Fi (%s) and %s confirmed: mount expected' ;;
            mount_expected_eth)   text='[%s] %s confirmed on Ethernet: mount expected' ;;
            wifi_unreadable)      text='[%s] SSID unreadable and %s not confirmed: no action' ;;
            no_link)              text='[%s] no link confirmed, not mounting' ;;
            wifi_not_confirmed)   text='[%s] targeted Wi-Fi but %s not confirmed: mount not expected' ;;
            net_unrecognised)     text='[%s] unrecognised network for %s: mount not expected' ;;
            no_shares)            text='No share configured in %s' ;;
            err_mount)            text='Error mounting a share (see the log lines above)' ;;
            err_unmount)          text='Error unmounting a mount point (see the log lines above)' ;;
            err_usage)            text='%s syntax error - valid usage is : %s {show [--json]|mount|unmount|apply|--version|--help}' ;;
            err_mac)              text='No target MAC for a share: refusing to mount (see the log above)' ;;
            err_deps)             text='Missing dependency: %s - see README, Requirements' ;;
            err_config)           text='Configuration missing or without any share (%s)' ;;
            err_ping)             text='A server does not answer ping (see the share in the journal)' ;;
            err_unknown)          text='Unknown error' ;;
            st_healthy)           text='mounted, healthy' ;;
            st_mute)              text='mounted, NOT RESPONDING' ;;
            st_unmounted)         text='not mounted' ;;
            st_foreign)           text='mounted (not in configuration)' ;;
            st_mounted)           text='mounted' ;;
            h_type)               text='TYPE' ;;
            h_point)              text='MOUNT POINT' ;;
            h_source)             text='SOURCE' ;;
            h_state)              text='STATE' ;;
            h_opts)               text='OPTIONS' ;;
            no_mounts)            text='(no active nfs/cifs mount)' ;;
            config_unreadable)    text='Configuration not readable (%s): run with sudo to compare it with the real mounts.' ;;
            ws_intro)             text='smart-mount setup.\n\nNo /etc/fstab entry is needed: smart-mount does the mounting itself.\nAn existing entry only provides defaults, and gets the noauto option if it\nconflicts with a configured share (it must not mount at boot).' ;;
            ws_network)           text='Network' ;;
            ws_shares)            text='Shares' ;;
            ws_share_title)       text='Share %s' ;;
            ws_ssid)              text='Wi-Fi SSID from which the shares are reachable' ;;
            ws_wifi_iface)        text='Wi-Fi interface' ;;
            ws_lan_iface)         text='Ethernet/LAN interface' ;;
            ws_count)             text='How many shares do you want to configure? (1-9)' ;;
            ws_count_bad)         text='Invalid number. How many shares? (1-9)' ;;
            ws_forbidden)         text='Forbidden characters: | " $ ` \\\n\nThe configuration file is a bash script read as root: these characters are\ndangerous there. Please enter another value.' ;;
            ws_smb_user)          text='SMB user (leave empty for guest access)' ;;
            ws_password)          text='Password for %s on %s' ;;
            ws_domain)            text='Domain / workgroup (optional)' ;;
            ws_type)              text='Type of share %s' ;;
            ws_smb_server)        text='SMB server name or IP address' ;;
            ws_smb_share)         text='SMB share name (e.g. public)' ;;
            ws_nfs_server)        text='NFS server IP address' ;;
            ws_nfs_path)          text='Exported path (e.g. /volume1/share)' ;;
            ws_mount)             text='Mount point' ;;
            ws_opts)              text='Mount options' ;;
            ws_mac)               text='MAC address of %s (mandatory: without it the share is never mounted)' ;;
            ws_mac_missing)       text='No MAC address detected for %s.\n\nThe server did not answer: its MAC address cannot be read. This share will NOT\nbe mounted until a target MAC is configured, over Wi-Fi as well as Ethernet.\n\nTo find it:\n  - while the server is reachable:  ip neigh show %s\n  - or in the NAS administration interface, or in the router'"'"'s DHCP leases\n\nThen fill in the 6th field of that share in /etc/smart-mount/config\n(or re-run: sudo nas-smartmount.sh setup).' ;;
            ws_nets)              text='Accepted networks, separated by ; (empty = the global SSID, * = any)' ;;
            ws_harden_opts)       text='Add the nodev,nosuid,noexec protections?\n\nEntered  : %s\nProposed : %s\n\nThese are kernel flags, valid for NFS as well as CIFS: without them a network\nshare can be used to run a binary or to mount a setuid file.' ;;
            ws_saved)             text='Configuration written to %s' ;;
            ws_saved_backup)      text='Configuration written to %s\n\nPrevious configuration kept in:\n%s' ;;
            ws_fstab)             text='One or more %s entries matching your shares received the noauto option\n(and lost x-systemd.automount).\n\nThey will no longer mount at boot: smart-mount does it, from the network hook\nand the timer.\n\nBackup: %s' ;;
            ws_cmd_missing)       text='Required command not found: %s' ;;
            ws_root_required)     text='This wizard must run as root (or through pkexec).' ;;
            err_root)             text='The setup verb requires root: sudo nas-smartmount.sh setup' ;;
            *)                    text="msg:${key}" ;;
        esac
    fi

    # shellcheck disable=SC2059 # le format est une constante du catalogue ci-dessus
    printf "${text}" "$@"
}

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
        1)   str="$(msg err_mount)";;
        2)   str="$(msg err_unmount)";;
        3)   str="$(msg err_usage "${SCRIPT_NAME}" "${SCRIPT_NAME}")";;
        4)   str="$(msg err_mac)";;
        5)   str="$(msg err_deps "${MISSING_DEPS}")";;
        122) str="$(msg err_config "${CONFIG}")";;
        127) str="$(msg err_ping)";;
        *)   str="$(msg err_unknown)";;
    esac
    log_err "${str}"
}

# Le seul texte volontairement en français avec le journal de l'ancienne version :
# l'aide s'adresse à un humain devant le terminal. Tout le reste — messages de
# journal, sortie de `show`, erreurs — est en anglais, parce que ces lignes finissent
# dans un rapport de bug ou dans une issue.
help_text() {
    if [[ "${SMARTMOUNT_LANG}" != 'fr' ]]; then
        cat <<'HELPEOF'
smart-mount - mounts NFS and CIFS shares only when the right server is reachable
on the right network, keeps them healthy, and unmounts them otherwise.

Usage:
  nas-smartmount.sh show [--json]   active mounts and the options retained
  nas-smartmount.sh apply           apply the policy to every share
  nas-smartmount.sh mount           mount what is legitimate, never unmount
  nas-smartmount.sh unmount         unmount every configured mount point
  nas-smartmount.sh setup           (re)configure the shares (root, whiptail)
  nas-smartmount.sh --version       version number, one line
  nas-smartmount.sh --help          this text

Configuration: /etc/smart-mount/config (root, 0640)
  WIFI_NAME, WIFI_IFACE, LAN_IFACE
  SHARES=("type|server|share|mount point|options|mac|credentials|networks" ...)
  networks: SSIDs separated by ; - empty = the global SSID, * = any network

Environment:
  SMARTMOUNT_DRY_RUN=1   evaluate and log the decision without mounting anything
  SMARTMOUNT_CONFIG      another configuration path (tests)
  SMARTMOUNT_LANG        force the message language (fr, en); defaults to the locale

Exit status: 0 ok - 1 mount failed - 2 unmount failed - 3 invalid usage
- 4 no target MAC - 5 missing dependency - 122 no configuration - 127 server
unreachable

See also: man 8 nas-smartmount
HELPEOF
        return 0
    fi

    cat <<'HELPEOF'
smart-mount — monte des partages NFS et CIFS seulement quand le bon serveur est
joignable sur le bon réseau, les répare, et les démonte sinon.

Usage :
  nas-smartmount.sh show [--json]   montages actifs et options retenues
  nas-smartmount.sh apply           applique la politique à tous les partages
  nas-smartmount.sh mount           monte ce qui est légitime, ne démonte jamais
  nas-smartmount.sh unmount         démonte tous les points de montage configurés
  nas-smartmount.sh setup           (re)configure les partages (root, whiptail)
  nas-smartmount.sh --version       numéro de version (une ligne)
  nas-smartmount.sh --help          ce texte

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

Détail : man 8 nas-smartmount
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
        log_info "$(msg arp_missing "${ip_addr}" "${iface}")"
        return 1
    fi

    if [[ "${mac,,}" != "${want,,}" ]]; then
        log_notice "$(msg mac_rejected "${mac}" "${iface}" "${ip_addr}" "${want}")"
        return 1
    fi

    log_notice "$(msg server_confirmed "${ip_addr}" "${iface}" "${mac}")"
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
        log_notice "$(msg lazy_done "${mount}")"
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

    log_warning "$(msg force_try "${mount}")"
    if timeout 10 umount -f -- "${mount}" 2>/dev/null; then
        log_notice "$(msg force_done "${mount}")"
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
        log_notice "$(msg already_unmounted "${mount}")"
        return 0
    fi

    if dry_run; then
        log_notice "$(msg dry_unmount "${mount}")"
        return 0
    fi

    if timeout 10 umount -- "${mount}" 2>/dev/null; then
        log_info "$(msg unmount_ok "${mount}")"
        return 0
    fi

    # Avant le repli paresseux : si le serveur est muet, `umount` vient de perdre
    # dix secondes à attendre des RPC. `-f` les abandonne et libère le montage.
    if umount_forced "${mount}"; then
        return 0
    fi

    # Cas courant : un shell ou un IDE ouvert dans le partage. Sans ce repli le
    # portable part avec un montage dur actif et fige au prochain accès.
    log_warning "$(msg unmount_blocked "${mount}")"
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
            log_info "$(msg mp_created "${mount}")"
        else
            log_err "$(msg mp_failed "${mount}")"
            return 1
        fi
    fi

    # `mountpoint` interroge le serveur quand les attributs ne sont plus en cache :
    # on le borne, sinon un serveur mort fige le timer. 124 = expiré.
    timeout 5 mountpoint -q -- "${mount}" >/dev/null 2>&1 || mountpoint_rc=$?

    if [[ ${mountpoint_rc} -eq 0 ]]; then
        if mount_is_healthy "${mount}"; then
            log_notice "$(msg already_healthy "${mount}")"
            return 0
        fi
        # Un test de santé peut échouer sur une coupure de deux secondes : on
        # confirme avant de détruire un montage qui fonctionne.
        sleep 2
        if mount_is_healthy "${mount}"; then
            log_notice "$(msg healthy_second "${mount}")"
            return 0
        fi
        log_warning "$(msg mute_repair "${mount}")"
        if ! unmount_one "${mount}"; then
            log_err "$(msg repair_failed "${mount}")"
            return 1
        fi
    elif [[ ${mountpoint_rc} -eq 124 ]]; then
        log_warning "$(msg check_timeout "${mount}")"
        # Si rien n'est monté, `umount -l` échoue : ce n'est pas une raison de
        # renoncer au montage, on laisse la tentative suivante trancher.
        if ! umount_lazy "${mount}"; then
            log_warning "$(msg nothing_to_lazy "${mount}")"
        fi
    fi

    if ! ping -c 1 -i 0.2 -W 2 -w 3 "${server}" >/dev/null 2>&1; then
        log_info "$(msg server_unreachable "${mount}" "${server}")"
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
        log_notice "$(msg dry_mount "${spec}" "${mount}")"
        return 0
    fi

    local -a args=(-t "${type}")
    [[ -n "${opts}" ]] && args+=(-o "${opts}")
    args+=(-- "${spec}" "${mount}")

    if mount "${args[@]}" 2>/dev/null; then
        log_info "$(msg mount_ok "${mount}" "${spec}")"
        return 0
    fi

    log_err "$(msg mount_failed "${mount}" "${spec}")"
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
        log_err "$(msg bad_record "${record}")"
        return 3
    fi

    if [[ "${type}" != "nfs" && "${type}" != "cifs" ]]; then
        log_err "$(msg bad_type "${mount}" "${type}")"
        return 3
    fi

    # L'identité du serveur ne se devine pas : sans MAC cible, pas de montage.
    if [[ -z "${mac}" ]]; then
        log_err "$(msg no_mac "${mount}")"
        return 4
    fi

    if [[ ${state} -eq 0 ]] && net_matches "${nets}" "${ssid}" \
        && neighbor_is_target "${WIFI_IFACE:-}" "${server}" "${mac}"; then
        log_info "$(msg mount_expected_wifi "${mount}" "${ssid}" "${server}")"
        mount_one "${type}" "${server}" "${path}" "${mount}" "${opts}" "${creds}"
        return
    fi

    if neighbor_is_target "${LAN_IFACE:-}" "${server}" "${mac}"; then
        log_info "$(msg mount_expected_eth "${mount}" "${server}")"
        mount_one "${type}" "${server}" "${path}" "${mount}" "${opts}" "${creds}"
        return
    fi

    if [[ ${state} -eq 2 ]]; then
        log_warning "$(msg wifi_unreadable "${mount}" "${server}")"
        return 0
    fi

    if [[ "${mode}" == "mount" ]]; then
        log_info "$(msg no_link "${mount}")"
        return 0
    fi

    if [[ ${state} -eq 0 ]] && net_matches "${nets}" "${ssid}"; then
        log_info "$(msg wifi_not_confirmed "${mount}" "${server}")"
    else
        log_info "$(msg net_unrecognised "${mount}" "${server}")"
    fi
    unmount_one "${mount}"
}

run_policy() { # run_policy <apply|mount>
    local mode="${1:-apply}"
    local ssid='' state=0 rc=0 share=''

    require_runtime "$(share_extra_deps)" || return 5

    if [[ ${#SHARES[@]} -eq 0 ]]; then
        log_err "$(msg no_shares "${CONFIG}")"
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
    local h_type='' h_point='' h_source='' h_state='' h_opts=''
    h_type="$(msg h_type)"
    h_point="$(msg h_point)"
    h_source="$(msg h_source)"
    h_state="$(msg h_state)"
    h_opts="$(msg h_opts)"
    local w_type=${#h_type} w_point=${#h_point} w_source=${#h_source} w_state=${#h_state}
    local -a cells=()
    local disp=''

    for row in "${SHOW_ROWS[@]}"; do
        IFS='|' read -r point type server path nets source fstype mopts state conf copts <<< "${row}"
        case "${state}" in
            'mounted, healthy')         disp="$(msg st_healthy)" ;;
            'mounted, NOT RESPONDING')  disp="$(msg st_mute)" ;;
            'not mounted')              disp="$(msg st_unmounted)" ;;
            'mounted (not in configuration)') disp="$(msg st_foreign)" ;;
            *)                          disp="$(msg st_mounted)" ;;
        esac
        cells+=("${type}|${point}|${source}|${disp}|${copts}")
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
        printf '%s\n' "$(msg no_mounts)" 
    fi

    if [[ ${SHOW_HAVE_CONFIG} -eq 0 ]]; then
        echo
        printf '%s\n' "$(msg config_unreadable "${CONFIG}")"
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

# ===================================================================== setup
# Le questionnaire vit dans ce fichier : une seule entrée (`setup`), un seul
# catalogue de messages, un seul format d'enregistrement. Il tourne dans un
# sous-shell avec `set -euo pipefail` pour ne pas imposer ces options au reste
# du script, qui doit rester tolérant dans les hooks et le timer.
SETUP_DIR="${CONFIG%/*}"
FSTAB="${SMARTMOUNT_FSTAB:-/etc/fstab}"

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

setup_main() {
    setup_require_root
    setup_require_cmd whiptail
    setup_require_cmd nmcli
    setup_require_cmd awk
    setup_require_cmd ip

    DEFAULT_WIFI_NAME=""
    DEFAULT_WIFI_IFACE="wlan0"
    DEFAULT_LAN_IFACE="eth0"

    find_active_wifi_defaults
    find_active_lan_defaults
    find_lan_iface_fallback

    whiptail --title "smart-mount setup" --msgbox "$(msg ws_intro)" 14 78 || true

    COUNT="$(ask_count)"
    SHARES=()
    local i
    for (( i = 1; i <= COUNT; i++ )); do
        SHARES+=("$(ask_share "${i}")")
    done

    WIFI_NAME="$(ask_input "$(msg ws_network)" "$(msg ws_ssid)" "${DEFAULT_WIFI_NAME}")"
    WIFI_IFACE="$(ask_input "$(msg ws_network)" "$(msg ws_wifi_iface)" "${DEFAULT_WIFI_IFACE}")"
    LAN_IFACE="$(ask_input "$(msg ws_network)" "$(msg ws_lan_iface)" "${DEFAULT_LAN_IFACE}")"

    write_config
    rewrite_fstab
}

# **************************************************************************************************************************************

setup_require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "$(msg ws_cmd_missing "$1")" >&2
        exit 1
    }
}
# **************************************************************************************************************************************

setup_require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "$(msg ws_root_required)" >&2
        exit 1
    fi
}
# **************************************************************************************************************************************

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

# nodev,nosuid,noexec : ce sont des drapeaux du noyau (VFS), donc valables en NFS
# comme en CIFS — vérifié : sur un montage cifs, noexec refuse réellement
# l'exécution. Un partage réseau qui autorise l'exécution ou les binaires setuid est
# un risque qu'on n'a aucune raison d'accepter par défaut.
ensure_safe_opts() { # ensure_safe_opts <options> -> options + les trois drapeaux manquants
    local opts="${1:-}"
    local flag=''
    local -a missing=()

    for flag in nodev nosuid noexec; do
        case ",${opts}," in
            *",${flag},"*) : ;;
            *) missing+=("${flag}") ;;
        esac
    done

    for flag in "${missing[@]}"; do
        opts="${opts:+${opts},}${flag}"
    done

    printf '%s' "${opts}"
}

ask_yesno() { # ask_yesno <titre> <question> -> 0 si oui
    local title="$1"
    local prompt="$2"

    if whiptail --title "${title}" --yesno "${prompt}" 12 78; then
        return 0
    fi
    return 1
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

        whiptail --title "${title}" --msgbox "$(msg ws_forbidden)" 12 78 || true
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
    n="$(ask_input "$(msg ws_shares)" "$(msg ws_count)" "1")"

    while [[ ! "${n}" =~ ^[1-9]$ ]]; do
        n="$(ask_input "$(msg ws_shares)" "$(msg ws_count_bad)" "1")"
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

    user="$(ask_input "$(msg ws_share_title "${num}")" "$(msg ws_smb_user)" "")"
    if [[ -z "${user}" ]]; then
        return 0
    fi

    pass="$(ask_password "$(msg ws_share_title "${num}")" "$(msg ws_password "${user}" "${server}")")"
    domain="$(ask_input "$(msg ws_share_title "${num}")" "$(msg ws_domain)" "")"

    file="${SETUP_DIR}/credentials-${num}"
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
    local type server path mount opts mac creds='' safe_opts=''
    local default_server='' defaults='' mount_default='' opts_default=''

    type="$(ask_menu "$(msg ws_share_title "${num}")" "$(msg ws_type "${num}")" \
        "nfs" "NFS (Linux, NAS)" \
        "cifs" "CIFS / SMB (Windows, NAS)")"

    default_server="$(fstab_first_server "${type}")"

    if [[ "${type}" = "cifs" ]]; then
        server="$(ask_input "$(msg ws_share_title "${num}")" "$(msg ws_smb_server)" "${default_server}")"
        path="$(ask_input "$(msg ws_share_title "${num}")" "$(msg ws_smb_share)" "")"
        opts_default="vers=3.0,iocharset=utf8,nodev,nosuid,noexec"
    else
        server="$(ask_input "$(msg ws_share_title "${num}")" "$(msg ws_nfs_server)" "${default_server}")"
        path="$(ask_input "$(msg ws_share_title "${num}")" "$(msg ws_nfs_path)" "")"
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

    mount="$(ask_input "$(msg ws_share_title "${num}")" "$(msg ws_mount)" "${mount_default}")"
    opts="$(ask_input "$(msg ws_share_title "${num}")" "$(msg ws_opts)" "${opts_default}")"

    # Les trois drapeaux ne sont pas seulement une valeur par défaut : celui qui
    # édite la ligne d'options ne doit pas pouvoir les perdre par inadvertance.
    safe_opts="$(ensure_safe_opts "${opts}")"
    if [[ "${safe_opts}" != "${opts}" ]]; then
        if ask_yesno "$(msg ws_share_title "${num}")" \
            "$(msg ws_harden_opts "${opts}" "${safe_opts}")"; then
            opts="${safe_opts}"
        fi
    fi

    if [[ "${type}" = "cifs" ]]; then
        creds="$(ask_cifs_creds "${num}" "${server}")"
    fi

    mac="$(get_server_mac "${server}")"
    mac="$(ask_input "$(msg ws_share_title "${num}")" "$(msg ws_mac "${server}")" "${mac}")"

    if [[ -z "${mac}" ]]; then
        whiptail --title "Share ${num}" --msgbox "$(msg ws_mac_missing "${server}")" 22 78 || true
    fi

    # 8e champ : réseaux autorisés pour CE partage. Vide = le SSID global, ce qui
    # reproduit exactement le comportement d'avant.
    nets="$(ask_input "$(msg ws_share_title "${num}")" "$(msg ws_nets)" "")"

    printf '%s|%s|%s|%s|%s|%s|%s|%s' "${type}" "${server}" "${path}" "${mount}" "${opts}" "${mac}" "${creds}" "${nets}"
}
# **************************************************************************************************************************************

write_config() {
    local backup='no'
    local backup_file=''
    local share=''

    mkdir -p "${SETUP_DIR}"

    if [[ -f "${CONFIG}" ]]; then
        backup_file="${CONFIG}.bak.$(date +%d_%m_%Y-%H.%M.%S)"
        cp -a "${CONFIG}" "${backup_file}"
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
    } > "${CONFIG}"

    # 0640 root:root : identique à 0600 pour tout autre utilisateur, mais un
    # groupe dédié (SMARTMOUNT_GROUP=smartmount) permet à `show` de lire la
    # configuration sans sudo, sans donner accès aux identifiants CIFS qui sont
    # dans des fichiers séparés.
    chmod 0640 "${CONFIG}"
    chgrp "${SMARTMOUNT_GROUP:-root}" "${CONFIG}" 2>/dev/null || true

    if [[ "${backup}" = "yes" ]]; then
        whiptail --title "smart-mount setup" --msgbox "$(msg ws_saved_backup "${CONFIG}" "${backup_file}")" 12 78 || true
    else
        whiptail --title "smart-mount setup" --msgbox "$(msg ws_saved "${CONFIG}")" 10 78 || true
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

    whiptail --title "smart-mount setup" --msgbox "$(msg ws_fstab "${FSTAB}" "${backup_file}")" 14 78 || true
}
# **************************************************************************************************************************************
# **************************************************************************************************************************************

main() {
    local action="${1:-}"

    # Résolu une fois pour toutes : utf8_setup exporte LC_ALL plus loin, et la
    # langue des messages ne doit pas changer en cours de route.
    SMARTMOUNT_LANG="${SMARTMOUNT_LANG:-$(smartmount_lang)}"

    case "${action}" in
        -h|--help) help_text; return 0 ;;
        setup)
            if [[ "$(id -u)" -ne 0 ]]; then
                # Verbe interactif : le message va sur stderr, où l'utilisateur le
                # voit, au lieu du journal qu'il ne lira pas.
                printf '%s\n' "$(msg err_root)" >&2
                return 1
            fi
            ( set -euo pipefail; setup_main )
            return
            ;;
        -V|--version) printf 'smart-mount %s\n' "${VER}"; return 0 ;;
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
