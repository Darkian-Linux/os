#!/usr/bin/env bash
#
# Darkian Linux — chroot customization
# Runs INSIDE the extracted root filesystem, invoked by build.sh.
#
set -euo pipefail

source /tmp/dk/config.env

log()  { echo "[darkian-chroot] $*"; }
warn() { echo "[darkian-chroot] WARNING: $*"; }

export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Don't let package postinsts start services while in the chroot.
cat > /usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 755 /usr/sbin/policy-rc.d

# apt's download sandbox runs as the unprivileged _apt user, which needs a
# world-writable /tmp (apt creates mkstemp files there for signature checks).
chmod 1777 /tmp /var/tmp 2>/dev/null || true

# ---------------------------------------------------------------------------
log "1/12  Enabling contrib/non-free apt components"
# ---------------------------------------------------------------------------
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
  [[ -f "$f" ]] || continue
  # Skip local CD/medium repositories; only patch network lines for trixie.
  sed -ri '/^deb(\s+\[[^]]*\])?\s+file:/! s/^(\s*deb(-src)?\s+\S+\s+trixie\s+main)(\s+non-free-firmware)?\s*$/\1 contrib non-free non-free-firmware/' "$f"
done
for f in /etc/apt/sources.list.d/*.sources; do
  [[ -f "$f" ]] || continue
  if grep -q '^Components:.*\bmain\b' "$f" && ! grep -q 'non-free' "$f"; then
    sed -ri 's/^(Components:.*\bmain\b)/\1 contrib non-free/' "$f"
  fi
done
log "$(grep -h 'deb ' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null | head -2 | tr '\n' ' ')"

# The file: (live medium) repo only exists in a booted live session;
# remove it so apt-get update succeeds inside the build chroot.
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
  [[ -f "$f" ]] || continue
  sed -i '\|file:/run/live/medium|d' "$f"
done

apt-get update

# ---------------------------------------------------------------------------
log "2/12  Locale (fix setlocale errors) + i386 multiarch"
# ---------------------------------------------------------------------------
echo 'LANG=en_US.UTF-8' > /etc/default/locale
sed -ri 's/^# *(en_US\.UTF-8)/\1/' /etc/locale.gen
locale-gen en_US.UTF-8 || warn "locale-gen failed"
# i386 is no longer needed (Steam comes from Flathub); kept for rare 32-bit deps.
dpkg --add-architecture i386
apt-get update

# ---------------------------------------------------------------------------
log "3/12  Removing unwanted packages"
# ---------------------------------------------------------------------------
mapfile -t REMOVE_PKGS < <(
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs || true)"
    [[ -z "$line" ]] && continue
    dpkg-query -W -f='${Package}\n' "$line" 2>/dev/null || true
  done < /tmp/dk/packages-remove.txt | sort -u
)
if ((${#REMOVE_PKGS[@]})); then
  log "Purging: ${REMOVE_PKGS[*]}"
  apt-get purge -y "${REMOVE_PKGS[@]}" || warn "purge reported problems (continuing)"
  # Sweep stragglers if the purge transaction aborted midway.
  mapfile -t LEFTOVERS < <(
    printf '%s\n' "${REMOVE_PKGS[@]}" | while IFS= read -r p; do
      dpkg-query -W -f='${Package} ${db:Status-Status}\n' "$p" 2>/dev/null || true
    done | awk '$2=="installed"{print $1}'
  )
  if ((${#LEFTOVERS[@]})); then
    warn "Purge leftovers, forcing removal: ${LEFTOVERS[*]}"
    dpkg --purge --force-depends "${LEFTOVERS[@]}" || true
    apt-get -f install -y || true
  fi
else
  log "nothing to remove"
fi

# ---------------------------------------------------------------------------
log "4/12  Installing packages from packages-add.txt"
# ---------------------------------------------------------------------------
mapfile -t ADD_PKGS < <(
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs || true)"
    [[ -z "$line" ]] && continue
    echo "$line"
  done < /tmp/dk/packages-add.txt
)
if ((${#ADD_PKGS[@]})); then
  if ! apt-get install -y "${ADD_PKGS[@]}"; then
    warn "batch install failed — retrying per package"
    for p in "${ADD_PKGS[@]}"; do
      apt-get install -y "$p" || warn "skipped: $p"
    done
  fi
fi

# ---------------------------------------------------------------------------
log "5/12  Installing Firefox (Mozilla build, not ESR)"
# ---------------------------------------------------------------------------
if [[ "$FIREFOX_CHANNEL" == "mozilla" ]]; then
  install -d -m 0755 /etc/apt/keyrings
  if curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/mozilla.asc; then
    echo "deb [signed-by=/etc/apt/keyrings/mozilla.asc] https://packages.mozilla.org/apt mozilla main" \
      > /etc/apt/sources.list.d/mozilla.list
    if apt-get update && apt-get install -y firefox; then
      log "Mozilla Firefox installed"
    else
      warn "Mozilla repo failed — falling back to firefox-esr"
      rm -f /etc/apt/sources.list.d/mozilla.list
      apt-get update || true
      apt-get install -y firefox-esr || warn "no Firefox could be installed"
    fi
  else
    warn "could not fetch Mozilla signing key — falling back to firefox-esr"
    apt-get install -y firefox-esr || warn "no Firefox could be installed"
  fi
else
  apt-get install -y firefox-esr || warn "no Firefox could be installed"
fi

# Keep the default-browser config pointing at whichever Firefox exists.
if [[ ! -f /usr/share/applications/firefox.desktop && -f /usr/share/applications/firefox-esr.desktop ]]; then
  sed -i 's/firefox\.desktop/firefox-esr\.desktop/g' /etc/skel/.config/mimeapps.list 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
log "6/12  Setting up Flatpak (Flathub remote, no apps preinstalled)"
# ---------------------------------------------------------------------------
# No flatpak apps/runtimes are preinstalled (keeps the image small). The
# Flathub remote is ready so users can install e.g.
#   flatpak install flathub com.valvesoftware.Steam
if command -v flatpak >/dev/null 2>&1; then
  flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo \
    || warn "could not add flathub remote"
else
  warn "flatpak not installed — skipping Flathub remote"
fi

# ---------------------------------------------------------------------------
log "7/13  Installing Obsidian (official .deb from GitHub releases)"
# ---------------------------------------------------------------------------
# Obsidian is not packaged by Debian; fetch the latest official amd64 .deb and
# install it with apt so its library dependencies resolve from the Debian repos.
OBS_URL=$(curl -fsSL --max-time 120 https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest \
  | grep -Eo 'https://[^" ]*obsidian_[0-9.]+_amd64\.deb' | head -n1 || true)
if [[ -n "$OBS_URL" ]]; then
  if curl -fsSL --max-time 300 "$OBS_URL" -o /tmp/dk/obsidian.deb && apt-get install -y /tmp/dk/obsidian.deb; then
    log "Obsidian installed from ${OBS_URL##*/}"
  else
    warn "Obsidian install failed"
  fi
  rm -f /tmp/dk/obsidian.deb
else
  warn "could not resolve Obsidian .deb URL — skipping"
fi

# ---------------------------------------------------------------------------
log "8/13  Installing XanMod kernel (used on the installed system)"
# ---------------------------------------------------------------------------
if [[ "$ENABLE_XANMOD" == "true" ]]; then
  # apt reads ASCII-armored keys in trusted.gpg.d directly (no gpg needed).
  if curl -fsSL --max-time 180 https://dl.xanmod.org/archive.key \
      -o /etc/apt/trusted.gpg.d/xanmod-archive.asc; then
    echo 'deb [arch=amd64] http://deb.xanmod.org trixie main' \
      > /etc/apt/sources.list.d/xanmod-archive.list
    if ! apt-get update || ! apt-get install -y linux-xanmod-x64v3; then
      # The NVIDIA 550 DKMS module does not build against XanMod 7.x.
      # Kernel + initrd are fine; drop the DKMS tree (prebuilt stock-kernel
      # .ko files under /lib/modules are untouched) and force dpkg to finish.
      warn "XanMod install: forcing configure (nvidia DKMS skipped for XanMod)"
      rm -rf /var/lib/dkms/nvidia-current
      dpkg --configure -a || true
      apt-get -f install -y || true
    fi
    if ls /boot/vmlinuz-*-xanmod1 >/dev/null 2>&1 \
       && dpkg-query -W -f='${db:Status-Status}' 'linux-image-*-xanmod1' 2>/dev/null | grep -qx installed; then
      log "XanMod kernel installed (live session still boots the stock kernel)"
    else
      warn "XanMod unavailable — keeping the stock Debian kernel only"
      mapfile -t XP < <(dpkg-query -W -f='${Package}\n' 'linux*xanmod*' 2>/dev/null || true)
      if ((${#XP[@]})); then dpkg --purge --force-depends "${XP[@]}" || true; fi
      rm -f /etc/apt/sources.list.d/xanmod-archive.list \
            /etc/apt/trusted.gpg.d/xanmod-archive.asc
      apt-get update || true
    fi
  else
    warn "XanMod signing key fetch failed — skipping custom kernel"
  fi
fi

# ---------------------------------------------------------------------------
log "9/13  Removing Plymouth (verbose text boot)"
# ---------------------------------------------------------------------------
apt-get purge -y 'plymouth*' || warn "plymouth purge reported problems"
rm -rf /etc/plymouth /usr/share/plymouth 2>/dev/null || true

# ---------------------------------------------------------------------------
log "10/13  Branding: icons, logos"
# ---------------------------------------------------------------------------
apt-get install -y imagemagick librsvg2-bin

ICONS=/usr/share/icons/hicolor
for s in 16 22 24 32 48 64 128 256 512; do
  d="$ICONS/${s}x${s}/apps"
  mkdir -p "$d"
  convert /tmp/dk/darkian.png -resize "${s}x${s}" "$d/start-here.png"
  cp "$d/start-here.png" "$d/darkian.png"
  cp "$d/start-here.png" "$d/distributor-logo-darkian.png"
  cp "$d/start-here.png" "$d/distributor-logo-debian.png"
done
mkdir -p "$ICONS/scalable/apps"

mkdir -p /usr/share/pixmaps
cp /tmp/dk/darkian.png /usr/share/pixmaps/darkian.png
cp /tmp/dk/darkian.png /usr/share/pixmaps/distributor-logo-darkian.png

# The Plasma app launcher (start menu / taskbar start button) resolves the
# icon name "start-here" in the ACTIVE theme (breeze). Breeze ships
# start-here*.svg as SYMLINKS to folder-activities.svg (and .svgz for some
# themes), and the plain hicolor fallbacks are not preferred — so deleting or
# ignoring them leaves the KDE gear. Break each symlink/file and write the
# Darkian circle logo in place (rm first so cp does NOT follow the link and
# clobber the shared folder-activities.svg target).
#
# IMPORTANT: do NOT touch any "start-here-kde*" icon — in Breeze these are the
# KDE-branded icons (start-here-kde-plasma.svg is a symlink to start-here-kde.svg,
# and the *-symbolic variants link to folder-activities.svg) that the KDE Welcome
# Center uses, and it must stay KDE. The launcher itself is pointed at our own
# "darkian" icon below.
DK_SVG=/tmp/dk/darkian.svg
if [[ -f "$DK_SVG" ]]; then
  n=0
  while IFS= read -r -d '' f; do
    case "$f" in
      *.svgz) rm -f "$f"; gzip -c "$DK_SVG" > "$f"; n=$((n+1)) ;;
      *.svg)  rm -f "$f"; cp "$DK_SVG" "$f"; n=$((n+1)) ;;
      *.png)
        sz=$(basename "$(dirname "$f")")
        src="/usr/share/icons/hicolor/${sz}/apps/start-here.png"
        if [[ -f "$src" ]]; then rm -f "$f"; cp "$src" "$f"; n=$((n+1)); fi ;;
    esac
  done < <(find /usr/share/icons -name 'start-here*' \
             ! -name 'start-here-kde*' \
             ! -path '*/hicolor/*' -print0 2>/dev/null)
  log "Replaced $n Darkian start-here icons (all start-here-kde* left intact for the Welcome Center)"
fi

# Point the launcher (kickoff) panel button at our own "darkian" icon. Its
# default "start-here-kde-symbolic" is shared with the KDE Welcome Center, so
# overriding it here brands the start menu without affecting the Welcome Center.
KICKOFF=/usr/share/plasma/plasmoids/org.kde.plasma.kickoff
if [[ -f "$KICKOFF/contents/config/main.xml" ]]; then
  sed -i 's#<default>start-here-kde-symbolic</default>#<default>darkian</default>#' \
    "$KICKOFF/contents/config/main.xml"
fi
if [[ -f "$KICKOFF/metadata.json" ]]; then
  sed -i 's#"Icon": *"start-here-kde"#"Icon": "darkian"#' "$KICKOFF/metadata.json"
fi

# Drop stale Debian logos from other themes so hicolor wins as fallback.
find /usr/share/icons -name 'distributor-logo-debian*' ! -path '*/hicolor/*' -print0 2>/dev/null | xargs -0 -r rm -f
find /usr/share/icons -name 'debian-logo*' ! -path '*/hicolor/*' -print0 2>/dev/null | xargs -0 -r rm -f
# Also replace Debian's own hicolor logos with ours (same filename).
for stale in "$ICONS"/*/apps/debian-logo.png "$ICONS"/*/apps/debian-logo.svg; do
  [[ -f "$stale" ]] && rm -f "$stale"
done
# SVG logos ship via the rootfs overlay into hicolor/scalable/apps.

# Some tools (including KDE's About-this-System) read /usr/lib/os-release
# directly — make it the Darkian one too so no Debian branding shows up.
if [[ -f /etc/os-release ]]; then
  cp -f /etc/os-release /usr/lib/os-release
  chmod 644 /usr/lib/os-release
fi
# Drop Debian's own pixmap logos.
rm -f /usr/share/pixmaps/debian-logo.png /usr/share/pixmaps/debian-security.png \
      /usr/share/pixmaps/install-debian.png 2>/dev/null || true

# imagemagick in trixie is split (imagemagick-7-common, imagemagick-7.q16): the
# plain "imagemagick" name no longer matches, so resolve real package names.
apt-get purge -y librsvg2-bin >/dev/null 2>&1 || true
mapfile -t IM_PKGS < <(dpkg-query -W -f='${Package}\n' 'imagemagick*' 2>/dev/null || true)
if ((${#IM_PKGS[@]})); then
  apt-get purge -y "${IM_PKGS[@]}" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
log "11/13  Calamares installer branding"
# ---------------------------------------------------------------------------
BRANDING_DIR=/etc/calamares/branding
rm -rf "$BRANDING_DIR/debian" "$BRANDING_DIR/default"

if [[ -f "$BRANDING_DIR/darkian/branding.desc" ]]; then
  cp /tmp/dk/darkian.png "$BRANDING_DIR/darkian/darkian-logo.png"
  cp /tmp/dk/darkian.png "$BRANDING_DIR/darkian/welcome.png"
  cp /tmp/dk/wallpaper.png "$BRANDING_DIR/darkian/slide1.png"
  chmod 644 "$BRANDING_DIR/darkian/"*
  log "Calamares branding: darkian (logo + wallpaper slide)"
else
  warn "branding.desc missing — Calamares will fall back to default branding"
fi

# settings.conf comes from the overlay; sanity-check it.
if grep -q '^branding: darkian' /etc/calamares/settings.conf; then
  log "Calamares settings.conf points at 'darkian' branding"
else
  warn "settings.conf branding line not found"
fi

# ---------------------------------------------------------------------------
log "12/13  Live identity, password, desktop polish"
# ---------------------------------------------------------------------------
log "hostname: $(cat /etc/hostname)"
log "live user: $(grep -E '^(LIVE_USERNAME|LIVE_USER_FULLNAME)=' /etc/live/config.conf | tr '\n' ' ')"

# Live password: live-config runs hooks from /lib/live/config/hooks at boot.
install -d -m 0755 /lib/live/config/hooks
cat > /lib/live/config/hooks/9999-darkian-password.sh <<'HOOK'
# Set the live user's password on every boot (live-config runs this in the
# live session, after the user account has been created).
if id "${LIVE_USERNAME:-darkian}" >/dev/null 2>&1; then
  echo "${LIVE_USERNAME:-darkian}:${LIVE_PASSWORD:-darkianlinux}" | chpasswd
fi
HOOK
chmod 755 /lib/live/config/hooks/9999-darkian-password.sh

# Make ZSH the default shell for the live user at boot.
cat > /lib/live/config/hooks/9998-darkian-shell.sh <<'HOOK'
if id "${LIVE_USERNAME:-darkian}" >/dev/null 2>&1; then
  usermod -s /usr/bin/zsh "${LIVE_USERNAME:-darkian}" 2>/dev/null \
    || chsh -s /usr/bin/zsh "${LIVE_USERNAME:-darkian}" 2>/dev/null || true
  H="/home/${LIVE_USERNAME:-darkian}"
  if [ -d "$H" ] && [ ! -e "$H/.zshrc" ] && [ -e /etc/skel/.zshrc ]; then
    cp /etc/skel/.zshrc "$H/.zshrc"
    chown "${LIVE_USERNAME:-darkian}:${LIVE_USERNAME:-darkian}" "$H/.zshrc" 2>/dev/null || true
  fi
fi
HOOK
chmod 755 /lib/live/config/hooks/9998-darkian-shell.sh

# ZSH: Darkian prompt for every user + ZSH as the default shell for new accounts.
if [[ -x /usr/bin/zsh ]]; then
  cat >> /etc/zsh/zshrc <<'ZRC'

# --- Darkian prompt: user@hostname (place)% with white/red colours ---
autoload -Uz colors 2>/dev/null && colors
PROMPT='%F{white}%n%F{red}@%F{white}%m %F{white}(%F{red}%~%F{white})%F{white}%%%f '
ZRC
  # Default shell for accounts created later (Calamares uses userShell in users.conf)
  if grep -q '^DSHELL=' /etc/adduser.conf 2>/dev/null; then
    sed -i 's|^DSHELL=.*|DSHELL=/usr/bin/zsh|' /etc/adduser.conf
  else
    echo 'DSHELL=/usr/bin/zsh' >> /etc/adduser.conf
  fi
  if grep -q '^SHELL=' /etc/default/useradd 2>/dev/null; then
    sed -i 's|^SHELL=.*|SHELL=/usr/bin/zsh|' /etc/default/useradd
  else
    echo 'SHELL=/usr/bin/zsh' >> /etc/default/useradd
  fi
  log "ZSH configured as default shell with Darkian prompt"
else
  warn "zsh not installed — leaving bash as the default shell"
fi

# Calamares: allow easy (short/simple) passwords on the installed system.
install -d -m 0755 /etc/calamares/modules
cat > /etc/calamares/modules/users.conf <<'USERS'
---
defaultGroups:
  - audio
  - cdrom
  - dip
  - floppy
  - lpadmin
  - netdev
  - plugdev
  - sudo
  - users
  - video
setHostname: true
savePassword: false
userShell: /usr/bin/zsh
passwordRequirements:
  minLength: 0
  minEntropyBits: 0
USERS
chmod 644 /etc/calamares/modules/users.conf

# Hide the keyboard-layout applet from the Plasma system tray (single-layout
# default; avoids the "layout switcher" clutter). Runs once per user session.
install -d -m 0755 /usr/local/bin
cat > /usr/local/bin/darkian-hide-keyboard <<'KBSCRIPT'
#!/bin/bash
# Remove the keyboard-layout indicator from the Plasma system tray.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if qdbus org.kde.plasmashell /PlasmaShell \
      org.kde.PlasmaShell.evaluateScript \
      "var ds=desktops();for(var i=0;i<ds.length;i++){var w=ds[i].widgetForType('org.kde.plasma.keyboardindicator');if(w){w.remove();}}" \
      >/dev/null 2>&1; then
    exit 0
  fi
  sleep 3
done
exit 0
KBSCRIPT
chmod 755 /usr/local/bin/darkian-hide-keyboard

install -d -m 0755 /etc/skel/.config/autostart
cat > /etc/skel/.config/autostart/darkian-hide-keyboard.desktop <<'KB'
[Desktop Entry]
Type=Application
Name=Hide keyboard layout applet
Exec=/usr/local/bin/darkian-hide-keyboard
X-KDE-autostart-phase=2
NoDisplay=true
KB
chmod 644 /etc/skel/.config/autostart/darkian-hide-keyboard.desktop

# Calamares window/launcher icon = Darkian circle logo
if [[ -f /tmp/dk/darkian.png ]]; then
  for d in /usr/share/pixmaps /usr/share/icons/hicolor/256x256/apps; do
    install -d -m 0755 "$d"
    cp /tmp/dk/darkian.png "$d/calamares.png"
  done
  for df in /usr/share/applications/calamares*.desktop; do
    [[ -f "$df" ]] && sed -i 's/^Icon=.*/Icon=calamares/' "$df"
  done
fi

# Fastfetch: custom Darkian ASCII logo (replaces Debian logo)
install -d -m 0755 /usr/share/fastfetch /etc/fastfetch
if [[ -f /tmp/dk/darkian-ascii.txt ]]; then
  cp /tmp/dk/darkian-ascii.txt /usr/share/fastfetch/darkian.txt
  chmod 644 /usr/share/fastfetch/darkian.txt
fi
cat > /etc/fastfetch/config.jsonc <<'FF'
{
  "logo": {
    "source": "/usr/share/fastfetch/darkian.txt"
  },
  "display": {
    "separator": ": "
  },
  "modules": [
    "title",
    "separator",
    "os",
    "host",
    "kernel",
    "uptime",
    "packages",
    "shell",
    "display",
    "de",
    "wm",
    "wmtheme",
    "theme",
    "icons",
    "cursor",
    "terminal",
    "cpu",
    "gpu",
    "memory",
    "swap",
    "disk",
    "localip",
    "battery",
    "poweradapter",
    "locale",
    "break",
    "colors"
  ]
}
FF
chmod 644 /etc/fastfetch/config.jsonc

# ---------------------------------------------------------------------------
# Darkian Plasma Global Theme (appears as "Darkian" in System Settings)
# ---------------------------------------------------------------------------
LAF=/usr/share/plasma/look-and-feel/org.darkian.desktop
rm -rf "$LAF"
install -d -m 0755 "$LAF/contents/layouts" "$LAF/contents/previews"
cat > "$LAF/metadata.json" <<'LAFMETA'
{
    "KPackageStructure": "Plasma/LookAndFeel",
    "KPlugin": {
        "Authors": [
            { "Name": "Darkian Linux", "Email": "build@darkian.xyz" }
        ],
        "Category": "",
        "Description": "Darkian Linux default theme",
        "Id": "org.darkian.desktop",
        "License": "GPLv2+",
        "Name": "Darkian",
        "Website": "https://darkian.xyz"
    }
}
LAFMETA
cat > "$LAF/contents/defaults" <<'LAFDEF'
[kdeglobals][KDE]
widgetStyle=Breeze

[kdeglobals][General]
ColorScheme=BreezeDark
AccentColor=239,68,68

[kdeglobals][Icons]
Theme=breeze-dark

[plasmarc][Theme]
name=default

[Wallpaper]
Image=Next

[kcminputrc][Mouse]
cursorTheme=breeze_cursors

[kwinrc][org.kde.kdecoration2]
library=org.kde.breeze
theme=Breeze

[KSplash]
Theme=org.kde.Breeze
LAFDEF
cat > "$LAF/contents/layouts/org.kde.plasma.desktop-layout.js" <<'LAFLAY'
loadTemplate("org.kde.plasma.desktop.defaultPanel")

var desktopsArray = desktopsForActivity(currentActivity());
for (var j = 0; j < desktopsArray.length; j++) {
    desktopsArray[j].wallpaperPlugin = 'org.kde.image';
}
LAFLAY
[[ -f /tmp/dk/wallpaper.png ]] && cp -f /tmp/dk/wallpaper.png "$LAF/contents/previews/preview.png"
chmod -R a+rX "$LAF"
log "Darkian global theme installed: org.darkian.desktop"

# Pin default apps to the taskbar in the default panel layout (applies to both
# the live session and freshly-installed systems, which both use this template).
# Order: Dolphin, System Settings, Firefox, Discover, Konsole.
DEFAULT_PANEL=/usr/share/plasma/layout-templates/org.kde.plasma.desktop.defaultPanel/contents/layout.js
DK_LAUNCHERS='applications:org.kde.dolphin.desktop,applications:systemsettings.desktop,applications:firefox.desktop,applications:org.kde.discover.desktop,applications:org.kde.konsole.desktop'
if [[ -f "$DEFAULT_PANEL" ]]; then
  sed -i "s#panel.addWidget(\"org.kde.plasma.icontasks\")#var icontasks = panel.addWidget(\"org.kde.plasma.icontasks\")\nicontasks.currentConfigGroup = [\"General\"]\nicontasks.writeConfig(\"launchers\", \"${DK_LAUNCHERS}\")#" "$DEFAULT_PANEL"
  log "default panel: taskbar pinned (Dolphin, System Settings, Firefox, Discover, Konsole)"
fi

# Fresh machine-id / systemd state so the first boot generates its own
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
rm -f /var/lib/systemd/random-seed

# ---------------------------------------------------------------------------
log "13/13  Cleanup"
# ---------------------------------------------------------------------------
dpkg --configure -a || true
apt-get autoremove -y --purge || warn "autoremove reported problems"

rm -rf /var/lib/apt/lists/*
apt-get clean
rm -rf /var/cache/apt/*.bin /var/cache/apt/archives/*.deb 2>/dev/null || true
find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true
rm -f /var/cache/man/* 2>/dev/null || true
rm -f /root/.bash_history /root/.wget-hsts 2>/dev/null || true

# Remove the chroot guard so services can start on the installed system
rm -f /usr/sbin/policy-rc.d

# Our own temp files (safe to delete: bash holds the script open)
rm -rf /tmp/dk /tmp/chroot.sh

log "chroot customization finished"
