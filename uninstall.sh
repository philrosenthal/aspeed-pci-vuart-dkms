#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Undo install.sh: remove the DKMS package and the configuration it added.
# The BMC's SOL settings are left as they are.
#
# With --keep-console, remove only the DKMS package and keep the console,
# initramfs, getty and ipmi_si configuration, for when the kernel has its own
# driver for the device.

set -euo pipefail

PKG=aspeed-pci-8250
MOD=8250_aspeed_pci
STATE_DIR=/var/lib/aspeed-pci-vuart-dkms
STATE=$STATE_DIR/state
MARK="# added by aspeed-pci-vuart-dkms"

info() { printf '\e[1m==>\e[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\e[33mWARNING:\e[0m %s\n' "$*" >&2; }

keep_console=no
assume_yes=no
while [ $# -gt 0 ]; do
	case "$1" in
	--keep-console) keep_console=yes ;;
	-y|--yes) assume_yes=yes ;;
	-h|--help)
		echo "Usage: $0 [--keep-console] [-y]"
		echo "  --keep-console  remove only the DKMS package (for a kernel with its own driver)"
		echo "  -y, --yes       do not ask"
		exit 0 ;;
	*) echo "Unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done

[ "$(id -u)" = 0 ] || { echo "Run as root." >&2; exit 1; }

exec 9>/run/lock/aspeed-pci-vuart-dkms.lock
flock -n 9 || { echo "Another install.sh or uninstall.sh is running." >&2; exit 1; }

# Remove files only if this package wrote them.
rm_owned() {
	local f
	for f in "$@"; do
		[ -e "$f" ] || continue
		if grep -q "aspeed-pci-vuart-dkms" "$f"; then
			rm -f "$f"
		else
			warn "Leaving $f: it was not written by this package."
		fi
	done
}

if [ "$keep_console" = yes ] && command -v aspeed-sol-status >/dev/null &&
   ! aspeed-sol-status 2>/dev/null | grep -q "has its own driver for this device"; then
	warn "Kernel $(uname -r) has no driver of its own for the device: without the"
	warn "DKMS package, SOL goes quiet from the next boot."
	if [ "$assume_yes" = no ]; then
		reply=
		[ -t 0 ] && read -r -p "Remove the DKMS package anyway? [y/N] " reply
		[[ $reply =~ ^[Yy] ]] || exit 1
	fi
fi

state_get() {
	[ -r "$STATE" ] && sed -n "s/^$1=//p" "$STATE" | tail -1
}

if command -v dkms >/dev/null; then
	for v in $(dkms status "$PKG" 2>/dev/null | sed -n "s|^$PKG/\([^,:]*\).*|\1|p" | sort -u); do
		info "Removing $PKG $v from DKMS"
		dkms remove "$PKG/$v" --all || true
		rm -rf "/usr/src/$PKG-$v"
	done
fi

if [ "$keep_console" = yes ]; then
	sed -i "/^version=/d" "$STATE" 2>/dev/null || true
	echo
	info "Done. Only the DKMS package was removed; the console setup stays."
	note "Run aspeed-sol-uninstall without --keep-console to remove the rest as well."
	exit 0
fi

info "Removing the ipmi_si configuration and helper scripts"
# Removing this script's own copy is fine while it runs: bash keeps the
# file open.
rm_owned "/etc/modprobe.d/$PKG.conf" /usr/local/sbin/aspeed-bmc-kcs-args \
	 /usr/local/sbin/aspeed-sol-status /usr/local/sbin/aspeed-sol-uninstall

refresh_boot=no

tty=$(state_get getty)
if [ -n "$tty" ]; then
	info "Disabling serial-getty@$tty"
	# Not --now: stopping it would leave the console port with no user, and
	# the login prompt goes away with the next boot anyway.
	systemctl disable "serial-getty@$tty.service" || true
fi

if grep -qxF "$MARK" /etc/initramfs-tools/modules 2>/dev/null; then
	info "Removing $MOD from /etc/initramfs-tools/modules"
	sed -i "/^$MARK\$/{N;/\n$MOD\$/d}" /etc/initramfs-tools/modules
	refresh_boot=yes
fi

add=$(state_get cmdline_proxmox)
if [ -n "$add" ] && [ -e /etc/kernel/cmdline ]; then
	info "Removing '$add' from /etc/kernel/cmdline"
	sed -i "1s| $add\$||; 1s| $add | |" /etc/kernel/cmdline
	refresh_boot=yes
fi

if [ -e "/etc/default/grub.d/90-$PKG.cfg" ] &&
   grep -q "aspeed-pci-vuart-dkms" "/etc/default/grub.d/90-$PKG.cfg"; then
	info "Removing /etc/default/grub.d/90-$PKG.cfg"
	rm -f "/etc/default/grub.d/90-$PKG.cfg"
	update-grub
	if [ -s /etc/kernel/proxmox-boot-uuids ]; then
		proxmox-boot-tool refresh
	fi
fi

if [ "$refresh_boot" = yes ]; then
	# On Proxmox, its hook also runs proxmox-boot-tool refresh.
	update-initramfs -u -k all
fi

rm -rf /var/lib/aspeed-pci-vuart-dkms

echo
info "Done."
if [ -d "/sys/module/$MOD" ]; then
	note "$MOD stays loaded until the next boot. Do not unload it by hand while"
	note "its port is the kernel console: on current kernels that can crash."
fi
