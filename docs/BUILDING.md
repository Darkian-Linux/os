# Building the Darkian Linux ISO

## Requirements

- Ubuntu (WSL2 or bare metal) with root access
- Packages: `xorriso`, `squashfs-tools` (usually preinstalled —
  Cubic already pulls them in)
- ~30 GB free disk on the Linux filesystem
- The base ISO at the path set in `build/config.env` (`BASE_ISO`)
- Internet access during the build (apt installs run inside the chroot)

## Run

```bash
sudo bash build/build.sh
```

That's it. Stages:

1. Extract the ISO media tree (bootloader, kernel, squashfs)
2. Unpack the squashfs root filesystem
3. Apply the `rootfs/` overlay
4. Chroot customization — apt sources, package removal/addition,
   Firefox/Steam/XanMod, Plymouth purge, icon branding, Calamares branding
5. Repack the squashfs (xz — the slowest step)
6. Boot menu edits, GRUB theme, md5sum.txt
7. Rebuild the hybrid bootable ISO with xorriso (reuses the original
   El Torito/isohybrid boot record via `-report_el_torito as_mkisofs`)

**Runtime:** roughly 30–60 minutes depending on CPU and network
(mostly squashfs packing and package downloads).

## Resume & clean

Progress markers live in the work directory (`/var/tmp/darkian-build`):

```bash
sudo bash build/build.sh          # resumes at the first unfinished stage
sudo bash build/build.sh --clean  # wipe the work dir, full rebuild
```

Stages 1–4 use markers (`.extracted`, `.unpacked`); steps 5–7 always
rerun, so after an interrupted build delete `.extracted`/`.unpacked`
only if you need to re-extract.

## Output

```
/var/tmp/darkian-build/Darkian-Linux-13-snake-amd64.iso
build/output/Darkian-Linux-13-snake-amd64.iso        (copy)
build/output/Darkian-Linux-13-snake-amd64.iso.sha256
```

Write it to a USB stick (Windows: Rufus/balenaEtcher, Linux:
`dd if=... of=/dev/sdX bs=4M status=progress`) and boot it.

## Verifying

- `sha256sum -c build/output/*.sha256`
- The build self-checks that the output has an El Torito boot record
- Boot test: check both the GRUB menu (Darkian titles, no quiet/splash)
  and that the Calamares launcher appears on the desktop/menu

## Known limitations

- The ISO **volume label** stays `d-live 13.7.0 kd amd64` (Debian's).
  Changing it is possible but adds boot risk for zero practical gain;
  the file name and everything visible to users says Darkian.
- The live session boots the stock Debian kernel; XanMod is installed
  only on systems installed *from* the ISO (both appear in GRUB there).
- `systemd-boot`/Secure Boot: Debian live uses signed shim; the rebuilt
  ISO keeps the original boot chain unchanged, so Secure Boot behavior
  matches the base Debian ISO.
