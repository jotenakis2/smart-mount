## DESCRIPTION

Script de montage intelligent d'un partage réseau local

NFS : 

- montage automatique au démarrage si connecté à un WIFI défini (SSID),

- montage automatique au démarrage si connecté en ethernet et que l'adresse MAC du serveur est la bonne,
  (⚠ cette voie n'est pas encore effective : le hook Ethernet appelle un script
  qui ne décide que sur le SSID Wi-Fi ; à corriger),

- utilise 1 script bash de montage, 2 hooks NetworkManager (pour gérer les évènements de connection LAN/WIFI) et un timer systemd (pour vérifier la connection et remonter si besoin).

- à l'installation les paramètres utilisateurs seront demandés pour générer un fichier de configuration.

## COMPORTEMENT

`nfs-smartmount.sh {mount|unmount|apply}`

- `apply` est la politique complète, seule utilisée par le timer et le hook Wi-Fi :
  il monte si le SSID ciblé est actif, démonte sinon, et **ne fait rien** si l'état
  Wi-Fi est illisible (une lecture ratée ne doit pas démonter un partage qui
  fonctionne).
- **auto-réparation** : à chaque passage, un montage existant est testé
  (`stat -f` + lecture du répertoire, bornés par `timeout 5`). S'il ne répond plus
  (NAS redémarré, handles obsolètes), il est démonté et remonté.
- **démontage avec repli** : `umount` simple, puis `umount -l` si le point est
  occupé (shell ou IDE ouvert dans le partage), pour ne pas partir avec un montage
  NFS dur actif.

## DÉPENDANCES

`bash`, `nfs-utils`, `whiptail`, NetworkManager, `systemd`, `coreutils` (`timeout`).
`iw` est recommandé (lecture fiable du SSID du lien actif, à défaut `nmcli`).

## TESTS

```
make check
```

Vérifie la syntaxe, passe `shellcheck` et rejoue 19 scénarios (51 assertions) avec
des commandes simulées (`tests/run.sh`) : montage nominal, NAS redémarré, partage
occupé, SSID illisible, Wi-Fi coupé, réseau étranger, NAS injoignable, santé
instable, montage muet + occupé, `mountpoint` expiré, repli `nmcli`, SSID avec
`:`… Aucun accès système réel.


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
