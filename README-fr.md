# smart-mount

Monte automatiquement des partages locaux quand la machine est sur le bon réseau — et
les démonte, ou les répare, quand la situation change.

[English version](README.md)

## Ce que ça fait

Autant de partages **NFS** et/ou **CIFS (SMB)** que voulu, chacun avec son point de
montage. Deux liens sont acceptés, et chacun est identifié par **le réseau et le
serveur** :

- **Wi-Fi** : le SSID configuré *et* l'adresse MAC du serveur, lue dans la table ARP de
  l'interface Wi-Fi ;
- **Ethernet** : le même contrôle de MAC, sur l'interface LAN configurée.

Le SSID seul ne suffit pas : un point d'accès portant le même nom ailleurs ne doit pas
faire monter un partage. La MAC est l'identité du serveur, et elle est obligatoire — un
partage sans MAC cible n'est jamais monté.

**Une seule décision, à un seul endroit.** `nas-smartmount.sh apply` porte toute la
politique, pour chaque partage. Les deux hooks NetworkManager et le timer systemd ne
décident plus rien : ils déclenchent cette politique. C'est ce qui empêche le hook Wi-Fi
et le hook Ethernet de défaire mutuellement leur travail quand les deux liens sont
actifs (portable docké, Wi-Fi sur un autre réseau…).

## Comportement

```
nas-smartmount.sh {show [--json]|mount|unmount|apply|setup|--version|--help}
```

Pour chaque partage configuré, indépendamment :

| situation | ce que fait `apply` |
|---|---|
| SSID correspond **et** MAC du serveur confirmée sur `WIFI_IFACE` | monte |
| sinon, MAC du serveur confirmée sur `LAN_IFACE` | monte |
| sinon, un des deux liens est illisible | rien (une lecture ratée ne doit pas détruire un partage qui fonctionne) |
| sinon, les deux liens écartés sans ambiguïté | démonte |
| le partage n'a pas de MAC cible | refuse de le monter, code de sortie 4 |

Un partage dont le serveur n'est pas sur le réseau courant reste simplement démonté ;
les autres partages ne sont pas affectés.

- **auto-réparation** : à chaque passage, un montage existant est testé (`stat -f` +
  lecture du répertoire, bornés par `timeout 5`). S'il ne répond plus — serveur
  redémarré, handles obsolètes — il est démonté puis remonté. Un second test 2 s plus
  tard évite de détruire un montage sain sur une coupure de deux secondes.
- **démontage robuste** : `umount` borné par `timeout 10`, puis repli `umount -l` si le
  point est occupé (shell ou IDE ouvert dans le partage). Code 2 seulement si les deux
  échouent.
- **mode dry-run** : `SMARTMOUNT_DRY_RUN=1` évalue et journalise la décision pour chaque
  partage sans monter ni démonter. C'est ainsi qu'on contrôle un chemin réseau sur une
  machine qui n'en a pas :
  `sudo SMARTMOUNT_DRY_RUN=1 /usr/local/bin/nas-smartmount.sh apply`.
- **`show`** : tableau en lecture seule des partages configurés et de ce qui est
  réellement monté, plus tout montage NFS/CIFS qui ne vient pas de la configuration :

  ```
  $ sudo nas-smartmount.sh show
  TYPE  MOUNT POINT     SOURCE                             STATE             OPTIONS
  nfs   /media/NAS      192.168.50.85:/media/diskusb/data  mounted, healthy  nodev,nosuid,noexec,noatime,lazytime
  cifs  /media/NAS-smb  //192.168.50.85/usbdisk_data       mounted, healthy  guest,iocharset=utf8,uid=1000,gid=1000
  ```

  L'état vaut `mounted, healthy`, `mounted, NOT RESPONDING` ou `not mounted` (la
  sortie est en anglais, comme le journal).
  La dernière colonne affiche les options **retenues dans la configuration** — ta
  décision — et non la chaîne que le noyau rapporte pour chaque montage (`rsize`,
  `addr`, `sec`, `proto`…), qui change à chaque fois et noie l'information utile.
  Il fonctionne aussi sans root : la configuration est alors illisible, seuls les
  montages réels sont listés, avec une note.
- **`setup`** : le questionnaire, désormais dans le même fichier. Il reprend la
  configuration existante comme valeurs par défaut, détecte les interfaces et la MAC
  de chaque serveur, écrit `/etc/smart-mount/config` (0640, l'ancienne conservée en
  `.bak`) et neutralise les entrées `fstab` qui monteraient un partage en double.
  Exige root : `sudo nas-smartmount.sh setup`, ou `pkexec nas-smartmount.sh setup`
  depuis une session graphique. `smart-mount-setup` reste comme enveloppe de deux
  lignes pour l'habitude.
- **`--version`** : une ligne, `smart-mount 1.10`, sans lire la configuration — la
  ligne à coller dans un rapport de bug.
- **`--help`** : aide courte en français, avec le format de configuration et les codes
  de sortie. C'est volontaire : journal, erreurs et sortie de `show` sont en anglais
  (ces lignes finissent dans un rapport de bug), alors que l'aide, la page de man et
  cette documentation s'adressent à l'humain devant le terminal.
- **`show --json`** : la même information en JSON, pour un script ou une interface
  graphique. Chaque partage porte `options` (retenues) et `runtime_options` (celles
  du noyau), `state`, `mounted` et `healthy`. Aucune dépendance à `jq` : le document
  est construit par le shell, et fonctionne sur une machine où rien d'autre n'est
  installé.

Codes de sortie : `1` échec de montage, `2` échec de démontage, `3` usage invalide ou
enregistrement de partage invalide, `4` un partage n'a pas de MAC cible, `5` dépendance
manquante (le message la nomme), `122` configuration absente ou aucun partage, `127`
serveur injoignable avant le montage.

## Dépendances

`bash`, `nfs-utils`, `whiptail`, NetworkManager, `systemd`, `coreutils` (`timeout`),
`iproute2` (`ip neigh`, utilisé pour le contrôle d'identité), `util-linux` (`logger`), et
`cifs-utils` (`mount.cifs`) si vous configurez un partage CIFS.
`iw` est recommandé — il lit le SSID du lien actif de façon fiable ; sans lui le script
retombe sur `nmcli`.

Elles sont **vérifiées**, pas seulement documentées : `make install` lance `make deps`
d'abord, et le script refuse de monter si une dépendance dure manque — code de sortie 5,
une ligne qui nomme la commande, pour que l'unité systemd passe en échec au lieu de se
dégrader en silence. `mount.cifs` n'est exigé que si un partage CIFS existe. `unmount`
n'est jamais bloqué, et `logger` est facultatif (repli sur stderr).

## Installation

```
git clone https://github.com/jotenakis2/smart-mount && cd smart-mount && sudo make install
```

`make install` exécute d'abord `make deps` (dépendances d'exécution) et `make check`
(syntaxe, `shellcheck`, suite de tests), puis le questionnaire de configuration (les
valeurs atterrissent dans `/etc/smart-mount/config`, mode 0600), copie les deux hooks
dans `/etc/NetworkManager/dispatcher.d`, le script dans `/usr/local/bin` et les unités
dans `/etc/systemd/system`, puis active le timer.

Le questionnaire demande combien de partages vous voulez, leur type (NFS ou CIFS), puis
les détails de chacun, et enfin le SSID Wi-Fi et les deux noms d'interface.

## Configuration

`/etc/smart-mount/config`, sourcé par le script (root uniquement, mode 0600). Un
enregistrement par partage, sept champs séparés par `|` :

```
type|serveur|partage|point de montage|options|mac|identifiants
```

```
WIFI_NAME="MaisonDuRuet"
WIFI_IFACE="wlan0"
LAN_IFACE="eth0"

SHARES=(
  "nfs|192.168.50.85|/volume1/share|/media/NAS|nodev,nosuid,noexec,noatime,lazytime|b0:83:fe:52:1b:6d|"
  "cifs|192.168.50.90|public|/media/PUB|vers=3.0,iocharset=utf8|d8:8c:79:0c:a9:70|/etc/smart-mount/credentials-2"
)
```

- **type** : `nfs` ou `cifs` ;
- **serveur** : adresse IP (ou nom d'hôte) du serveur ;
- **partage** : le chemin exporté en NFS, le nom du partage en CIFS ;
- **options** : passées en `-o` à `mount` (vide autorisé). `nodev`, `nosuid` et
  `noexec` sont appliqués par le noyau, en NFS comme en CIFS ; `noatime` et `lazytime`
  sont **ignorés par `mount.cifs`** (le montage reste en `relatime`) — côté CIFS, les
  options utiles sont `vers=`, `iocharset=`, `uid=`, `gid=`, `file_mode=`, `dir_mode=` ;
  le questionnaire propose d'ajouter `nodev,nosuid,noexec` quand ta ligne ne les a pas,
  et demande avant : un partage réseau qui autorise l'exécution ou les binaires setuid
  est un risque qu'on n'a aucune raison d'accepter par défaut ;
- **mac** : l'adresse MAC du serveur — sans elle, le partage n'est jamais monté ;
- **identifiants** : CIFS uniquement, chemin du fichier d'identifiants (vide sinon) ;
- **réseaux** (facultatif) : où ce partage peut monter, séparés par `;` ou `,`.
  Vide = le SSID global `WIFI_NAME` ; un seul `*` = n'importe quel réseau, la MAC
  décidant seule. Un partage peut donc ignorer ton Wi-Fi domestique, en accepter
  deux, ou être joignable partout tant que le serveur est là. Un SSID ne doit pas
  contenir `;` ni `,` — c'est la limite du champ.

Un fichier de configuration d'une version antérieure (variables à plat
`NFS_SERVER_IP`, `MOUNT_POINT`…) reste lisible : il est traité comme un seul partage
NFS. Relancez `sudo make install` pour passer au nouveau format.

### Deux identités sur un partage CIFS

Ce ne sont pas les mêmes, et les confondre est la façon dont un partage finit lisible par
personne :

- **`username=` / `password=` / `domain=`** — le compte SMB, celui qui s'authentifie
  auprès du serveur. Stocké dans le fichier d'identifiants.
- **`uid=` / `gid=`** — le propriétaire local des fichiers une fois montés. Sans eux,
  `mount.cifs` monte en `uid=0`, donc seul root peut écrire dans le partage.

Le questionnaire demande les deux : le compte SMB quand le partage n'est pas invité, et
le propriétaire local (`uid:gid`, par défaut celui qui a lancé `sudo` ou `pkexec`, lu
dans `SUDO_UID` / `PKEXEC_UID`). Il écrit `uid=`/`gid=` dans les options, sans dupliquer
ce qui y est déjà.

### Identifiants CIFS

Le questionnaire demande un utilisateur, un mot de passe et un domaine facultatifs, et
les écrit dans `/etc/smart-mount/credentials-<n>` (mode 0600). Le chemin est stocké dans
l'enregistrement et passé en `credentials=…`, **jamais en `-o username=…,password=…`** :
la ligne de commande est lisible par tous les utilisateurs via `ps`. Laissez
l'utilisateur vide pour un partage invité/anonyme.

### Trouver l'adresse MAC

- quand le serveur est joignable : `ip neigh show <IP_DU_SERVEUR>` ;
- ou dans l'interface d'administration du NAS, ou dans la liste des baux DHCP de la box ;
- `setup.sh` regarde la table ARP d'abord et ne ping qu'en secours. S'il ne la trouve
  toujours pas, il explique la procédure et laisse le champ vide : il faut alors éditer
  le 6e champ de ce partage dans `/etc/smart-mount/config` (ou relancer
  `sudo make install`). Ce partage ne monte pas tant que ce n'est pas fait.

### À propos de `/etc/fstab`

**Aucune entrée `fstab` n'est nécessaire.** smart-mount monte chaque partage lui-même
(`mount -t nfs|cifs -o <options> <spécification> <point de montage>`), crée le point de
montage si besoin, et ne lit jamais `/etc/fstab` à l'exécution.

Le questionnaire ne touche à `fstab` que dans deux cas, et il ne modifie rien quand
aucune entrée ne correspond :

1. **Valeurs par défaut.** Une entrée `nfs`/`nfs4` (ou `cifs`/`smb3`) existante sert de
   valeur pré-remplie : le serveur pour le premier partage, et le point de montage avec
   les options pour tout partage dont le `serveur:partage` (ou `//serveur/partage`)
   correspond exactement.
2. **Suppression d'un conflit.** Si une entrée correspond *exactement* au serveur, au
   partage et au point de montage configurés, ses options sont réécrites pour ajouter
   `noauto` (et retirer `x-systemd.automount`), afin que le démarrage ne monte pas le
   même partage une seconde fois dans le dos de smart-mount. Tous les partages sont
   traités en une seule passe, avec une seule sauvegarde :
   `/etc/fstab.smart-mount.bak.<date>`. Toutes les autres lignes — et toute entrée qui ne
   correspond pas — restent intactes.

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

## Langue

Journal, erreurs, `show` et questionnaire suivent la locale (`LC_ALL`, `LC_MESSAGES`,
`LANG` ; deux lettres suffisent), anglais par défaut — un journal collé dans une issue
reste lisible. `SMARTMOUNT_LANG=fr` force le français quelle que soit la locale. Les
en-têtes et les états du tableau sont traduits ; **les valeurs de `show --json` ne le
sont pas** (un script ne doit pas dépendre de qui l'appelle).

La page de man existe dans les deux langues : `man 8 nas-smartmount` prend la page
française quand la locale est française, l'anglaise sinon.

## Sans root

`show` fonctionne déjà en tant qu'utilisateur. Pour les autres verbes, `pkexec` est
relié à une action polkit dédiée (`org.jotenakis.smartmount.manage`, installée avec le
reste) : `pkexec nas-smartmount.sh apply` demande l'authentification dans la session
graphique au lieu d'exiger un terminal `sudo`. Ce n'est pas un contournement de
privilège — la spécification montée vient de `/etc/smart-mount/config`, qui reste
`root:root`.
Polkit lit ses actions dans `/usr/share`, `/usr/local/share` et `/etc` ; si l'action
n'apparaît pas juste après l'installation (`pkaction --action-id
org.jotenakis.smartmount.manage`), un `sudo systemctl restart polkit` suffit.

Pour que `show` lise aussi la configuration, donne-lui un groupe :

```
sudo groupadd -r smartmount
sudo usermod -aG smartmount "$USER"
sudo chgrp smartmount /etc/smart-mount/config    # mode 0640
```

## Depuis la 1.9 et avant

La commande s'appelle maintenant `nas-smartmount.sh` (elle gère aussi le SMB).
`make install` conserve un lien `nfs-smartmount.sh`, et l'unité, les deux hooks et
l'action polkit sont réécrits pour le `BINDIR` réel : une installation en paquet dans
`/usr` ne pointe donc plus vers `/usr/local/bin`. `man nfs-smartmount` devient
`man nas-smartmount`.

Le questionnaire quitte `setup.sh` pour le script principal : un fichier, un catalogue
de messages, un seul endroit qui connaît le format des enregistrements.
`smart-mount-setup` fonctionne toujours.

## Tests

```
make check
```

Lance `bash -n`, `shellcheck` et 77 scénarios / 201 assertions avec des commandes
simulées (`tests/run.sh`) : montage nominal, serveur redémarré, point de montage occupé,
SSID illisible, serveur injoignable, test de santé instable, `mountpoint` expiré, repli
`nmcli`, SSID contenant `:`, MAC absente (refus, code 4), dépendance absente (refus,
code 5, et démontage toujours possible), SSID correct sans entrée ARP ou avec une MAC
différente (refus + log d'identité), Ethernet confirmé sans Wi-Fi, Wi-Fi étranger +
Ethernet confirmé (et l'inverse), MAC comparée sans tenir compte de la casse, `LAN_IFACE`
vide, mode dry-run, les deux hooks (qui doivent déclencher `apply` et jamais démonter de
leur côté), plusieurs partages à la fois (un présent, un absent ; les deux présents avec
des types différents), un montage CIFS, les identifiants CIFS (transmis une seule fois,
sans doublon), un type de partage invalide, une liste de partages vide, un ancien
fichier de configuration à plat, la sortie de `show` (sain, muet, démonté, montage
hors configuration, configuration illisible, options retenues affichées et options du
noyau masquées), `show --json` (validité du document, `mounted`, `healthy`, chemin des
identifiants jamais exposé), les réseaux autorisés par partage (refus, liste, `*`), et
le démontage forcé NFS (`umount -f` sur NFS, jamais sur CIFS). Aucun accès au système
réel.

Le contrôle d'identité (table ARP + MAC attendue) a été validé en dry-run contre une
entrée ARP réelle. Ce qui reste non validé : un lien Ethernet physique, et un vrai
serveur CIFS (`mount.cifs` n'est exercé qu'à travers un stub).

## Limites connues

- La MAC est lue dans la table ARP du lien. Si un serveur est derrière un routeur (autre
  sous-réseau ou VLAN), la MAC vue est celle du routeur : c'est elle qu'il faut mettre
  dans l'enregistrement de ce partage.
- Côté Wi-Fi, un cache ARP froid demande un ping pour se remplir ; un serveur qui filtre
  l'ICMP doit déjà être présent dans la table ARP, sinon l'identité ne peut pas être
  confirmée et le partage ne montera pas.
- Les options NFS par défaut n'incluent ni `soft` ni `timeo` : un montage dur avec un
  serveur qui disparaît peut figer les accès aussi longtemps que durent les timeouts RPC.
  Les hooks démontent à la perte du réseau, le timer répare les montages morts, et les
  options des partages vous appartiennent.
- Les noms d'interface sont globaux, pas par partage : une interface Wi-Fi et une
  interface LAN par machine. Seule la liste des réseaux acceptés est par partage.
- `umount -f` (abandon des RPC en attente) n'est utilisé que sur NFS. Sur CIFS il n'a
  pas cet effet et peut échouer là où un démontage paresseux réussit ; c'est donc le
  repli paresseux qui s'applique.

## Paquet

`PKGBUILD` et `smart-mount.install` construisent un paquet Arch (`make install` sous
`DESTDIR`, sans questionnaire pendant la construction) :

```
makepkg -si          # puis : sudo smart-mount-setup
```

La copie du `PKGBUILD` dans le dépôt utilise `sha256sums=('SKIP')`, parce qu'elle voyage
aussi *à l'intérieur* du tarball qu'elle télécharge et ne peut pas porter son propre
hash. La copie publiée sur l'AUR doit porter le vrai (`makepkg -g >> PKGBUILD`), avec un
`.SRCINFO` regénéré en conséquence.

Le reste du travail d'empaquetage est le même partout : installer
`nas-smartmount.8`, `org.jotenakis.smartmount.policy`, les deux hooks NetworkManager,
l'unité et le timer. La CI rejoue la suite de tests sur des conteneurs Debian, Ubuntu,
Fedora et Arch (`.github/workflows/check.yml`), parce que les pannes qui comptent ici
sont des différences de bash et de parsing, pas de `mount`.

## Désinstallation

```
cd smart-mount && sudo make uninstall
```

Supprime les hooks, le script et les unités, puis désactive le timer. Le fichier de
configuration, les fichiers d'identifiants CIFS et l'ajustement de `fstab` sont laissés
en place volontairement — vérifiez `/etc/smart-mount/` et `/etc/fstab` si vous voulez les
défaire à la main.

## TODO

Rien d'ouvert côté fonctionnel. Côté distribution : publier le paquet sur l'AUR, puis
un `.deb` et un `.rpm` à partir des mêmes fichiers.
