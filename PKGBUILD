# Maintainer: Olivier Lorillu <contact@jotenakis.ovh>
pkgname=smart-mount
pkgver=1.17
pkgrel=1
pkgdesc="Mount NFS and CIFS shares only when the right network and the right server are
present, and keep them healthy"
arch=('any')
url="https://github.com/jotenakis2/smart-mount"
license=('MIT')
depends=('bash' 'coreutils' 'util-linux' 'iproute2' 'iputils' 'nfs-utils'
         'networkmanager' 'systemd' 'libnewt')
optdepends=('cifs-utils: share of type cifs'
            'iw: reliable SSID detection (falls back to nmcli)')
provides=('smart-mount')
conflicts=('smart-mount-git')
# Pas de `backup=('/etc/smart-mount/config')` : le fichier n'est pas dans le paquet
# (il est écrit par smart-mount-setup), et pacman n'applique le mécanisme de
# sauvegarde qu'aux fichiers qu'il a lui-même installés.
install="$pkgname.install"
source=("$url/archive/v$pkgver/$pkgname-$pkgver.tar.gz")
# SKIP volontaire : ce PKGBUILD est aussi présent DANS le tarball qu'il télécharge,
# et il ne peut pas contenir le sha256 de lui-même. La copie publiée sur l'AUR doit,
# elle, porter le vrai hash :
#   makepkg -g >> PKGBUILD      (ou : sha256sum smart-mount-<version>.tar.gz)
sha256sums=('SKIP')

package() {
    cd "$pkgname-$pkgver"

    # DESTDIR : make saute le questionnaire (il n'y a pas de machine à configurer
    # ici, seulement un paquet) et la vérification des dépendances, qui relève des
    # métadonnées du paquet.
    make install DESTDIR="$pkgdir" PREFIX=/usr
}
