# Builds the PAM module with clang only — no Xcode required.
#
#   make            → pam_faceunlock.so (universal arm64 + x86_64)
#   make check      → syntax-check only
#   sudo make install

CC      ?= clang
SDKROOT := $(shell xcrun --show-sdk-path 2>/dev/null)
ifneq ($(SDKROOT),)
SYSROOT_FLAGS = -isysroot $(SDKROOT)
endif

# Native-only builds: make ARCHS="-arch arm64"
ARCHS  ?= -arch arm64 -arch x86_64

CFLAGS ?= -Os
CFLAGS += -Wall -Wextra -fstack-protector-strong
LDLIBS  = -lpam

MODULE      = pam_faceunlock.so
INSTALL_DIR = /usr/local/lib/pam

.PHONY: all check install clean

all: $(MODULE)

$(MODULE): pam_faceunlock.c
	$(CC) $(SYSROOT_FLAGS) $(ARCHS) $(CFLAGS) -bundle -o $@ $< $(LDLIBS)

check:
	$(CC) $(SYSROOT_FLAGS) $(CFLAGS) -fsyntax-only pam_faceunlock.c

# Same ownership/permissions as Apple's modules in /usr/lib/pam.
install: $(MODULE)
	mkdir -p $(INSTALL_DIR)
	install -o root -g wheel -m 444 $(MODULE) $(INSTALL_DIR)/$(MODULE)

clean:
	rm -f $(MODULE)
