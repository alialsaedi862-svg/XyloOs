#!/usr/bin/env bash
#
# build.sh
# ---------------------------------------------------------------------------
# Builds "xyloOS" — a rebranded, lightweight Arch-Linux-based installer ISO,
# bootable via BIOS (isolinux/syslinux) and UEFI (GRUB), hybrid-formatted so
# tools like Rufus can write it straight to a USB drive.
#
# MUST be run as root on an Arch Linux machine (bare metal, VM, or an
# `archlinux` Docker/systemd-nspawn container) — mkarchiso is Arch-only
# tooling and is not available on other distros.
#
# What it does:
#   1. Installs archiso if it isn't already present
#   2. Copies the upstream `releng` archiso profile as a base skeleton
#   3. Overlays this kit's profile/ directory on top (motd, xylo-installer,
#      grub.cfg, splash.png — the files you can see and edit directly)
#   4. Rebrands profiledef.sh, os-release, hostname, package list
#   5. Substitutes the %ISO_LABEL% / %INSTALL_DIR% tokens into grub.cfg
#   6. Adds the black dialog theme and autostarts xylo-installer on tty1,
#      wrapped in a safety-net loop so no crash silently dumps you at an
#      unexplained shell
#   7. Writes a clean 4-item syslinux (BIOS) boot menu
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
  -e "s/^iso_application=.*/iso_application=\"${ISO_APPLICATION}\"/" \
  -e "s#^install_dir=.*#install_dir=\"${INSTALL_DIR}\"#" \
  "${PROFILE_DIR}/profiledef.sh"

# ---- 4. Package list additions ----------------------------------------------
# This is the full set needed across all 17 DE/WM options in xylo-installer,
# plus core installer tooling. xylo-installer itself double-checks each
# selected DE/WM's packages against your actual mirrors before installing
# (pacman -Si) since a couple of these names could not be verified against
# a live Arch repo in the environment that authored this kit.
c_green "==> Adding installer + DE/WM dependencies to packages.x86_64..."
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
dwm
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

# ---- 7. Autostart the wizard on tty1, with a crash-safety net --------------
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
# Auto-launch the xyloOS installer wizard on first console login only.
# Wrapped in a retry loop: if the wizard exits unexpectedly for any reason
# (a bug, Ctrl+C, etc.) this explains what happened and offers to restart
# it, instead of silently dropping to an unexplained shell prompt.
if [[ -z "${XYLOOS_WIZARD_STARTED:-}" && "$(tty)" == "/dev/tty1" ]]; then
    export XYLOOS_WIZARD_STARTED=1
    while true; do
        /usr/local/bin/xylo-installer
        rc=$?
        if [[ $rc -eq 0 ]]; then
            break
        fi
        echo
        echo "-------------------------------------------------------------"
        echo " The installer exited unexpectedly (exit code $rc)."
        echo "-------------------------------------------------------------"
        read -rp "Press Enter to restart the installer, or type 'shell' for a command line: " ans
        if [[ "$ans" == "shell" ]]; then
            echo "Type 'xylo-installer' at any time to relaunch the wizard."
            break
        fi
    done
fi
EOF

# ---- 8. Substitute tokens into the overlaid GRUB config ---------------------
c_green "==> Finalizing GRUB boot menu (background image + labels)..."
GRUB_MAIN="${PROFILE_DIR}/grub/grub.cfg"
if [[ -f "$GRUB_MAIN" ]]; then
  sed -i "s#%INSTALL_DIR%#${INSTALL_DIR}#g; s#%ISO_LABEL%#${ISO_LABEL}#g" "$GRUB_MAIN"
fi
[[ -f "${PROFILE_DIR}/grub/splash.png" ]] || die "profile/grub/splash.png is missing."

# ---- 9. syslinux (BIOS) boot menu --------------------------------------------
c_green "==> Writing syslinux boot menu..."
SYS_CFG="${PROFILE_DIR}/syslinux/archiso_sys.cfg"
if [[ -f "$SYS_CFG" ]]; then
cat > "$SYS_CFG" <<EOF
LABEL xyloos
    MENU LABEL Boot xyloOS Installer (Default)
    LINUX /${INSTALL_DIR}/boot/x86_64/vmlinuz-linux
    INITRD /${INSTALL_DIR}/boot/x86_64/initramfs-linux.img
    APPEND archisobasedir=${INSTALL_DIR} archisolabel=${ISO_LABEL} quiet

LABEL xyloos-safe
    MENU LABEL Boot xyloOS Installer (Safe Graphics / Nomodeset)
    LINUX /${INSTALL_DIR}/boot/x86_64/vmlinuz-linux
    INITRD /${INSTALL_DIR}/boot/x86_64/initramfs-linux.img
    APPEND archisobasedir=${INSTALL_DIR} archisolabel=${ISO_LABEL} nomodeset quiet

LABEL reboot
    MENU LABEL Reboot
    COM32 reboot.c32

LABEL poweroff
    MENU LABEL Power Off
    COM32 poweroff.c32
EOF
fi

if [[ -f "${PROFILE_DIR}/syslinux/archiso_head.cfg" ]]; then
  sed -i "s/^MENU TITLE.*/MENU TITLE xyloOS Boot Menu/" "${PROFILE_DIR}/syslinux/archiso_head.cfg" || true
fi

# Make sure the reboot/poweroff com32 modules are present in the profile
for mod in reboot.c32 poweroff.c32 libutil.c32; do
    for src in "/usr/lib/syslinux/bios/${mod}" "/usr/lib/syslinux/${mod}"; do
        if [[ -f "$src" && -d "${PROFILE_DIR}/syslinux" ]]; then
            cp -n "$src" "${PROFILE_DIR}/syslinux/" 2>/dev/null || true
        fi
    done
done

# ---- 10. Build the ISO ---------------------------------------------------------
c_green "==> Running mkarchiso (this will take a while and needs internet)..."
mkarchiso -v -w "${WORKDIR}/mkarchiso-work" -o "$OUT_DIR" "$PROFILE_DIR"

c_green "==> Build complete:"
ls -lh "$OUT_DIR"/*.iso
c_green "Flash with Rufus using 'DD Image mode' (it will offer this automatically"
c_green "for hybrid ISOs) for full BIOS + UEFI compatibility."
c_green ""
c_green "Recommended: test-boot the ISO in a VM (QEMU/VirtualBox) before writing"
c_green "it to real hardware, since boot menu templates can vary slightly across"
c_green "archiso versions."
