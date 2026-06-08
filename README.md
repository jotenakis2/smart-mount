## DESCRIPTION

Script de montage intelligent d'un partage réseau local

NFS : 

- montage automatique au démarrage si connecté à un WIFI défini (SSID),

- montage automatique au démarrage si connecté en ethernet et que l'adresse MAC du serveur est la bonne,

- utilise 1 script et 2 hooks NetworkManager + un timer systemd (pour vérifier la connection et remonter si besoin).

Idem plus tard pour SMB

## INSTALLATION 



```
git clone https://github.com/jotenakis2/smart-mount && cd smart-mount && sudo make install 
```

éditer le fichier /etc/smart-mount/config

```
sudo nano /etc/smart-mount/config
```


## SUPPRESSION

```
cd smart-mount && sudo make uninstall 
```

