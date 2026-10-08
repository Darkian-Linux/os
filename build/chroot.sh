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
log "2/12  Adding i386 multiarch (Steam)"
# ---------------------------------------------------------------------------
if [[ "$ENABLE_STEAM" == "true" ]]; then
  dpkg --add-architecture i386
  apt-get update
fi

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
  sed -i 's/firefox\.desktop/firefox-esr.desktop/g' /etc/skel/.config/mimeapps.list 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
log "6/12  Installing Steam"
# ---------------------------------------------------------------------------
if [[ "$ENABLE_STEAM" == "true" ]]; then
  apt-get install -y steam-installer || apt-get install -y steam || warn "Steam unavailable"
fi

# ---------------------------------------------------------------------------
log "7/12  Installing XanMod kernel (used on the installed system)"
# ---------------------------------------------------------------------------
if [[ "$ENABLE_XANMOD" == "true" ]]; then
  command -v gpg >/dev/null || apt-get install -y gnupg
  if curl -fsSL https://dl.xanmod.org/gpg.key | gpg --dearmor -o /usr/share/keyrings/xanmod-archive.gpg; then
    echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive.gpg arch=amd64] http://deb.xanmod.org releases main' \
      > /etc/apt/sources.list.d/xanmod-archive.list
    if apt-get update && apt-get install -y linux-xanmod; then
      log "XanMod kernel installed (live session still boots the stock kernel)"
    elif apt-get install -y linux-xanmod-x64v3; then
      log "XanMod x64v3 kernel installed"
    else
      warn "XanMod unavailable — keeping the stock Debian kernel only"
      rm -f /etc/apt/sources.list.d/xanmod-archive.list
      apt-get update || true
    fi
  else
    warn "XanMod signing key fetch failed — skipping custom kernel"
  fi
fi

# ---------------------------------------------------------------------------
log "8/12  Removing Plymouth (verbose text boot)"
# ---------------------------------------------------------------------------
apt-get purge -y 'plymouth*' || warn "plymouth purge reported problems"
rm -rf /etc/plymouth /usr/share/plymouth 2>/dev/null || true

# ---------------------------------------------------------------------------
log "9/12  Branding: icons, logos"
# ---------------------------------------------------------------------------
apt-get install -y imagemagick librsvg2-bin

ICONS=/usr/share/icons/hicolor
for s in 16 22 24 32 48 64 128 256 512; do
  d="$ICONS/${s}x${s}/apps"
  mkdir -p "$d"
  convert /tmp/dk/darkian_square.png -resize "${s}x${s}" "$d/start-here.png"
  cp "$d/start-here.png" "$d/darkian.png"
  cp "$d/start-here.png" "$d/distributor-logo-darkian.png"
  cp "$d/start-here.png" "$d/distributor-logo-debian.png"
done
mkdir -p "$ICONS/scalable/apps"

mkdir -p /usr/share/pixmaps
cp /tmp/dk/darkian.png /usr/share/pixmaps/darkian.png
cp /tmp/dk/darkian.png /usr/share/pixmaps/distributor-logo-darkian.png

# Drop stale Debian/start-here icons from other themes so hicolor wins.
find /usr/share/icons -path '*/hicolor/*' -prune -o -type f \
  \( -name 'start-here*' -o -name 'distributor-logo-debian*' -o -name 'debian-logo*' \) \
  -print0 2>/dev/null | xargs -0 -r rm -f
# Also replace Debian's own hicolor logos with ours (same filename).
for stale in "$ICONS"/*/apps/debian-logo.png "$ICONS"/*/apps/debian-logo.svg; do
  [[ -f "$stale" ]] && rm -f "$stale"
done
# SVG logos ship via the rootfs overlay into hicolor/scalable/apps.

apt-get purge -y imagemagick librsvg2-bin >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
log "10/12  Calamares installer branding"
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
log "11/12  Live session identity"
# ---------------------------------------------------------------------------
log "hostname: $(cat /etc/hostname)"
log "live user: $(grep -E '^(LIVE_USERNAME|LIVE_USER_FULLNAME)=' /etc/live/config.conf | tr '\n' ' ')"

# Fresh machine-id / systemd state so the first boot generates its own
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
rm -f /var/lib/systemd/random-seed

# ---------------------------------------------------------------------------
log "12/12  Cleanup"
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
