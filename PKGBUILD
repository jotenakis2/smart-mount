# Maintainer: Olivier Lorillu <contact@jotenakis.ovh>
pkgname=smart-mount
pkgver=1.7
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
sha256sums=('1b290533e113ad1b2e831d14653a011dbfb406f536aa861a14e36e2d27c2d885')

package() {
    cd "$pkgname-$pkgver"

    # DESTDIR : make saute le questionnaire (il n'y a pas de machine à configurer
    # ici, seulement un paquet) et la vérification des dépendances, qui relève des
    # métadonnées du paquet.
    make install DESTDIR="$pkgdir" PREFIX=/usr
}
