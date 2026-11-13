# smart-mount

Mount local shares automatically when the machine is on the right network — and
unmount them, or repair them, when things change.

[Version française](README-fr.md)

## What it does

Any number of **NFS** and/or **CIFS (SMB)** shares, each with its own mount point.
Two links are trusted, and each one is identified by **both** the network and the
server:

- **Wi-Fi**: the configured SSID *and* the server's MAC address, read from the ARP
  table of the Wi-Fi interface;
- **Ethernet**: the same MAC check, on the configured LAN interface.

The SSID alone is not enough: an access point with the same name somewhere else must
not make a share mount. The MAC address is the server's identity, and it is mandatory
— a share without a target MAC is never mounted.

**One decision, one place.** `nas-smartmount.sh apply` holds the whole policy, for
every share. The two NetworkManager hooks and the systemd timer no longer decide
anything: they trigger that policy. This is what stops the Wi-Fi hook and the Ethernet
hook from undoing each other's work when both links are active (laptop docked, Wi-Fi on
another network, …).

## Behaviour

```
nas-smartmount.sh {show [--json]|mount|unmount|apply|setup|--version|--help}
```

For each configured share, independently:

| situation | what `apply` does |
|---|---|
| SSID matches **and** server MAC confirmed on `WIFI_IFACE` | mount |
| otherwise, server MAC confirmed on `LAN_IFACE` | mount |
| otherwise, one of the two links cannot be read | nothing (a failed read must not destroy a working share) |
| otherwise, both links ruled out for certain | unmount |
| the share has no target MAC | refuses to mount it, exit code 4 |

A share whose server is not on the current network is simply left unmounted; the other
shares are unaffected.

- **self-healing**: every pass tests an existing mount (`stat -f` plus a directory read,
  bounded by `timeout 5`). If it no longer answers — server rebooted, stale handles — it
  is unmounted and mounted again. A second test 2 s later avoids destroying a healthy
  mount on a two-second network blip.
- **robust unmount**: `umount` bounded by `timeout 10`, then a lazy `umount -l` fallback
  if the mount point is busy (a shell or an IDE sitting in the share). Exit code 2 only
  if both fail.
- **dry-run**: `SMARTMOUNT_DRY_RUN=1` evaluates and logs the decision for every share
  without mounting or unmounting. This is how a network path can be checked on a machine
  that does not have it: `sudo SMARTMOUNT_DRY_RUN=1 /usr/local/bin/nas-smartmount.sh apply`.
- **`show`**: read-only table of the configured shares and of what is really mounted,
  plus any NFS/CIFS mount that does not come from the configuration:

  ```
  $ sudo nas-smartmount.sh show
  TYPE  MOUNT POINT     SOURCE                             STATE             OPTIONS
  nfs   /media/NAS      192.168.50.85:/media/diskusb/data  mounted, healthy  nodev,nosuid,noexec,noatime,lazytime
  cifs  /media/NAS-smb  //192.168.50.85/usbdisk_data       mounted, healthy  guest,iocharset=utf8,uid=1000,gid=1000
  ```

  State is `mounted, healthy`, `mounted, NOT RESPONDING` or `not mounted`; the last
  column is the options retained in the configuration, not the kernel's.
  The last column shows the options retained in the configuration — the decision you
  made — and not the kernel's per-mount string (`rsize`, `addr`, `sec`, `proto`…),
  which changes on every mount and buries the useful part.
  It also works without root: the configuration is then unreadable, so only the real
  mounts are listed, with a note.
- **`setup`**: the configuration wizard, now inside the same file. It reads the
  current values as defaults, detects the interfaces and each server's MAC, writes
  `/etc/smart-mount/config` (0640, previous one kept as `.bak`), and neutralises any
  `fstab` entry that would double-mount a share. Needs root:
  `sudo nas-smartmount.sh setup`, or `pkexec nas-smartmount.sh setup` from a desktop
  session. `smart-mount-setup` remains as a two-line wrapper for the old habit.
- **`--version`**: one line, `smart-mount 1.10`, and it does not read the
  configuration — the line to paste into a bug report.
- **`--help`**: short French help with the configuration format and the exit codes.
  That is deliberate: logs, errors and `show` output are in English (they end up in
  bug reports), while the help, the man page and this documentation are for the human
  sitting in front of the terminal.
- **`show --json`**: the same information as JSON, for a script or a graphical front
  end. Each share carries `options` (as retained) and `runtime_options` (as reported
  by the kernel), `state`, `mounted` and `healthy`. No `jq` dependency: the shell
  builds the document, so it works on a machine where nothing else is installed.

Exit codes: `1` mount failed, `2` unmount failed, `3` invalid usage or invalid share
record, `4` a share has no target MAC, `5` missing runtime dependency (the message names
it), `122` missing config or no share configured, `127` server unreachable before
mounting.

## Requirements

`bash`, `nfs-utils`, `whiptail`, NetworkManager, `systemd`, `coreutils` (`timeout`),
`iproute2` (`ip neigh`, used for the identity check), `util-linux` (`logger`), and
`cifs-utils` (`mount.cifs`) if you configure a CIFS share.
`iw` is recommended — it reads the SSID of the active link reliably; without it the
script falls back to `nmcli`.

They are **checked**, not just documented: `make install` runs `make deps` first, and
the script refuses to mount when a hard dependency is missing — exit code 5, one line
naming the command, so the systemd unit turns red instead of degrading silently.
`mount.cifs` is only required when a CIFS share is configured. `unmount` is never
blocked, and `logger` is optional (logs fall back to stderr).

## Install

```
git clone https://github.com/jotenakis2/smart-mount && cd smart-mount && sudo make install
```

`make install` runs `make deps` (runtime dependencies) and `make check` first (syntax,
`shellcheck`, test suite), then the configuration wizard (values land in
`/etc/smart-mount/config`, mode 0600), copies the two hooks to
`/etc/NetworkManager/dispatcher.d`, the script to `/usr/local/bin` and the units to
`/etc/systemd/system`, then enables the timer.

The wizard asks how many shares you want, their type (NFS or CIFS), then the details of
each one, and finally the Wi-Fi SSID and the two interface names.

## Configuration

`/etc/smart-mount/config`, sourced by the script (root only, mode 0600). One record per
share, seven fields separated by `|`:

```
type|server|share|mount point|options|mac|credentials
```

```
WIFI_NAME="HomeWiFi"
WIFI_IFACE="wlan0"
LAN_IFACE="eth0"

SHARES=(
  "nfs|192.168.50.85|/volume1/share|/media/NAS|nodev,nosuid,noexec,noatime,lazytime|b0:83:fe:52:1b:6d|"
  "cifs|192.168.50.90|public|/media/PUB|vers=3.0,iocharset=utf8|d8:8c:79:0c:a9:70|/etc/smart-mount/credentials-2"
)
```

- **type**: `nfs` or `cifs`;
- **server**: IP address (or hostname) of the server;
- **share**: the exported path for NFS, the share name for CIFS;
- **options**: passed as `-o` to `mount` (empty is allowed);
- **mac**: the server's MAC address — without it the share is never mounted;
- **credentials**: CIFS only, path to a credentials file (empty otherwise).
- **networks** (optional): where this share may mount, separated by `;` or `,`.
  Empty means the global `WIFI_NAME`; a single `*` means any network, the MAC alone
  deciding. A share can therefore ignore your home Wi-Fi, accept two of them, or be
  reachable from anywhere as long as the server is there. An SSID must not contain
  `;` or `,` — that is the limit of the field.

A configuration file from an earlier version (flat `NFS_SERVER_IP`, `MOUNT_POINT`, …) is
still read: it is treated as a single NFS share. Re-run `sudo make install` to migrate
to the new format.

### CIFS credentials

The wizard asks for an optional user name, password and domain, and writes them to
`/etc/smart-mount/credentials-<n>` (mode 0600). The path is stored in the record and
passed as `credentials=…`, **never as `-o username=…,password=…`**: the command line is
readable by every user through `ps`. Leave the user name empty for a guest/anonymous
share.

### Finding the MAC address

- while the server is reachable: `ip neigh show <server_ip>`;
- or in the NAS administration interface, or in the router's DHCP lease list;
- `setup.sh` looks in the ARP table first and only pings as a fallback. If it still
  cannot find it, it explains the procedure and leaves the field empty: you then edit
  the 6th field of that share in `/etc/smart-mount/config` (or re-run
  `sudo make install`). That share does not mount until it is set.

### About `/etc/fstab`

**No `fstab` entry is required.** smart-mount mounts each share itself
(`mount -t nfs|cifs -o <options> <spec> <mount point>`), creates the mount point if
needed, and never reads `/etc/fstab` at runtime.

The wizard touches `fstab` for two reasons only, and both leave it untouched when
nothing matches:

1. **Defaults.** An existing `nfs`/`nfs4` (or `cifs`/`smb3`) entry is offered as
   pre-filled values: the server for the first share, and the mount point and options
   for any share whose `server:share` (or `//server/share`) matches exactly.
2. **Conflict removal.** When an entry matches *exactly* the configured server, share
   and mount point, its options are rewritten to add `noauto` (and drop
   `x-systemd.automount`), so the boot does not mount the same share a second time
   behind smart-mount's back. All shares are handled in a single pass, with one backup:
   `/etc/fstab.smart-mount.bak.<date>`. Every other line — and any entry that does not
   match — is left alone.

```
# before
192.168.50.85:/volume1/share  /media/NAS  nfs4  rw,relatime,x-systemd.automount  0 0
# after
192.168.50.85:/volume1/share  /media/NAS  nfs4  rw,relatime,noauto  0 0
```

Keeping an entry is a valid choice — handy if other tools or systemd units need to know
about the share — as long as it does not auto-mount at boot: with `noauto`, boot
mounting is smart-mount's job (hook + timer). `make uninstall` leaves the rewrite in
place; see Uninstall.

## Language

Log lines, errors, `show` and the wizard follow the locale (`LC_ALL`, `LC_MESSAGES`,
`LANG`; two letters are enough), English by default — a journal pasted into an issue
stays readable. `SMARTMOUNT_LANG=fr` forces French whatever the locale says. The table
headers and states are translated; **`show --json` values are not** (a script must not
depend on who calls it).

The man page exists in both languages: `man 8 nas-smartmount` picks the French page
when your locale is French, the English one otherwise.

## Running it without root

`show` already works as a normal user. For the other verbs, `pkexec` is bound to a
dedicated polkit action (`org.jotenakis.smartmount.manage`, installed with the rest):
`pkexec nas-smartmount.sh apply` asks for authentication in the desktop session
instead of requiring a `sudo` terminal. It is not a privilege bypass — the mount
specification comes from `/etc/smart-mount/config`, which stays `root:root`.
Polkit reads actions from `/usr/share`, `/usr/local/share` and `/etc`; if the action
does not show up right after installation (`pkaction --action-id
org.jotenakis.smartmount.manage`), `sudo systemctl restart polkit` once.

If you want `show` to read the configuration too, give it a group of its own:

```
sudo groupadd -r smartmount
sudo usermod -aG smartmount "$USER"
sudo chgrp smartmount /etc/smart-mount/config    # mode 0640
```

## Upgrading from 1.9 and earlier

The command is now `nas-smartmount.sh` (it handles SMB too). `make install` keeps a
`nfs-smartmount.sh` symlink, and the unit, the two hooks and the polkit action are
rewritten for the real `BINDIR`; a packaged install in `/usr` therefore no longer
points at `/usr/local/bin`. `man nfs-smartmount` becomes `man nas-smartmount`.

The wizard moved from `setup.sh` into the main script: one file, one message
catalogue, one place that knows the record format. `smart-mount-setup` still works.

## Tests

```
make check
```

Runs `bash -n`, `shellcheck`, and 77 scenarios / 201 assertions with simulated commands
(`tests/run.sh`): nominal mount, server rebooted, busy mount point, unreadable SSID,
unreachable server, flaky health check, expired `mountpoint`, `nmcli` fallback, SSID
containing `:`, missing MAC (refusal, code 4), missing dependency (refusal, code 5, and
unmount still working), matching SSID without an ARP entry or with a different MAC
(refusal + identity log), Ethernet confirmed without Wi-Fi, foreign Wi-Fi + confirmed
Ethernet (and the reverse), MAC compared case-insensitively, empty `LAN_IFACE`,
dry-run, both hooks (which must trigger `apply` and never unmount on their own), several
shares at once (one present, one absent; both present with different types), a CIFS
mount, CIFS credentials (passed once, no duplicate), an invalid share type, an empty
share list, the `show` output (healthy, mute, unmounted, foreign mount, unreadable
configuration, retained options shown and kernel options hidden), `show --json`
(valid document, `mounted`, `healthy`, credentials path never exposed), the accepted
networks per share (refusal, list, `*`), and the forced NFS unmount (`umount -f` on
NFS, never on CIFS). Nothing touches the real system.

The identity check (ARP table + expected MAC) has been validated in dry-run against a
real ARP entry. What is still not validated: a physical Ethernet link, and a real CIFS
server (`mount.cifs` is exercised through a stub only).

## Known limits

- The MAC is read from the ARP table of the link. If a server sits behind a router
  (another subnet or a VLAN), the MAC seen is the router's — that is the one to put in
  that share's record.
- On the Wi-Fi side, a cold ARP cache needs one ping to resolve; a server that filters
  ICMP must already be present in the ARP table, otherwise the identity cannot be
  confirmed and the share will not mount.
- Default NFS options include neither `soft` nor `timeo`: a hard mount plus a server
  that disappears can freeze accesses for as long as the RPC timeouts last. The hooks
  unmount on network loss, the timer repairs dead mounts, and the share options are
  yours to tune.
- Interface names are global, not per share: one Wi-Fi interface and one LAN interface
  per machine. Only the list of accepted networks is per share.
- `umount -f` (abandon pending RPCs) is only used on NFS. On CIFS it has no such
  effect and can fail where a lazy unmount succeeds, so the lazy fallback applies.

## Packaging

`PKGBUILD` and `smart-mount.install` build an Arch package (`make install` under
`DESTDIR`, with no interactive configuration during the build):

```
makepkg -si          # then: sudo smart-mount-setup
```

The repository copy of `PKGBUILD` uses `sha256sums=('SKIP')`, because it also travels
*inside* the tarball it downloads and cannot carry its own hash. The copy published on
the AUR must carry the real one (`makepkg -g >> PKGBUILD`), and `.SRCINFO` must be
regenerated to match.

The rest of the packaging work is the same on any distribution: install
`nas-smartmount.8`, `org.jotenakis.smartmount.policy`, the two NetworkManager hooks,
the unit and the timer. CI replays the test suite on Debian, Ubuntu, Fedora and Arch
containers (`.github/workflows/check.yml`), because the failure modes we care about
are bash and text-parsing differences, not `mount` itself.

## Uninstall

```
cd smart-mount && sudo make uninstall
```

Removes the hooks, the script and the units, then disables the timer. The configuration
file, the CIFS credentials files and the `fstab` adjustment are left in place on purpose
— check `/etc/smart-mount/` and `/etc/fstab` if you want to undo them by hand.

## TODO

Nothing open on the functional side. Distribution side: publish the package on the
AUR, then a `.deb` and an `.rpm` from the same files.
