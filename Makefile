PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
NM_DISPATCHER_DIR ?= /etc/NetworkManager/dispatcher.d
SYSTEMD_SYSTEM_DIR ?= /etc/systemd/system
MAN8_DIR ?= $(PREFIX)/share/man/man8
POLKIT_ACTIONS_DIR ?= $(PREFIX)/share/polkit-1/actions
INSTALL ?= install
CHOWN ?= chown
RM ?= rm -f

DISPATCHER_SCRIPTS := 98-eth-nfs-mac 99-wifi-nfs-mount
BIN_SCRIPT := nfs-smartmount.sh
SYSTEMD_UNITS := nfs-network-check.service nfs-network-check.timer
MANPAGE := nfs-smartmount.8
POLICY := org.jotenakis.smartmount.policy
SETUP_SCRIPT := setup.sh

# Dépendances d'exécution, exprimées en commandes (pas en paquets, qui changent
# selon la distribution) : nfs-utils/nfs-common, iproute2, iputils, coreutils,
# util-linux, whiptail, NetworkManager.
RUNTIME_DEPS := mount.nfs ip ping timeout logger whiptail nmcli

.PHONY: all install uninstall check deps verify

all:
	@printf '%s\n' "Targets: install uninstall check deps verify"

# Vérifie que la machine peut réellement faire tourner l'outil avant de copier
# quoi que ce soit. Ignoré quand DESTDIR est utilisé : on prépare alors un paquet
# pour une autre machine, et les dépendances relèvent de ses métadonnées.
deps:
	@if [ -n "$(DESTDIR)" ]; then exit 0; fi; \
	missing=''; \
	for cmd in $(RUNTIME_DEPS); do \
		command -v "$$cmd" >/dev/null 2>&1 || missing="$$missing $$cmd"; \
	done; \
	if [ -n "$$missing" ]; then \
		printf '%s\n' "Dépendance(s) manquante(s):$$missing"; \
		printf '%s\n' "Paquets: nfs-utils (nfs-common sur Debian), iproute2, iputils, coreutils, util-linux, whiptail, NetworkManager."; \
		exit 1; \
	fi

check:
	test -f 98-eth-nfs-mac
	test -f 99-wifi-nfs-mount
	test -f nfs-smartmount.sh
	test -f nfs-network-check.service
	test -f nfs-network-check.timer
	test -f nfs-smartmount.8
	test -f org.jotenakis.smartmount.policy
	bash -n 98-eth-nfs-mac
	bash -n 99-wifi-nfs-mount
	bash -n nfs-smartmount.sh
	bash -n setup.sh
	bash -n tests/run.sh
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -x --severity=info --exclude=SC1091 \
			98-eth-nfs-mac 99-wifi-nfs-mount nfs-smartmount.sh setup.sh tests/run.sh; \
	else \
		printf '%s\n' "shellcheck absent : contrôle de style sauté"; \
	fi
	@if command -v groff >/dev/null 2>&1; then \
		groff -man -Tutf8 -z nfs-smartmount.8; \
	else \
		printf '%s\n' "groff absent : page de man non validée"; \
	fi
	bash tests/run.sh

install: deps check
	@if [ -z "$(DESTDIR)" ] && [ -t 0 ] && [ -t 1 ] && [ -x ./$(SETUP_SCRIPT) ]; then \
		./$(SETUP_SCRIPT); \
	fi
	$(INSTALL) -d -m 0755 "$(DESTDIR)$(NM_DISPATCHER_DIR)"
	$(INSTALL) -d -m 0755 "$(DESTDIR)$(BINDIR)"
	$(INSTALL) -d -m 0755 "$(DESTDIR)$(SYSTEMD_SYSTEM_DIR)"
	$(INSTALL) -d -m 0755 "$(DESTDIR)$(MAN8_DIR)"
	$(INSTALL) -d -m 0755 "$(DESTDIR)$(POLKIT_ACTIONS_DIR)"

	$(INSTALL) -m 0700 $(DISPATCHER_SCRIPTS) "$(DESTDIR)$(NM_DISPATCHER_DIR)/"
	$(CHOWN) root:root "$(DESTDIR)$(NM_DISPATCHER_DIR)/98-eth-nfs-mac"
	$(CHOWN) root:root "$(DESTDIR)$(NM_DISPATCHER_DIR)/99-wifi-nfs-mount"

	$(INSTALL) -m 0755 $(BIN_SCRIPT) "$(DESTDIR)$(BINDIR)/$(BIN_SCRIPT)"
	$(CHOWN) root:root "$(DESTDIR)$(BINDIR)/$(BIN_SCRIPT)"

	$(INSTALL) -m 0755 $(SETUP_SCRIPT) "$(DESTDIR)$(BINDIR)/smart-mount-setup"
	$(CHOWN) root:root "$(DESTDIR)$(BINDIR)/smart-mount-setup"

	$(INSTALL) -m 0644 $(MANPAGE) "$(DESTDIR)$(MAN8_DIR)/"
	# L'action polkit est liée à un chemin absolu : on la réécrit pour le PREFIX
	# réellement utilisé, sinon un paquet en /usr déclare une action pour un
	# binaire qui n'existe pas à cet endroit.
	sed 's|/usr/local/bin/nfs-smartmount.sh|$(BINDIR)/nfs-smartmount.sh|' $(POLICY) \
		> "$(DESTDIR)$(POLKIT_ACTIONS_DIR)/$(POLICY)"
	chmod 0644 "$(DESTDIR)$(POLKIT_ACTIONS_DIR)/$(POLICY)"
	$(CHOWN) root:root "$(DESTDIR)$(MAN8_DIR)/$(MANPAGE)"
	$(CHOWN) root:root "$(DESTDIR)$(POLKIT_ACTIONS_DIR)/$(POLICY)"

	$(INSTALL) -m 0644 $(SYSTEMD_UNITS) "$(DESTDIR)$(SYSTEMD_SYSTEM_DIR)/"
	$(CHOWN) root:root "$(DESTDIR)$(SYSTEMD_SYSTEM_DIR)/nfs-network-check.service"
	$(CHOWN) root:root "$(DESTDIR)$(SYSTEMD_SYSTEM_DIR)/nfs-network-check.timer"

	@if command -v restorecon >/dev/null 2>&1; then \
		restorecon "$(DESTDIR)$(NM_DISPATCHER_DIR)/98-eth-nfs-mac" \
			"$(DESTDIR)$(NM_DISPATCHER_DIR)/99-wifi-nfs-mount" \
			"$(DESTDIR)$(BINDIR)/$(BIN_SCRIPT)" \
			"$(DESTDIR)$(SYSTEMD_SYSTEM_DIR)/nfs-network-check.service" \
			"$(DESTDIR)$(SYSTEMD_SYSTEM_DIR)/nfs-network-check.timer"; \
	fi

	@if [ -z "$(DESTDIR)" ]; then \
		systemd-analyze verify \
			"$(SYSTEMD_SYSTEM_DIR)/nfs-network-check.service" \
			"$(SYSTEMD_SYSTEM_DIR)/nfs-network-check.timer"; \
		systemctl daemon-reload; \
		systemctl enable --now nfs-network-check.timer; \
	fi

verify:
	systemd-analyze verify \
		"$(SYSTEMD_SYSTEM_DIR)/nfs-network-check.service" \
		"$(SYSTEMD_SYSTEM_DIR)/nfs-network-check.timer"

uninstall:
	@if [ -z "$(DESTDIR)" ]; then \
		systemctl disable --now nfs-network-check.timer || true; \
	fi
	$(RM) "$(DESTDIR)$(NM_DISPATCHER_DIR)/98-eth-nfs-mac"
	$(RM) "$(DESTDIR)$(NM_DISPATCHER_DIR)/99-wifi-nfs-mount"
	$(RM) "$(DESTDIR)$(BINDIR)/$(BIN_SCRIPT)"
	$(RM) "$(DESTDIR)$(SYSTEMD_SYSTEM_DIR)/nfs-network-check.service"
	$(RM) "$(DESTDIR)$(SYSTEMD_SYSTEM_DIR)/nfs-network-check.timer"
	$(RM) "$(DESTDIR)$(BINDIR)/smart-mount-setup"
	$(RM) "$(DESTDIR)$(MAN8_DIR)/$(MANPAGE)"
	$(RM) "$(DESTDIR)$(POLKIT_ACTIONS_DIR)/$(POLICY)"
	@if [ -z "$(DESTDIR)" ]; then \
		systemctl daemon-reload || true; \
	fi
