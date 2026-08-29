#!/usr/bin/env bash
#
# build.sh
# ---------------------------------------------------------------------------
# Builds "xyloOS" — a rebranded, lightweight Arch-Linux-based installer ISO,
# bootable via BIOS (isolinux/syslinux) and UEFI (systemd-boot), hybrid-
# formatted so tools like Rufus can write it straight to a USB drive.
#
# MUST be run as root on an Arch Linux machine (bare metal, VM, or an
# `archlinux` Docker/systemd-nspawn container) — mkarchiso is Arch-only
# tooling and is not available on other distros.
#
# What it does:
#   1. Installs archiso if it isn't already present
#   2. Copies the upstream `releng` archiso profile as a base skeleton
#   3. Overlays this kit's profile/ directory on top (motd, xylo-installer,
#      splash.png — the files you can see and edit directly)
#   4. Rebrands profiledef.sh, os-release, hostname, package list
#   5. Rebrands and hides both boot menus:
#        - UEFI: rewrites efiboot/loader/ (systemd-boot) — this profile's
#          real UEFI bootloader, see profiledef.sh bootmodes
#        - BIOS: rewrites syslinux/archiso_sys-linux.cfg (the real boot
#          entries file), while PRESERVING syslinux/archiso_sys.cfg's
#          INCLUDE/DEFAULT structure — that structure is load-bearing;
#          replacing it outright breaks the whole BIOS menu (learned the
#          hard way — see CHANGELOG at the bottom of this file)
#      Both boot straight into xyloOS with zero "Arch" branding, no
#      visible menu, and a near-zero timeout.
#   6. Sets up a Plymouth splash using the stock "spinner" theme (unbranded
#      for now — see CHANGELOG at the bottom for why) + quiet boot params,
#      so the verbose systemd startup log is hidden
#   7. Adds the black dialog theme and autostarts xylo-installer on tty1
#      unconditionally (no fragile tty-matching — this medium's root
#      account exists only to run the installer)
#   8. Runs mkarchiso to produce the final .iso
#
# Usage:
#   sudo ./build.sh
#
# Output:
#   ./out/xyloos-*.iso
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(pwd)/xyloos-work"
PROFILE_DIR="${WORKDIR}/xyloos-profile"
OUT_DIR="$(pwd)/out"
ISO_NAME="xyloos"
ISO_LABEL="XYLOOS_$(date +%Y%m)"
ISO_PUBLISHER="xyloOS Project"
ISO_APPLICATION="xyloOS Live/Installer"
INSTALL_DIR="xyloos"
# Kernel params shared by both boot paths (UEFI systemd-boot + BIOS syslinux)
# to hide the verbose systemd startup log behind the Plymouth splash.
# Deliberately NOT including systemd.show_status=false: if Plymouth doesn't
# render for any reason, this keeps systemd's own boot status text visible
# as a fallback instead of a blank/black screen with zero information.
QUIET_PARAMS="quiet loglevel=3"

c_green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
die()     { c_red "ERROR: $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Must run as root (sudo ./build.sh)"
command -v pacman >/dev/null 2>&1 || die "This must run on Arch Linux (pacman not found)."
[[ -d "${SCRIPT_DIR}/profile" ]] || die "profile/ not found next to this script."
[[ -f "${SCRIPT_DIR}/profile/airootfs/usr/local/bin/xylo-installer" ]] \
    || die "profile/airootfs/usr/local/bin/xylo-installer is missing."

# ---- 1. Dependencies -------------------------------------------------------
c_green "==> Installing build dependencies..."
pacman -Sy --needed --noconfirm archiso

RELENG_SRC="/usr/share/archiso/configs/releng"
[[ -d "$RELENG_SRC" ]] || die "archiso releng profile not found at $RELENG_SRC"

# ---- 2. Fresh workspace: releng skeleton + this kit's overlay -------------
c_green "==> Preparing workspace..."
rm -rf "$WORKDIR" "$OUT_DIR"
mkdir -p "$WORKDIR" "$OUT_DIR"
cp -r "$RELENG_SRC" "$PROFILE_DIR"

c_green "==> Overlaying profile/ branding files onto the releng skeleton..."
cp -r "${SCRIPT_DIR}/profile/." "${PROFILE_DIR}/"
chmod +x "${PROFILE_DIR}/airootfs/usr/local/bin/xylo-installer"

# ---- 3. profiledef.sh branding ---------------------------------------------
c_green "==> Branding profiledef.sh..."
sed -i \
  -e "s/^iso_name=.*/iso_name=\"${ISO_NAME}\"/" \
  -e "s/^iso_label=.*/iso_label=\"${ISO_LABEL}\"/" \
  -e "s/^iso_publisher=.*/iso_publisher=\"${ISO_PUBLISHER}\"/" \
  -e "s#^iso_application=.*#iso_application=\"${ISO_APPLICATION}\"#" \
  -e "s#^install_dir=.*#install_dir=\"${INSTALL_DIR}\"#" \
  "${PROFILE_DIR}/profiledef.sh"

# Register xylo-installer's executable bit explicitly. Verified against
# real releng's own profiledef.sh: it lists its own custom airootfs
# scripts (choose-mirror, livecd-sound, etc.) in file_permissions the
# same way — mkarchiso treats this array as authoritative for the final
# image rather than trusting whatever chmod was applied during staging,
# which is exactly why xylo-installer was silently non-executable
# ("permission denied") despite being chmod +x'd earlier in this script.
sed -i '/^file_permissions=(/a\  ["/usr/local/bin/xylo-installer"]="0:0:755"' "${PROFILE_DIR}/profiledef.sh"

# Force root's login shell to bash. The releng skeleton (via
# grml-zsh-config in the base package set) defaults root's shell to zsh
# on the live medium — but /root/.bash_profile (our whole auto-launch
# mechanism) is bash-specific and is never sourced by a zsh login at all,
# which is why the installer never launched with zero error output: the
# file containing both the launch call AND its own error handling was
# simply never being read.
if [[ -f "${PROFILE_DIR}/airootfs/etc/passwd" ]]; then
    sed -i -E 's|^(root:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:).*|\1/bin/bash|' "${PROFILE_DIR}/airootfs/etc/passwd"
fi

# ---- 4. Package list additions ----------------------------------------------
# This is the full set needed across all 17 DE/WM options in xylo-installer,
# plus core installer tooling and plymouth (boot splash). xylo-installer
# itself double-checks each selected DE/WM's packages against your actual
# mirrors before installing (pacman -Si) since a couple of these names
# could not be verified against a live Arch repo in the environment that
# authored this kit.
c_green "==> Adding installer + DE/WM + splash dependencies to packages.x86_64..."
cat >> "${PROFILE_DIR}/packages.x86_64" <<'EOF'
dialog
base-devel
git
iwd
wpa_supplicant
dhcpcd
parted
gptfdisk
dosfstools
e2fsprogs
arch-install-scripts
networkmanager
grub
efibootmgr
os-prober
reflector
fastfetch
gnome-shell
gnome-control-center
nautilus
gnome-terminal
gdm
plasma-desktop
sddm
konsole
dolphin
xfce4
xfce4-goodies
lightdm
lightdm-gtk-greeter
mate
mate-extra
cinnamon
lxqt
lxde
budgie-desktop
hyprland
kitty
waybar
dunst
sway
foot
xorg-server
xorg-xinit
xterm
i3-wm
i3status
i3lock
dmenu
rofi
feh
picom
bspwm
sxhkd
awesome
xmonad
xmonad-contrib
herbstluftwm
EOF
sort -u -o "${PROFILE_DIR}/packages.x86_64" "${PROFILE_DIR}/packages.x86_64"
c_red "NOTE: this package list was written from best available knowledge of"
c_red "Arch's official repos, not verified live against a pacman database (no"
c_red "Arch mirror access where this kit was authored). If mkarchiso below"
c_red "fails with 'target not found' for any package, remove that line from"
c_red "packages.x86_64 and check the current name at https://archlinux.org/packages/"
c_red "— the installer itself also re-checks availability at install time."

# ---- 5. Remaining airootfs branding (os-release, hostname) ------------------
c_green "==> Rebranding os-release / hostname..."
AIROOTFS="${PROFILE_DIR}/airootfs"
mkdir -p "${AIROOTFS}/etc"

cat > "${AIROOTFS}/etc/xyloos-release" <<EOF
NAME="xyloOS"
PRETTY_NAME="xyloOS Live"
ID=xyloos
ID_LIKE=arch
BUILD_ID=$(date +%Y%m%d)
ANSI_COLOR="1;36"
EOF
ln -sf xyloos-release "${AIROOTFS}/etc/os-release"

echo "xyloos" > "${AIROOTFS}/etc/hostname"

mkdir -p "${AIROOTFS}/etc/profile.d"
cat > "${AIROOTFS}/etc/profile.d/xyloos-aliases.sh" <<'EOF'
alias xyloinstall='sudo xylo-installer'
EOF

# ---- 6. Black dialog theme (replaces the default blue screen) --------------
c_green "==> Installing black dialog theme..."
mkdir -p "${AIROOTFS}/etc/xyloos"
cat > "${AIROOTFS}/etc/xyloos/dialogrc" <<'EOF'
screen_color = (WHITE,BLACK,OFF)
shadow_color = (BLACK,BLACK,OFF)
dialog_color = (WHITE,BLACK,OFF)
title_color = (CYAN,BLACK,ON)
border_color = (WHITE,BLACK,OFF)
button_active_color = (BLACK,CYAN,ON)
button_inactive_color = dialog_color
button_key_active_color = button_active_color
button_key_inactive_color = (CYAN,BLACK,OFF)
button_label_active_color = (BLACK,CYAN,ON)
button_label_inactive_color = (WHITE,BLACK,ON)
inputbox_color = dialog_color
inputbox_border_color = dialog_color
searchbox_color = dialog_color
searchbox_title_color = title_color
searchbox_border_color = border_color
position_indicator_color = title_color
menubox_color = dialog_color
menubox_border_color = border_color
item_color = dialog_color
item_selected_color = button_active_color
tag_color = title_color
tag_selected_color = button_label_active_color
tag_key_color = button_key_inactive_color
tag_key_selected_color = (BLACK,CYAN,ON)
check_color = dialog_color
check_selected_color = button_active_color
uarrow_color = (CYAN,BLACK,ON)
darrow_color = uarrow_color
itemhelp_color = (WHITE,BLACK,OFF)
form_active_text_color = button_active_color
form_text_color = (WHITE,BLACK,ON)
form_item_readonly_color = (CYAN,BLACK,ON)
gauge_color = title_color
border2_color = dialog_color
inputbox_border2_color = dialog_color
searchbox_border2_color = dialog_color
menubox_border2_color = dialog_color
EOF

# ---- 7. No Plymouth splash (disabled — see CHANGELOG at the bottom) -------
# Plymouth has caused repeated, hard-to-verify problems across several
# rounds (a pacman file conflict, then — confirmed via boot test — showing
# Arch's own bundled fallback logo instead of our config's chosen theme).
# Given zero Arch branding anywhere is a hard requirement, disabling the
# splash entirely is the only way to *guarantee* no logo can appear, so
# that's what this does for now. Boot is plain "quiet" (readable text, no
# graphical splash) instead. A properly branded splash is worth revisiting
# later as its own isolated piece, once it can be done with much tighter
# verification than trial-and-error against a live boot each time.
c_green "==> Skipping Plymouth splash (disabled — see build.sh CHANGELOG)."

# ---- 8. Autostart the wizard on tty1 (unconditional — no shell fallback) ---
c_green "==> Configuring autostart on tty1..."
mkdir -p "${AIROOTFS}/etc/systemd/system/getty@tty1.service.d"
# NOTE: the 'EOF' delimiter here is QUOTED deliberately — this keeps $TERM
# literal so agetty resolves it at its own runtime, instead of this build
# script substituting whatever $TERM happens to be set to on the machine
# running build.sh right now.
cat > "${AIROOTFS}/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF

mkdir -p "${AIROOTFS}/root"
cat > "${AIROOTFS}/root/.bash_profile" <<'EOF'
# Auto-launch the xyloOS installer wizard on login.
# This account exists solely to run the installer, so this launches
# unconditionally rather than gating on a tty-string match (which is
# fragile depending on exactly how the login was spawned, and previously
# caused the wizard to silently fail to start on some hardware).
if [[ -z "${XYLOOS_WIZARD_STARTED:-}" ]]; then
    export XYLOOS_WIZARD_STARTED=1
    clear
    /usr/local/bin/xylo-installer
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo
        echo "-------------------------------------------------------------"
        echo " The installer exited unexpectedly (exit code $rc)."
        echo " Type 'xylo-installer' at any time to relaunch it."
        echo "-------------------------------------------------------------"
    fi
fi
EOF

# ---- 9. Rebrand + hide the UEFI boot menu (systemd-boot) -------------------
# This profile's actual UEFI boot mode is systemd-boot (see profiledef.sh
# bootmodes), not GRUB — mkarchiso never reads profile/grub/grub.cfg for
# UEFI at all. That file is left in place below purely as inert legacy
# content; the real UEFI menu lives in efiboot/loader/.
#
# The entry below matches the real upstream releng entry's structure
# exactly (verified against archlinux/archiso's actual source) — same
# %ARCH%/%INSTALL_DIR%/%ARCHISO_UUID% tokens that mkarchiso substitutes
# automatically, and critically NO separate ucode initrd lines: an
# earlier version of this kit added initrd lines for intel-ucode.img/
# amd-ucode.img that don't exist as separate files in the real boot
# layout (microcode is folded into the main initramfs already) — those
# bogus references are the most likely cause of a blank screen on boot.
c_green "==> Rebranding + hiding the UEFI boot menu (systemd-boot)..."
EFIBOOT_LOADER="${PROFILE_DIR}/efiboot/loader"
mkdir -p "${EFIBOOT_LOADER}/entries"
rm -f "${EFIBOOT_LOADER}"/entries/*.conf

cat > "${EFIBOOT_LOADER}/loader.conf" <<'EOF'
timeout 0
default 01-xyloos-install.conf
console-mode max
EOF

cat > "${EFIBOOT_LOADER}/entries/01-xyloos-install.conf" <<EOF
title    xyloOS Installer
sort-key 01
linux    /%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux
initrd   /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux.img
options  archisobasedir=%INSTALL_DIR% archisosearchuuid=%ARCHISO_UUID% ${QUIET_PARAMS}
EOF

# ---- 10. Rebrand + hide the BIOS boot menu (syslinux) ----------------------
# CRITICAL STRUCTURE NOTE (learned from a real broken build): the boot
# chain for local media is syslinux.cfg -> archiso_sys.cfg -> [INCLUDE
# archiso_head.cfg (menu system/UI), DEFAULT + TIMEOUT, INCLUDE
# archiso_sys-linux.cfg (the actual boot entries)]. An earlier version of
# this kit fully overwrote archiso_sys.cfg with a flat entry list, which
# silently deleted the INCLUDE archiso_head.cfg line (where "UI
# vesamenu.c32" lives) and the DEFAULT directive — producing exactly the
# ISOLINUX error "No DEFAULT or UI configuration directive found!" at
# boot. The fix below preserves that structure and puts our custom
# entries in archiso_sys-linux.cfg, which is the file actually meant for
# them (verified against archlinux/archiso's real source).
c_green "==> Rebranding + hiding the BIOS boot menu (syslinux)..."
SYSLINUX_DIR="${PROFILE_DIR}/syslinux"

if [[ -f "${SYSLINUX_DIR}/archiso_head.cfg" ]]; then
  sed -i "s/^MENU TITLE.*/MENU TITLE xyloOS Boot Menu/" "${SYSLINUX_DIR}/archiso_head.cfg" || true
fi
# Use our own logo for the BIOS menu background too (MENU BACKGROUND in
# archiso_head.cfg is a relative reference to a file in this directory).
cp "${PROFILE_DIR}/grub/splash.png" "${SYSLINUX_DIR}/splash.png" 2>/dev/null || true

cat > "${SYSLINUX_DIR}/archiso_sys.cfg" <<'EOF'
INCLUDE archiso_head.cfg

DEFAULT xyloos
TIMEOUT 1

INCLUDE archiso_sys-linux.cfg

LABEL reboot
    MENU LABEL Reboot
    COM32 reboot.c32

LABEL poweroff
    MENU LABEL Power Off
    COM32 poweroff.c32
EOF

cat > "${SYSLINUX_DIR}/archiso_sys-linux.cfg" <<EOF
LABEL xyloos
MENU LABEL Boot xyloOS Installer (Default)
LINUX /%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux
INITRD /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux.img
APPEND archisobasedir=%INSTALL_DIR% archisosearchuuid=%ARCHISO_UUID% ${QUIET_PARAMS}

LABEL xyloos-safe
MENU LABEL Boot xyloOS Installer (Safe Graphics / Nomodeset)
LINUX /%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux
INITRD /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux.img
APPEND archisobasedir=%INSTALL_DIR% archisosearchuuid=%ARCHISO_UUID% nomodeset ${QUIET_PARAMS}
EOF

# Make sure the reboot/poweroff com32 modules are present in the profile
for mod in reboot.c32 poweroff.c32 libutil.c32; do
    for src in "/usr/lib/syslinux/bios/${mod}" "/usr/lib/syslinux/${mod}"; do
        if [[ -f "$src" && -d "$SYSLINUX_DIR" ]]; then
            cp -n "$src" "${SYSLINUX_DIR}/" 2>/dev/null || true
        fi
    done
done

# ---- 11. Build the ISO ---------------------------------------------------------
c_green "==> Running mkarchiso (this will take a while and needs internet)..."
mkarchiso -v -w "${WORKDIR}/mkarchiso-work" -o "$OUT_DIR" "$PROFILE_DIR"

c_green "==> Build complete:"
ls -lh "$OUT_DIR"/*.iso
c_green "Flash with Rufus using 'DD Image mode' (it will offer this automatically"
c_green "for hybrid ISOs) for full BIOS + UEFI compatibility."

# ---------------------------------------------------------------------------
# CHANGELOG (kept here so future edits don't reintroduce fixed bugs)
# ---------------------------------------------------------------------------
# - dwm removed from the live-ISO package list (not in official repos;
#   built from source at install time instead by xylo-installer)
# - BIOS boot menu: archiso_sys.cfg's INCLUDE/DEFAULT structure must be
#   preserved, not overwritten wholesale — see step 10 above
# - UEFI boot menu: no separate ucode initrd lines; use the same
#   %ARCH%/%INSTALL_DIR%/%ARCHISO_UUID% tokens the real releng entries use
# - Plymouth: airootfs is overlaid BEFORE pacstrap runs (confirmed in
#   archiso's own docs), so pre-placing a file at a path the plymouth
#   package also ships (spinner theme's watermark.png) breaks pacstrap
#   with a file-conflict error.
# - Plymouth, take 2: switched to the unbranded stock "spinner" theme via
#   plymouthd.conf to sidestep the conflict above. On a real boot this
#   showed ARCH'S OWN logo instead — Arch's plymouth package defaults to
#   theme "bgrt", which falls back to a bundled Arch-branded image when no
#   vendor boot logo is found in firmware; the plymouthd.conf override did
#   not take effect early enough to prevent this. Given zero Arch branding
#   is a hard requirement, Plymouth is disabled entirely for now (plain
#   quiet boot, no splash) rather than keep iterating blind on this one
#   piece — a properly branded splash is a good separate follow-up later,
#   done with tighter verification than trial-and-error on live boots.
