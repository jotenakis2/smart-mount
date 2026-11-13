# smart-mount

Monte automatiquement un partage NFS local quand la machine est sur le bon réseau —
et le démonte, ou le répare, quand la situation change.

[English version](README.md)

## Ce que ça fait

Deux liens sont acceptés, et chacun est identifié par **le réseau et le serveur** :

- **Wi-Fi** : le SSID configuré *et* l'adresse MAC du serveur NFS, lue dans la table
  ARP de l'interface Wi-Fi ;
- **Ethernet** : le même contrôle de MAC, sur l'interface LAN configurée.

Le SSID seul ne suffit pas : un point d'accès portant le même nom ailleurs ne doit
pas faire monter le partage. La MAC est l'identité du serveur, et elle est
obligatoire — sans elle, rien ne monte.

**Une seule décision, à un seul endroit.** `nfs-smartmount.sh apply` porte toute la
politique. Les deux hooks NetworkManager et le timer systemd ne décident plus rien :
ils déclenchent cette politique. C'est ce qui empêche le hook Wi-Fi et le hook
Ethernet de défaire mutuellement leur travail quand les deux liens sont actifs
(portable docké, Wi-Fi sur un autre réseau…).

## Comportement

```
nfs-smartmount.sh {mount|unmount|apply}
```

| situation | ce que fait `apply` |
|---|---|
| SSID correspond **et** MAC du NAS confirmée sur `WIFI_IFACE` | monte |
| sinon, MAC du NAS confirmée sur `LAN_IFACE` | monte |
| sinon, un des deux liens est illisible | rien (une lecture ratée ne doit pas détruire un partage qui fonctionne) |
| sinon, les deux liens écartés sans ambiguïté | démonte |
| `NFS_SERVER_MAC` vide | refuse de monter, code de sortie 4 |

- **auto-réparation** : à chaque passage, un montage existant est testé
  (`stat -f` + lecture du répertoire, bornés par `timeout 5`). S'il ne répond plus
  — NAS redémarré, handles obsolètes — il est démonté puis remonté. Un second test
  2 s plus tard évite de détruire un montage sain sur une coupure de deux secondes.
- **démontage robuste** : `umount` borné par `timeout 10`, puis repli `umount -l`
  si le point est occupé (shell ou IDE ouvert dans le partage). Code 2 seulement si
  les deux échouent.
- **mode dry-run** : `SMARTMOUNT_DRY_RUN=1` évalue et journalise la décision sans
  monter ni démonter. C'est ainsi qu'on contrôle le chemin Ethernet sur une machine
  qui n'en a pas :
  `sudo SMARTMOUNT_DRY_RUN=1 /usr/local/bin/nfs-smartmount.sh apply`.

Codes de sortie : `1` échec de montage, `2` échec de démontage, `3` usage invalide,
`4` aucune MAC cible configurée, `5` dépendance manquante (le message la nomme),
`122` fichier de configuration absent, `127` serveur injoignable avant le montage.

## Dépendances

`bash`, `nfs-utils`, `whiptail`, NetworkManager, `systemd`, `coreutils` (`timeout`),
`iproute2` (`ip neigh`, utilisé pour le contrôle d'identité), `util-linux` (`logger`).
`iw` est recommandé — il lit le SSID du lien actif de façon fiable ; sans lui le
script retombe sur `nmcli`.

Elles sont **vérifiées**, pas seulement documentées : `make install` lance `make deps`
d'abord, et le script refuse de monter si une dépendance dure manque (`mount.nfs`,
`ip`, `ping`, `timeout`) — code de sortie 5, une ligne qui nomme la commande, pour que
l'unité systemd passe en échec au lieu de se dégrader en silence. `unmount` n'est
jamais bloqué, et `logger` est facultatif (repli sur stderr).

## Installation

```
git clone https://github.com/jotenakis2/smart-mount && cd smart-mount && sudo make install
```

`make install` exécute d'abord `make deps` (dépendances d'exécution) et `make check`
(syntaxe, `shellcheck`, suite de tests), puis le questionnaire de configuration (les
valeurs atterrissent dans `/etc/smart-mount/config`, mode 0600), copie les deux hooks
dans `/etc/NetworkManager/dispatcher.d`, le script dans `/usr/local/bin` et les unités
dans `/etc/systemd/system`, puis active le timer.

Le questionnaire utilise `/etc/fstab` et la connexion active comme valeurs par
défaut, détecte l'adresse MAC du serveur, et ajuste une entrée `fstab` en conflit
pour éviter un double montage au démarrage (une sauvegarde est conservée) — voir
ci-dessous.

## Configuration

`/etc/smart-mount/config`, sourcé par le script (root uniquement, mode 0600) :

```
NFS_SERVER_IP="192.168.50.85"
NFS_SHAREDPATH="/volume1/share"
MOUNT_POINT="/media/NAS"
NFS_OPTS="nodev,nosuid,noexec,noatime,lazytime"

WIFI_NAME="MaisonDuRuet"
WIFI_IFACE="wlan0"

NFS_SERVER_MAC="b0:83:fe:52:1b:6d"
LAN_IFACE="eth0"
```

### Trouver l'adresse MAC

- quand le NAS est joignable : `ip neigh show <IP_DU_NAS>` ;
- ou dans l'interface d'administration du NAS, ou dans la liste des baux DHCP de la
  box ;
- `setup.sh` regarde la table ARP d'abord et ne ping qu'en secours. S'il ne la trouve
  toujours pas, il explique la procédure et laisse le champ vide : il faut alors
  renseigner `NFS_SERVER_MAC` dans `/etc/smart-mount/config` (ou relancer
  `sudo make install`). Rien ne montera tant que ce n'est pas fait.

### À propos de `/etc/fstab`

**Aucune entrée `fstab` n'est nécessaire.** smart-mount monte le partage lui-même
(`mount -t nfs -o <NFS_OPTS> <serveur>:<partage> <point>`), crée le point de montage
si besoin, et ne lit jamais `/etc/fstab` à l'exécution.

Le questionnaire ne touche à `fstab` que dans deux cas, et il ne modifie rien quand
aucune entrée ne correspond :

1. **Valeurs par défaut.** Une entrée `nfs`/`nfs4` existante — la première trouvée,
   quel que soit le serveur — sert de valeur pré-remplie pour le serveur, le partage,
   le point de montage et les options. Sans entrée, ces champs sont simplement vides.
2. **Suppression d'un conflit.** Si une entrée correspond *exactement* au
   `serveur:partage` configuré **et** au point de montage, ses options sont réécrites
   pour ajouter `noauto` (et retirer `x-systemd.automount`), afin que le démarrage ne
   monte pas le même partage une seconde fois dans le dos de smart-mount. Une
   sauvegarde est écrite à côté : `/etc/fstab.smart-mount.bak.<date>`. Toutes les
   autres lignes — et toute entrée qui ne correspond pas — restent intactes.

```
# avant
192.168.50.85:/volume1/share  /media/NAS  nfs4  rw,relatime,x-systemd.automount  0 0
# après
192.168.50.85:/volume1/share  /media/NAS  nfs4  rw,relatime,noauto  0 0
```

Garder une entrée est un choix valable — pratique si d'autres outils ou unités systemd
doivent connaître le partage — à condition qu'elle ne se monte pas automatiquement au
démarrage : avec `noauto`, c'est smart-mount qui monte au boot (hook + timer).
`make uninstall` laisse cette réécriture en place ; voir Désinstallation.

## Tests

```
make check
```

Lance `bash -n`, `shellcheck` et 42 scénarios / 110 assertions avec des commandes
simulées (`tests/run.sh`) : montage nominal, NAS redémarré, point de montage occupé,
SSID illisible, serveur injoignable, test de santé instable, `mountpoint` expiré,
repli `nmcli`, SSID contenant `:`, MAC absente (refus, code 4), dépendance absente
(refus, code 5, et démontage toujours possible), SSID correct sans entrée ARP ou avec
une MAC différente (refus + log d'identité), Ethernet confirmé sans Wi-Fi, Wi-Fi
étranger + Ethernet confirmé (et l'inverse), MAC comparée sans tenir compte de la
casse, `LAN_IFACE` vide, mode dry-run, et les deux hooks (qui doivent déclencher
`apply` et jamais démonter de leur côté). Aucun accès au système réel.

Le contrôle d'identité (table ARP + MAC attendue) a été validé en dry-run contre une
entrée ARP réelle, en Wi-Fi comme en Ethernet. Ce qui reste non validé : le
raccordement physique Ethernet, c'est-à-dire le nom d'interface et les évènements
NetworkManager sur ce lien.

## Limites connues

- La MAC est lue dans la table ARP du lien. Si le NAS est derrière un routeur (autre
  sous-réseau ou VLAN), la MAC vue est celle du routeur : c'est elle qu'il faut
  configurer.
- Côté Wi-Fi, un cache ARP froid demande un ping pour se remplir ; un serveur qui
  filtre l'ICMP doit déjà être présent dans la table ARP, sinon l'identité ne peut
  pas être confirmée et le partage ne montera pas.
- Les options NFS par défaut n'incluent ni `soft` ni `timeo` : un montage dur avec un
  serveur qui disparaît peut figer les accès aussi longtemps que durent les timeouts
  RPC. Les hooks démontent à la perte du réseau, le timer répare les montages morts,
  et `NFS_OPTS` vous appartient.

## Désinstallation

```
cd smart-mount && sudo make uninstall
```

Supprime les hooks, le script et les unités, puis désactive le timer. Le fichier de
configuration et l'ajustement de `fstab` sont laissés en place volontairement —
vérifiez `/etc/smart-mount/config` et `/etc/fstab` si vous voulez les défaire à la
main.

## TODO

SMB
