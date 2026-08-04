# SPDX-License-Identifier: Apache-2.0
# Build a minimal speedometer demo against libwayland-client + cairo.
# Generates xdg-shell client glue from /usr/share/wayland-protocols.
WAYLAND_SCANNER ?= wayland-scanner
PKGCONFIG      ?= pkg-config
WPROTODIR      ?= $(shell $(PKGCONFIG) --variable=pkgdatadir wayland-protocols)
XDG_XML        ?= $(WPROTODIR)/stable/xdg-shell/xdg-shell.xml

CFLAGS  ?= -O2 -Wall -Wextra
CFLAGS  += $(shell $(PKGCONFIG) --cflags wayland-client cairo)
CFLAGS  += -I.
LDLIBS  += $(shell $(PKGCONFIG) --libs   wayland-client cairo) -lm

OBJS = xt-cluster-shm.o xdg-shell-protocol.o

all: xt-cluster-shm

xt-cluster-shm: $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(OBJS) $(LDLIBS)

xdg-shell-client-protocol.h: $(XDG_XML)
	$(WAYLAND_SCANNER) client-header $< $@

xdg-shell-protocol.c: $(XDG_XML)
	$(WAYLAND_SCANNER) private-code $< $@

xt-cluster-shm.o: xt-cluster-shm.c xdg-shell-client-protocol.h
	$(CC) $(CFLAGS) -c -o $@ $<

xdg-shell-protocol.o: xdg-shell-protocol.c xdg-shell-client-protocol.h
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	$(RM) xt-cluster-shm $(OBJS) xdg-shell-client-protocol.h xdg-shell-protocol.c

install:
	install -d $(DESTDIR)/usr/bin
	install -m 0755 xt-cluster-shm $(DESTDIR)/usr/bin/xt-cluster-shm
