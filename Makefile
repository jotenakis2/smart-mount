PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
NM_DISPATCHER_DIR ?= /etc/NetworkManager/dispatcher.d
SYSTEMD_SYSTEM_DIR ?= /etc/systemd/system
CONF_DIR ?= /etc/smart-mount
INSTALL ?= install
CHOWN ?= chown
RM ?= rm -f

DISPATCHER_SCRIPTS := 98-eth-nfs-mac 99-wifi-nfs-mount
CONFIG := config
BIN_SCRIPT := nfs-mount.sh
SYSTEMD_UNITS := nfs-network-check.service nfs-network-check.timer

.PHONY: all install uninstall check verify

all:
	@printf '%s\n' "Targets: install uninstall check verify"

check:
	test -f 98-eth-nfs-mac
	test -f 99-wifi-nfs-mount
	test -f nfs-mount.sh
	test -f config
	test -f nfs-network-check.service
	test -f nfs-network-check.timer

install: check
	$(INSTALL) -d -m 0755 "$(DESTDIR)$(NM_DISPATCHER_DIR)"
	$(INSTALL) -d -m 0755 "$(DESTDIR)$(BINDIR)"
	$(INSTALL) -d -m 0755 "$(DESTDIR)$(SYSTEMD_SYSTEM_DIR)"
	$(INSTALL) -d -m 0755 "$(DESTDIR)$(CONF_DIR)"

	$(INSTALL) -m 0700 $(DISPATCHER_SCRIPTS) "$(DESTDIR)$(NM_DISPATCHER_DIR)/"
	$(CHOWN) root:root "$(DESTDIR)$(NM_DISPATCHER_DIR)/98-eth-nfs-mac"
	$(CHOWN) root:root "$(DESTDIR)$(NM_DISPATCHER_DIR)/99-wifi-nfs-mount"

	$(INSTALL) -m 0600 $(CONFIG) "$(DESTDIR)$(CONF_DIR)/"
	$(CHOWN) root:root "$(DESTDIR)$(CONF_DIR)/config"


	$(INSTALL) -m 0755 $(BIN_SCRIPT) "$(DESTDIR)$(BINDIR)/$(BIN_SCRIPT)"
	$(CHOWN) root:root "$(DESTDIR)$(BINDIR)/$(BIN_SCRIPT)"

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
	@if [ -z "$(DESTDIR)" ]; then \
		systemctl daemon-reload || true; \
	fi
