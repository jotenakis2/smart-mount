# smart-mount

Mount a local NFS share automatically when the machine is on the right network —
and unmount it, or repair it, when things change.

[Version française](README-fr.md)

## What it does

Two links are trusted, and each one is identified by **both** the network and the
server:

- **Wi-Fi**: the configured SSID *and* the NFS server's MAC address, read from the
  ARP table of the Wi-Fi interface;
- **Ethernet**: the same MAC check, on the configured LAN interface.

The SSID alone is not enough: an access point with the same name somewhere else must
not make the share mount. The MAC address is the server's identity, and it is
mandatory — without it nothing mounts.

**One decision, one place.** `nfs-smartmount.sh apply` holds the whole policy. The two
NetworkManager hooks and the systemd timer no longer decide anything: they trigger
that policy. This is what stops the Wi-Fi hook and the Ethernet hook from undoing each
other's work when both links are active (laptop docked, Wi-Fi on another network, …).

## Behaviour

```
nfs-smartmount.sh {mount|unmount|apply}
```

| situation | what `apply` does |
|---|---|
| SSID matches **and** NAS MAC confirmed on `WIFI_IFACE` | mount |
| otherwise, NAS MAC confirmed on `LAN_IFACE` | mount |
| otherwise, one of the two links cannot be read | nothing (a failed read must not destroy a working share) |
| otherwise, both links ruled out for certain | unmount |
| `NFS_SERVER_MAC` is empty | refuses to mount, exit code 4 |

- **self-healing**: every pass tests an existing mount (`stat -f` plus a directory
  read, bounded by `timeout 5`). If it no longer answers — NAS rebooted, stale handles
  — it is unmounted and mounted again. A second test 2 s later avoids destroying a
  healthy mount on a two-second network blip.
- **robust unmount**: `umount` bounded by `timeout 10`, then a lazy `umount -l`
  fallback if the mount point is busy (a shell or an IDE sitting in the share). Exit
  code 2 only if both fail.
- **dry-run**: `SMARTMOUNT_DRY_RUN=1` evaluates and logs the decision without mounting
  or unmounting. This is how the Ethernet path can be checked on a machine that has
  none: `sudo SMARTMOUNT_DRY_RUN=1 /usr/local/bin/nfs-smartmount.sh apply`.

Exit codes: `1` mount failed, `2` unmount failed, `3` invalid usage, `4` no target MAC
configured, `122` missing config file, `127` server unreachable before mounting.

## Requirements

`bash`, `nfs-utils`, `whiptail`, NetworkManager, `systemd`, `coreutils` (`timeout`),
`iproute2` (`ip neigh`, used for the identity check).
`iw` is recommended — it reads the SSID of the active link reliably; without it the
script falls back to `nmcli`.

## Install

```
git clone https://github.com/jotenakis2/smart-mount && cd smart-mount && sudo make install
```

`make install` runs `make check` first (syntax, `shellcheck`, test suite), then the
configuration wizard (values land in `/etc/smart-mount/config`, mode 0600), copies the
two hooks to `/etc/NetworkManager/dispatcher.d`, the script to `/usr/local/bin` and the
units to `/etc/systemd/system`, then enables the timer.

The wizard uses `/etc/fstab` and the active connection as defaults, detects the
server's MAC address, and rewrites a conflicting `fstab` entry so the share is not
mounted twice at boot (a backup is kept).

## Configuration

`/etc/smart-mount/config`, sourced by the script (root only, mode 0600):

```
NFS_SERVER_IP="192.168.50.85"
NFS_SHAREDPATH="/volume1/share"
MOUNT_POINT="/media/NAS"
NFS_OPTS="nodev,nosuid,noexec,noatime,lazytime"

WIFI_NAME="HomeWiFi"
WIFI_IFACE="wlan0"

NFS_SERVER_MAC="b0:83:fe:52:1b:6d"
LAN_IFACE="eth0"
```

### Finding the MAC address

- while the NAS is reachable: `ip neigh show <NAS_IP>`;
- or in the NAS administration interface, or in the router's DHCP lease list;
- `setup.sh` looks in the ARP table first and only pings as a fallback. If it still
  cannot find it, it explains the procedure and leaves the field empty: you then set
  `NFS_SERVER_MAC` in `/etc/smart-mount/config` (or re-run `sudo make install`).
  Nothing mounts until that is done.

## Tests

```
make check
```

Runs `bash -n`, `shellcheck`, and 38 scenarios / 103 assertions with simulated
commands (`tests/run.sh`): nominal mount, NAS rebooted, busy mount point, unreadable
SSID, unreachable server, flaky health check, expired `mountpoint`, `nmcli` fallback,
SSID containing `:`, missing MAC (refusal, code 4), matching SSID without an ARP entry
or with a different MAC (refusal + identity log), Ethernet confirmed without Wi-Fi,
foreign Wi-Fi + confirmed Ethernet (and the reverse), MAC compared case-insensitively,
empty `LAN_IFACE`, dry-run, and both hooks (which must trigger `apply` and never
unmount on their own). Nothing touches the real system.

The identity check (ARP table + expected MAC) has been validated in dry-run against a
real ARP entry, over Wi-Fi and Ethernet. What is still not validated is the physical
Ethernet side: the interface name and the NetworkManager events on that link.

## Known limits

- The MAC is read from the ARP table of the link. If the NAS sits behind a router
  (another subnet or a VLAN), the MAC seen is the router's — that is the one to put in
  the configuration.
- On the Wi-Fi side, a cold ARP cache needs one ping to resolve; a server that filters
  ICMP must already be present in the ARP table, otherwise the identity cannot be
  confirmed and the share will not mount.
- Default NFS options include neither `soft` nor `timeo`: a hard mount plus a server
  that disappears can freeze accesses for as long as the RPC timeouts last. The hooks
  unmount on network loss, the timer repairs dead mounts, and `NFS_OPTS` is yours to
  tune.

## Uninstall

```
cd smart-mount && sudo make uninstall
```

Removes the hooks, the script and the units, then disables the timer. The configuration
file and the `fstab` adjustment are left in place on purpose — check
`/etc/smart-mount/config` and `/etc/fstab` if you want to undo them by hand.

## TODO

SMB
