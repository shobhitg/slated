# A headless GNOME Shell for Slated's end-to-end extension tests (see run.sh).
#
# The GNOME version follows the Fedora release:
#   FEDORA_VERSION=44 → GNOME 50 (default)   45 → GNOME 51   43 → GNOME 49   42 → GNOME 48   41 → 47   40 → 46
# Releases past their end of life live on Fedora's archive mirror; build them with FEDORA_ARCHIVE=1.
ARG FEDORA_VERSION=44
FROM registry.fedoraproject.org/fedora:${FEDORA_VERSION}

ARG FEDORA_ARCHIVE=0
RUN if [ "$FEDORA_ARCHIVE" = "1" ]; then \
      sed -i -e 's|^metalink=|#metalink=|' \
             -e 's|^#baseurl=http://download.example/pub/fedora/linux|baseurl=https://archives.fedoraproject.org/pub/archive/fedora/linux|' \
             /etc/yum.repos.d/*.repo; \
    fi

# gnome-shell brings mutter, gjs and the GSettings schemas; mesa renders without a GPU; gtk4 + gjs run
# the test window; python3-gobject drives the extension over D-Bus.
RUN dnf -y install --setopt=install_weak_deps=False \
      gnome-shell gjs gtk4 glib2 dconf \
      dbus-daemon dbus-tools \
      mesa-dri-drivers mesa-libEGL mesa-libgbm xorg-x11-server-Xwayland \
      python3 python3-gobject procps-ng findutils \
      dejavu-sans-fonts adwaita-icon-theme \
 && dnf clean all

RUN useradd --create-home tester
USER tester
WORKDIR /home/tester

ENV XDG_SESSION_TYPE=wayland \
    XDG_CURRENT_DESKTOP=GNOME \
    LIBGL_ALWAYS_SOFTWARE=1 \
    GSK_RENDERER=cairo \
    NO_AT_BRIDGE=1 \
    SLATED_IN_CONTAINER=1

ENTRYPOINT ["/bin/bash"]
