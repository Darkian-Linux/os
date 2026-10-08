# Darkian Linux

**Darkian Linux 13 "Snake"** — a custom Linux distribution based on
[Debian 13 (trixie)](https://www.debian.org/) with the KDE Plasma desktop,
built for dark-mode-first use with the Darkian brand throughout.

- Website: <https://darkian.xyz>
- Base: Debian 13 "trixie" (live KDE image)
- Desktop: KDE Plasma 6
- Installer: Calamares (branded for Darkian Linux)
- License: GPL-3.0

## What's customized

| Area | Changes |
|---|---|
| Identity | `os-release`, hostname `darkianlive`, live user *Darkian Live User*, issue/motd/lsb-release |
| Boot | Verbose text boot (Plymouth removed, `quiet`/`splash` stripped), Darkian GRUB menu titles, Darkian wallpaper as GRUB background |
| Desktop | Breeze Dark global theme, Darkian wallpaper, custom start-menu / About logos, Firefox as default browser |
| Installer | Calamares branded *Darkian Linux 13* (logo, colors, slideshow, GRUB entry), launcher on the desktop and in the app menu runs elevated via `pkexec` |
| Apps added | VLC, Gwenview, htop, btop, fastfetch, vim, nano, git, curl, wget, Flatpak, Steam, Firefox (Mozilla build, not ESR) |
| Apps removed | LibreOffice, Thunderbird, GIMP, Firefox ESR |
| Drivers | Mesa Vulkan (Intel/AMD), Intel media VA-API (non-free), NVIDIA driver, full firmware set |
| Kernel | Stock Debian kernel in the live session; optional [XanMod](https://www.xanmod.org/) kernel installed alongside it for the installed system (GRUB keeps both) |

## Repository layout

```
os/
├── build/
│   ├── build.sh            # main pipeline: extract → customize → rebuild
│   ├── chroot.sh           # runs inside the rootfs (packages, branding)
│   ├── config.env          # all knobs: paths, names, feature flags
│   ├── packages-add.txt    # packages to install
│   └── packages-remove.txt # packages to purge
├── rootfs/                 # files overlaid onto the live filesystem
│   ├── etc/                # os-release, hostname, Calamares, skel/, ...
│   └── usr/share/          # wallpaper, icons, installer launcher
├── assets/                 # Darkian logos + wallpaper (source of truth)
└── docs/BUILDING.md        # build instructions
```

## Building

Requires Ubuntu (or another full Linux) with `xorriso`, `squashfs-tools`
and root access. Inside WSL:

```bash
sudo bash build/build.sh
```

Output: `build/output/Darkian-Linux-13-snake-amd64.iso` (+ `.sha256`).
See [docs/BUILDING.md](docs/BUILDING.md) for details, resume/clean behavior
and expected runtime.

## Customizing

- **Packages** — edit `build/packages-add.txt` / `build/packages-remove.txt`
- **Names, paths, feature flags** — edit `build/config.env`
- **System files** — edit anything under `rootfs/`
- **Logo/wallpaper** — replace files in `assets/`

Then rerun the build.

## Credits

- [Debian](https://www.debian.org/) — base operating system
- [Calamares](https://calamares.io/) — system installer
- [XanMod](https://www.xanmod.org/) — optional optimized kernel
- KDE — Plasma desktop environment

## License

[GPL-3.0](LICENSE)
