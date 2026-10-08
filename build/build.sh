#!/usr/bin/env bash
#
# Darkian Linux — ISO build pipeline
#
# Extracts the Debian 13 live ISO, applies the rootfs overlay, runs the
# chroot customizations (packages, branding, Calamares, Plymouth removal),
# repacks the squashfs and rebuilds a bootable hybrid ISO.
#
# Usage:
#   sudo bash build/build.sh            # full build (resumes at failed stage)
#   sudo bash build/build.sh --clean    # wipe the work directory first
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=config.env
source "$SCRIPT_DIR/config.env"

log()  { echo -e "\e[1;35m[darkian]\e[0m $*"; }
warn() { echo -e "\e[1;33m[darkian]\e[0m WARNING: $*"; }
die()  { echo -e "\e[1;31m[darkian]\e[0m ERROR: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "This script must run as root:  sudo bash $0"

for tool in xorriso unsquashfs mksquashfs md5sum awk grep sed find; do
  command -v "$tool" >/dev/null || die "missing tool: $tool"
done
[[ -f "$BASE_ISO" ]] || die "base ISO not found: $BASE_ISO"

WORK="$WORK_DIR"
ISO_DIR="$WORK/iso"
ROOTFS="$WORK/rootfs"
OUT_ISO="$WORK/$OUTPUT_ISO_NAME"

if [[ "${1:-}" == "--clean" ]]; then
  log "Cleaning work directory $WORK"
  rm -rf "$WORK"
fi
mkdir -p "$WORK" "$REPO_DIR/build/output"

IMG_MNT=""

cleanup() {
  set +e
  mountpoint -q "$ROOTFS/dev" 2>/dev/null && umount -R "$ROOTFS/dev"
  mountpoint -q "$ROOTFS/proc" 2>/dev/null && umount "$ROOTFS/proc"
  mountpoint -q "$ROOTFS/sys"  2>/dev/null && umount "$ROOTFS/sys"
  [[ -n "$IMG_MNT" && -n "$(ls -A "$IMG_MNT" 2>/dev/null)" ]] && umount -l "$IMG_MNT"
  return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
log "[1/7] Extracting ISO media tree"
# ---------------------------------------------------------------------------
if [[ ! -f "$WORK/.extracted" ]]; then
  rm -rf "$ISO_DIR"
  mkdir -p "$ISO_DIR"
  xorriso -osirrox on -indev "$BASE_ISO" -extract / "$ISO_DIR" >/dev/null 2>&1 \
    || die "ISO extraction failed"
  touch "$WORK/.extracted"
fi

SQFS="$(find "$ISO_DIR/live" -maxdepth 1 -name '*.squashfs' 2>/dev/null | head -n1 || true)"
[[ -n "$SQFS" ]] || die "no live/filesystem.squashfs found in the ISO"
[[ -f "$ISO_DIR/isolinux/isolinux.bin" ]] || warn "isolinux.bin missing — BIOS boot may be affected"
[[ -f "$ISO_DIR/boot/grub/efi.img" ]]     || warn "efi.img missing — UEFI boot may be affected"

# ---------------------------------------------------------------------------
log "[2/7] Unpacking root filesystem (squashfs)"
# ---------------------------------------------------------------------------
if [[ ! -f "$WORK/.unpacked" ]]; then
  rm -rf "$ROOTFS"
  mkdir -p "$ROOTFS"
  unsquashfs -d "$ROOTFS" "$SQFS" >/dev/null 2>&1 || die "unsquashfs failed"
  touch "$WORK/.unpacked"
fi

# ---------------------------------------------------------------------------
log "[3/7] Applying rootfs overlay"
# ---------------------------------------------------------------------------
cp -a "$REPO_DIR/rootfs/." "$ROOTFS/"

# The repo lives on a Windows/drvfs mount where every file may show up as
# 0777 — normalize permissions so the image gets sane modes.
while IFS= read -r -d '' src; do
  rel="${src#"$REPO_DIR/rootfs/"}"
  dst="$ROOTFS/$rel"
  if [[ -d "$src" ]]; then
    chmod 755 "$dst"
  elif [[ "$src" == *.desktop ]]; then
    chmod 755 "$dst"
  else
    chmod 644 "$dst"
  fi
done < <(find "$REPO_DIR/rootfs" -mindepth 1 -print0)

# ---------------------------------------------------------------------------
log "[4/7] Customizing system inside chroot"
# ---------------------------------------------------------------------------
install -d -m 755 "$ROOTFS/tmp/dk"
cp "$SCRIPT_DIR/config.env" \
   "$SCRIPT_DIR/packages-add.txt" \
   "$SCRIPT_DIR/packages-remove.txt" "$ROOTFS/tmp/dk/"
cp "$REPO_DIR/assets/darkian.png" \
   "$REPO_DIR/assets/darkian_square.png" \
   "$REPO_DIR/assets/wallpaper.png" "$ROOTFS/tmp/dk/"
cp "$SCRIPT_DIR/chroot.sh" "$ROOTFS/tmp/chroot.sh"

rm -f "$ROOTFS/etc/resolv.conf"
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
grep -q '1.1.1.1' "$ROOTFS/etc/resolv.conf" || echo 'nameserver 1.1.1.1' >> "$ROOTFS/etc/resolv.conf"
chmod 644 "$ROOTFS/etc/resolv.conf"

mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sysfs "$ROOTFS/sys"
mount --rbind /dev "$ROOTFS/dev"
mount --make-rslave "$ROOTFS/dev" 2>/dev/null || true

chroot "$ROOTFS" /usr/bin/env -i \
  HOME=/root \
  TERM="${TERM:-dumb}" \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  DEBIAN_FRONTEND=noninteractive \
  bash /tmp/chroot.sh

umount -R "$ROOTFS/dev"
umount "$ROOTFS/proc"
umount "$ROOTFS/sys"

# ---------------------------------------------------------------------------
log "[5/7] Repacking squashfs (xz — this is the slow part)"
# ---------------------------------------------------------------------------
SQ_OUT="$WORK/filesystem-new.squashfs"
rm -f "$SQ_OUT"
MKSQ_OPTS=(-comp "$SQUASHFS_COMPRESS" -b 1048576 -no-progress)
if [[ "$SQUASHFS_COMPRESS" == "xz" ]]; then
  MKSQ_OPTS+=(-Xbcj x86)
fi
mksquashfs "$ROOTFS" "$SQ_OUT" "${MKSQ_OPTS[@]}"
rm -f "$SQFS"
mv "$SQ_OUT" "$SQFS"
log "squashfs repacked: $(du -h "$SQFS" | cut -f1)"

# ---------------------------------------------------------------------------
log "[6/7] Boot menu, theme and checksums"
# ---------------------------------------------------------------------------
GRUB_CFG="$ISO_DIR/boot/grub/grub.cfg"

# Verbose text boot: strip 'quiet' and 'splash' kernel parameters
find "$ISO_DIR/boot/grub" -name '*.cfg' -type f -print0 |
  xargs -0 sed -ri 's/(^|[[:space:]])quiet([[:space:]]|$)/\1\2/g; s/(^|[[:space:]])splash([[:space:]]|$)/\1\2/g'

# Rebrand menu titles
if [[ -f "$GRUB_CFG" ]]; then
  sed -i \
    -e 's/menuentry "Live system (amd64)"/menuentry "Darkian Linux 13 (amd64)"/' \
    -e 's/menuentry "Live system (amd64 fail-safe mode)"/menuentry "Darkian Linux 13 (amd64 fail-safe mode)"/' \
    "$GRUB_CFG"
fi

# GRUB theme background: replace a 1920x1080 PNG with the Darkian wallpaper
while IFS= read -r -d '' png; do
  if file "$png" | grep -q '1920 x 1080'; then
    cp "$REPO_DIR/assets/wallpaper.png" "$png"
    log "GRUB theme background replaced: $png"
  fi
done < <(find "$ISO_DIR/boot/grub" -name '*.png' -size +100k -print0 2>/dev/null)

# Regenerate md5sum.txt (used by the 'Verify integrity' boot entry)
log "Regenerating md5sum.txt"
(
  cd "$ISO_DIR"
  find . -type f ! -name md5sum.txt -print0 | sort -z | xargs -0 md5sum > md5sum.txt
)

# ---------------------------------------------------------------------------
log "[7/7] Rebuilding bootable ISO with xorriso"
# ---------------------------------------------------------------------------
xorriso -indev "$BASE_ISO" -report_el_torito as_mkisofs 2>/dev/null \
  | grep '^-' > "$WORK/iso-template.txt" || true
[[ -s "$WORK/iso-template.txt" ]] || die "could not derive boot template from base ISO"

# The report is shell-quoted and paste-able; load it as an argument array.
eval "TEMPLATE=( $(cat "$WORK/iso-template.txt") )"

rm -f "$OUT_ISO"
(
  cd "$ISO_DIR"
  xorriso -as mkisofs -r -J -joliet-long -l -iso-level 3 \
    "${TEMPLATE[@]}" \
    -o "$OUT_ISO" .
)

[[ -s "$OUT_ISO" ]] || die "output ISO was not created"
sha256sum "$OUT_ISO" > "$OUT_ISO.sha256"

log "Verifying output ISO structure"
xorriso -indev "$OUT_ISO" -report_el_torito plain >/dev/null 2>&1 \
  || die "output ISO has no El Torito boot record"

mkdir -p "$REPO_DIR/build/output"
cp "$OUT_ISO" "$OUT_ISO.sha256" "$REPO_DIR/build/output/"

log "============================================================"
log "BUILD COMPLETE"
log "  ISO:     $OUT_ISO"
log "  SHA256:  $(cut -d' ' -f1 "$OUT_ISO.sha256")"
log "  Copy:    $REPO_DIR/build/output/$OUTPUT_ISO_NAME"
log "============================================================"
