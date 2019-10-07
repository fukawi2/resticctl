DESTDIR?=
PREFIX?=/usr/local

all: test install

test:
	bash -n resticctl.sh

install:
	install -m0755 resticctl.sh $(DESTDIR)$(PREFIX)/bin/resticctl
