## DESCRIPTION

Script de montage intelligent d'un partage réseau local

NFS : 

- montage automatique quand la machine est sur le WIFI défini (SSID) **et** que
  le NAS répond avec l'adresse MAC configurée (lue dans la table ARP de
  l'interface Wi-Fi). Le SSID seul ne suffit pas : un réseau du même nom ailleurs
  ne fait pas monter le partage ;

- même contrôle d'identité en ethernet, sur l'interface LAN ;

- **une seule décision** pour les deux liens : il suffit que l'un des deux soit
  à la fois le bon réseau et le bon serveur pour monter, et il faut que les deux
  soient écartés pour démonter. Les hooks ne décident plus, ils déclenchent cette
  politique ; c'est ce qui empêche le hook Wi-Fi et le hook Ethernet de se
  contredire quand les deux liens sont actifs (portable docké, Wi-Fi sur un autre
  réseau, etc.).

- utilise 1 script bash de montage, 2 hooks NetworkManager (pour gérer les évènements de connection LAN/WIFI) et un timer systemd (pour vérifier la connection et remonter si besoin).

- à l'installation les paramètres utilisateurs seront demandés pour générer un fichier de configuration.

## COMPORTEMENT

`nfs-smartmount.sh {mount|unmount|apply}`

- `apply` est la politique complète, seule utilisée par le timer et les deux
  hooks :
  - Wi-Fi ciblé (SSID) **et** MAC du NAS lue sur `WIFI_IFACE` → montage attendu ;
  - sinon MAC du NAS lue sur `LAN_IFACE` → montage attendu ;
  - sinon, un des deux liens est illisible → **aucune action** (une lecture ratée
    ne doit pas démonter un partage qui fonctionne) ;
  - sinon (les deux liens écartés sans ambiguïté) → démontage.
- **la MAC cible est obligatoire** : sans `NFS_SERVER_MAC` configurée, aucun
  montage n'est possible (code de sortie 4, message dédié). L'identité du serveur
  ne se devine pas.
- `mount` ne monte que, avec la même règle « l'un des deux liens suffit » :
  utilisable à la main ou depuis un script de démarrage.
- **auto-réparation** : à chaque passage, un montage existant est testé
  (`stat -f` + lecture du répertoire, bornés par `timeout 5`). S'il ne répond plus
  (NAS redémarré, handles obsolètes), il est démonté et remonté.
- **démontage avec repli** : `umount` simple, puis `umount -l` si le point est
  occupé (shell ou IDE ouvert dans le partage), pour ne pas partir avec un montage
  NFS dur actif.
- **mode dry-run** : `SMARTMOUNT_DRY_RUN=1` calcule et journalise la décision
  sans monter ni démonter. C'est le moyen de contrôler le chemin Ethernet sur une
  machine qui n'en a pas :
  `sudo SMARTMOUNT_DRY_RUN=1 /usr/local/bin/nfs-smartmount.sh apply`.

Pour trouver la MAC du NAS : `ip neigh show <IP>` quand il est joignable, ou
l'interface d'administration du NAS, ou la liste des baux DHCP de la box.
`setup.sh` la détecte (table ARP d'abord, un ping en secours) et, si elle reste
introuvable, affiche la procédure et laisse le champ vide : il faut alors
renseigner `NFS_SERVER_MAC` dans `/etc/smart-mount/config`. Rien ne montera tant
que ce n'est pas fait.

Limite connue de la détection Ethernet : la MAC est lue dans la table ARP du
lien. Si le NAS est derrière un routeur (autre sous-réseau ou VLAN), la MAC vue
est celle du routeur ; c'est alors cette MAC qu'il faut mettre en configuration.

## DÉPENDANCES

`bash`, `nfs-utils`, `whiptail`, NetworkManager, `systemd`, `coreutils` (`timeout`),
`iproute2` (`ip neigh` pour la détection Ethernet).
`iw` est recommandé (lecture fiable du SSID du lien actif, à défaut `nmcli`).

## TESTS

```
make check
```

Vérifie la syntaxe, passe `shellcheck` et rejoue 38 scénarios (103 assertions)
avec des commandes simulées (`tests/run.sh`) : montage nominal, NAS redémarré,
partage occupé, SSID illisible, NAS injoignable, santé instable, `mountpoint`
expiré, repli `nmcli`, SSID avec `:`, MAC absente de la configuration (refus,
code 4), Wi-Fi ciblé sans voisin ARP ou avec une MAC différente (refus + log
d'identité), Ethernet confirmé sans Wi-Fi, Wi-Fi étranger + Ethernet confirmé (et
l'inverse), MAC inversée de casse, `LAN_IFACE` vide, mode dry-run, et les deux
hooks (qui doivent déclencher `apply` et jamais démonter de leur côté). Aucun
accès système réel.

La vérification d'identité (table ARP + MAC attendue) a été validée en dry-run
contre une entrée ARP réelle, en Wi-Fi comme en Ethernet (MAC correcte → montage
attendu ; MAC fausse ou absence de voisin → refus). Ce qui reste non testé : le
raccordement physique Ethernet, c'est à dire le nom d'interface et les évènements
NetworkManager associés.


## INSTALLATION 

```
git clone https://github.com/jotenakis2/smart-mount && cd smart-mount && sudo make install 
```


## SUPPRESSION

```
cd smart-mount && sudo make uninstall 
```

## TODO

SMB
