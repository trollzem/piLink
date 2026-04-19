CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter
PKG := libdrm

pidisplay: pidisplay.c
	$(CC) $(CFLAGS) $$(pkg-config --cflags $(PKG)) -o $@ $< $$(pkg-config --libs $(PKG))

clean:
	rm -f pidisplay
