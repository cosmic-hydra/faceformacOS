# Builds pam_faceunlock, the PAM module that runs faceunlock-verify.
#
#   make            build pam_faceunlock.so
#   sudo make install   install to /usr/local/lib/pam/pam_faceunlock.so.2
#                       (the .2 suffix is required by macOS OpenPAM's loader)

UNAME := $(shell uname -s)

CC ?= cc
CFLAGS ?= -O2
CFLAGS += -Wall -Wextra -fPIC

ifeq ($(UNAME),Darwin)
SHARED_FLAGS = -dynamiclib
INSTALL_OWNER = -o root -g wheel
else
SHARED_FLAGS = -shared
INSTALL_OWNER =
endif

MODULE = pam_faceunlock.so
PAM_DIR = /usr/local/lib/pam

.PHONY: all install uninstall clean

all: $(MODULE)

$(MODULE): pam_faceunlock.c
	$(CC) $(CFLAGS) $(SHARED_FLAGS) -o $@ $< -lpam

install: $(MODULE)
	install -d -m 755 $(INSTALL_OWNER) $(PAM_DIR)
	install -m 444 $(INSTALL_OWNER) $(MODULE) $(PAM_DIR)/$(MODULE).2

uninstall:
	rm -f $(PAM_DIR)/$(MODULE).2

clean:
	rm -f $(MODULE)
