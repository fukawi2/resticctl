DESTDIR?=
PREFIX?=/usr/local

all: test install

test:
	bash -n resticctl.sh

install:
	install -m0755 resticctl.sh $(DESTDIR)$(PREFIX)/bin/resticctl
	install -m0644 restic@.service $(DESTDIR)/etc/systemd/system/restic@.service
	install -m0644 restic@.timer $(DESTDIR)/etc/systemd/system/restic@.timer
	install -m0644 restic-cleanup@.service $(DESTDIR)/etc/systemd/system/restic-cleanup@.service
	install -m0644 restic-cleanup@.timer $(DESTDIR)/etc/systemd/system/restic-cleanup@.timer
