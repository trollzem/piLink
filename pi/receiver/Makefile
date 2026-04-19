CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter
PKG := libdrm

all: pidisplay ffs-init

pidisplay: pidisplay.c
	$(CC) $(CFLAGS) $$(pkg-config --cflags $(PKG)) -o $@ $< $$(pkg-config --libs $(PKG))

ffs-init: ffs-init.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f pidisplay ffs-init
