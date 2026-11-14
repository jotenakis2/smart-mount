#!/usr/bin/env bash
# shellcheck enable=all
# =============================================================================
# nas-outage-sim.sh — simule l'absence du NAS pour éprouver smart-mount
#
# Pourquoi pas un simple `nft drop` sur l'IP : smart-mount vérifie l'identité du
# serveur par sa MAC dans la table ARP. Un filtrage IP laisse le NAS répondre
# aux requêtes ARP, l'identité reste confirmée et le chemin de démontage n'est
# jamais exercé. On coupe donc les deux :
#   - famille `arp` : on jette les réponses ARP du NAS ;
#   - famille `inet` : on jette tout son trafic IP ;
#   - on supprime l'entrée voisine déjà en cache.
# Du point de vue du noyau le serveur n'existe plus : c'est ce que voit
# smart-mount quand le NAS est réellement éteint.
#
# Le rétablissement est planifié AVANT la coupure (systemd-run --on-active) :
# un script interrompu ne laisse pas la machine coupée du NAS.
#
# Usage :
#   nas-outage-sim.sh cut [DUREE]   coupe pendant DUREE (défaut 5m ; 90m, 3600s)
#   nas-outage-sim.sh restore       rétablit immédiatement
#   nas-outage-sim.sh status        règles actives, ARP, état des partages
#   --dry-run s'ajoute à n'importe lequel des trois
#
# Variables : NAS_IP (192.168.50.85), IFACE (wlan0), SHOW_BIN, LOG.
# cut et restore exigent root : le script se ré-exécute via pkexec.
# =============================================================================

set -uo pipefail

SELF=$(readlink -f "$0")
NAS_IP=${NAS_IP:-192.168.50.85}
IFACE=${IFACE:-wlan0}
SHOW_BIN=${SHOW_BIN:-nas-smartmount.sh}
TABLE_INET=nas_outage_sim
TABLE_ARP=nas_outage_sim
LOG=${LOG:-/tmp/nas-outage-sim.log}
RESTORE_UNIT=nas-outage-restore

DRY_RUN=0
args=()
for a in "$@"; do
    if [[ $a == --dry-run ]]; then DRY_RUN=1; else args+=("$a"); fi
done
set -- "${args[@]+"${args[@]}"}"

log() {
    local ts
    ts=$(date '+%H:%M:%S')
    # le script tourne aussi en root (pkexec) : le journal appartient à
    # l'utilisateur, on n'échoue pas si on ne peut pas y écrire.
    printf '%s %s\n' "${ts}" "$*" | tee -a "$LOG" >&2 2>/dev/null || printf '%s %s\n' "${ts}" "$*" >&2
}

# Ré-exécution unique via pkexec pour les verbes qui touchent au réseau.
maybe_reexec() {
    (( DRY_RUN )) && return 0
    [[ ${EUID} -eq 0 ]] && return 0
    log "root requis : relance via pkexec"
    local extra=()
    (( DRY_RUN )) && extra+=(--dry-run)
    exec pkexec env NAS_IP="$NAS_IP" IFACE="$IFACE" SHOW_BIN="$SHOW_BIN" LOG="$LOG" \
        "$SELF" "${extra[@]+"${extra[@]}"}" "$@"
}

nft_do() {
    if (( DRY_RUN )); then log "DRY: nft $*"; return 0; fi
    nft "$@"
}

cut_rules() {
    nft_do delete table arp "$TABLE_ARP" 2>/dev/null
    nft_do delete table inet "$TABLE_INET" 2>/dev/null

    nft_do add table arp "$TABLE_ARP"
    nft_do add chain arp "$TABLE_ARP" out '{ type filter hook output priority 0 ; }'
    nft_do add rule arp "$TABLE_ARP" out arp saddr ip "$NAS_IP" drop
    nft_do add chain arp "$TABLE_ARP" in '{ type filter hook input priority 0 ; }'
    nft_do add rule arp "$TABLE_ARP" in arp saddr ip "$NAS_IP" drop

    nft_do add table inet "$TABLE_INET"
    nft_do add chain inet "$TABLE_INET" out '{ type filter hook output priority 0 ; }'
    nft_do add rule inet "$TABLE_INET" out ip daddr "$NAS_IP" drop
    nft_do add chain inet "$TABLE_INET" in '{ type filter hook input priority 0 ; }'
    nft_do add rule inet "$TABLE_INET" in ip saddr "$NAS_IP" drop

    if (( DRY_RUN )); then
        log "DRY: ip neigh del $NAS_IP dev $IFACE"
    else
        ip neigh del "$NAS_IP" dev "$IFACE" 2>/dev/null || true
    fi
}

clear_rules() {
    nft_do delete table arp "$TABLE_ARP" 2>/dev/null || true
    nft_do delete table inet "$TABLE_INET" 2>/dev/null || true
    (( DRY_RUN )) && { log "DRY: ping $NAS_IP"; return 0; }
    ip neigh del "$NAS_IP" dev "$IFACE" 2>/dev/null || true
    ping -c1 -W2 "$NAS_IP" >/dev/null 2>&1 || true
}

show_state() {
    timeout 30 "$SHOW_BIN" show 2>/dev/null | awk '/^nfs|^cifs/ {print "   " $0}' | sed 's/  */ /g'
}

to_seconds() {
    case "$1" in
        *h) printf '%s' $(( ${1%h} * 3600 )) ;;
        *m) printf '%s' $(( ${1%m} * 60 )) ;;
        *s) printf '%s' "${1%s}" ;;
        *)  printf '%s' $(( $1 * 60 )) ;;
    esac
}

cmd_status() {
    log "règles de coupure : $(nft list tables 2>/dev/null | grep -c "$TABLE_INET" || true)"
    log "ARP pour ${NAS_IP} :"
    ip neigh show "$NAS_IP" 2>/dev/null | sed 's/^/   /' || log "   (aucune entrée)"
    log "partages :"
    show_state
}

cmd_cut() {
    local duree=${1:-5m} seconds
    seconds=$(to_seconds "$duree")
    if (( seconds < 30 )); then
        log "durée trop courte (${seconds}s) : 30 s minimum"
        return 2
    fi

    if (( DRY_RUN )); then
        log "DRY: systemd-run --on-active=${seconds} ${RESTORE_UNIT} … restore"
    else
        systemctl reset-failed "$RESTORE_UNIT.service" >/dev/null 2>&1 || true
        if ! systemd-run --on-active="${seconds}" --unit="$RESTORE_UNIT" \
            --description="rétablissement réseau NAS (simulation)" \
            "$SELF" restore >/dev/null 2>&1; then
            log "rétablissement non planifiable : coupure annulée"
            return 1
        fi
        log "rétablissement planifié dans ${seconds}s (${RESTORE_UNIT})"
    fi

    log "coupure ARP + IP de ${NAS_IP} (${IFACE})"
    cut_rules

    log "observation immédiate :"
    local restant=120
    while (( restant > 0 )); do
        sleep 20
        restant=$(( restant - 20 ))
        show_state
    done
    log "fenêtre d'observation terminée ; rétablissement automatique à échéance"
}

cmd_restore() {
    log "rétablissement"
    clear_rules
    systemctl start nas-network-check.service >/dev/null 2>&1 || true
    sleep 5
    log "état après rétablissement :"
    show_state
}

main() {
    local cmd=${1:-status}
    shift || true
    case "$cmd" in
        cut)     maybe_reexec cut "$@"; cmd_cut "$@" ;;
        restore) maybe_reexec restore "$@"; cmd_restore ;;
        status)  cmd_status ;;
        -h|--help|help) sed -n '3,30p' "$SELF" ;;
        *) log "verbe inconnu : $cmd"; return 2 ;;
    esac
}

main "$@"
