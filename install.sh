#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Install the 8250_aspeed_pci driver with DKMS, so that the serial ports of an
# ASPEED BMC that are only reachable over PCIe (IPMI Serial over LAN) work in
# Linux. See README.md.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PKG=aspeed-pci-8250
MOD=8250_aspeed_pci
VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$HERE/dkms/dkms.conf")
STATE_DIR=/var/lib/aspeed-pci-vuart-dkms
STATE=$STATE_DIR/state
MARK="# added by aspeed-pci-vuart-dkms"

console=ask
kcs_fix=no
install_deps=yes
assume_yes=no
baud=
tty_opt=
sol_tune=ask

usage() {
	cat <<EOF
Usage: $0 [options]

Installs $PKG $VER (the $MOD driver) with DKMS.

  --console        make the BMC serial port the kernel console and start a
                   login prompt on it without asking (the default, after
                   asking when run interactively)
  --no-console     only install the driver: no kernel command line, initramfs
                   or getty changes
  --baud RATE      console speed: 9600, 19200, 38400, 57600 or 115200
                   (default: the BMC's SOL bit rate, or 115200)
  --tty ttySN      the serial port that carries SOL, when the BMC exposes two
  --sol-tune       set the BMC's SOL character accumulate interval to 25 ms and
                   send threshold to 255 characters, if not set already
  --no-sol-tune    leave the BMC's SOL settings alone
  --kcs-fix        point ipmi_si at BAR1 + 0xe88 instead of the ACPI address
                   (only for boards whose ACPI KCS address goes stale; see README)
  --no-deps        do not install packages (dkms, kernel headers) with apt
  -y, --yes        do not ask questions
  -h, --help       show this help
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--console) console=yes ;;
	--no-console) console=no ;;
	--baud) baud=${2:?--baud needs a value}; shift ;;
	--tty) tty_opt=${2:?--tty needs a value}; shift ;;
	--kcs-fix) kcs_fix=yes ;;
	--sol-tune) sol_tune=yes ;;
	--no-sol-tune) sol_tune=no ;;
	--no-deps) install_deps=no ;;
	-y|--yes) assume_yes=yes ;;
	-h|--help) usage; exit 0 ;;
	*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

case "$baud" in
""|9600|19200|38400|57600|115200) ;;
*) echo "--baud must be 9600, 19200, 38400, 57600 or 115200" >&2; exit 2 ;;
esac
case "$tty_opt" in
""|ttyS[0-9]|ttyS[0-9][0-9]|ttyS[0-9][0-9][0-9]) ;;
*) echo "--tty must be a ttyS port name, e.g. ttyS5" >&2; exit 2 ;;
esac

info() { printf '\e[1m==>\e[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\e[33mWARNING:\e[0m %s\n' "$*" >&2; }
die() { printf '\e[31mERROR:\e[0m %s\n' "$*" >&2; exit 1; }

# Ask a yes/no question that defaults to no (yes with -y; no when not interactive).
ask() {
	local reply
	[ "$assume_yes" = yes ] && return 0
	[ -t 0 ] || return 1
	read -r -p "$1 [y/N] " reply
	[[ $reply =~ ^[Yy] ]]
}

# The same, defaulting to yes (also when not interactive).
ask_default_yes() {
	local reply
	[ "$assume_yes" = yes ] && return 0
	[ -t 0 ] || return 0
	read -r -p "$1 [Y/n] " reply
	[[ ! $reply =~ ^[Nn] ]]
}

state_get() {
	[ -r "$STATE" ] && sed -n "s/^$1=//p" "$STATE" | tail -1
	return 0
}

# Whether a file is absent or was written by this package, i.e. safe to
# replace or remove.
owned() {
	[ ! -e "$1" ] || grep -q "aspeed-pci-vuart-dkms" "$1"
}

# install(1) a file of this package, refusing to replace someone else's.
install_owned() {
	local mode=$1 src=$2 dst=$3
	owned "$dst" || die "$dst exists and was not installed by this package; move it away and rerun."
	install -m "$mode" "$src" "$dst"
}

state_set() {
	mkdir -p "$STATE_DIR"
	touch "$STATE"
	sed -i "/^$1=/d" "$STATE"
	echo "$1=$2" >>"$STATE"
}

# The certificate DKMS signs modules with: mok_certificate if configured,
# otherwise the distribution's default (Ubuntu patches DKMS to use shim-signed's).
dkms_cert() {
	local c
	c=$(sed -n 's/^ *mok_certificate=["'\'']\{0,1\}\([^"'\'']*\).*/\1/p' \
		/etc/dkms/framework.conf /etc/dkms/framework.conf.d/*.conf 2>/dev/null | tail -1)
	[ -n "$c" ] && { echo "$c"; return 0; }
	. /etc/os-release
	if [ "$ID" = ubuntu ]; then
		echo /var/lib/shim-signed/mok/MOK.der
	else
		echo /var/lib/dkms/mok.pub
	fi
}

find_device() {
	local d
	for d in /sys/bus/pci/devices/*; do
		[ "$(cat "$d/vendor")" = 0x1a03 ] &&
			[ "$(cat "$d/device")" = 0x2402 ] && { echo "$d"; return; }
	done
	return 0
}

# The ttyS ports of the device, one per line.
find_ttys() {
	local t bdf=${1##*/}
	for t in /sys/class/tty/ttyS*; do
		case "$(readlink -f "$t/device" 2>/dev/null)" in
		*/"$bdf"/*) echo "${t##*/}" ;;
		esac
	done
	return 0
}

# --- checks ------------------------------------------------------------------

[ "$(id -u)" = 0 ] || die "Run as root."
[ -n "$VER" ] || die "Cannot read PACKAGE_VERSION from $HERE/dkms/dkms.conf"

exec 9>/run/lock/aspeed-pci-vuart-dkms.lock
flock -n 9 || die "Another install.sh or uninstall.sh is running."

. /etc/os-release
distro=$ID
command -v pveversion >/dev/null && distro=proxmox
case "$distro:${VERSION_ID:-}" in
proxmox:13*) distro_name="Proxmox VE $(pveversion | sed -n 's|^pve-manager/\([0-9.]*\).*|\1|p')" ;;
debian:13*) distro_name="Debian 13" ;;
ubuntu:24.04|ubuntu:26.04) distro_name="Ubuntu $VERSION_ID" ;;
*)
	distro_name="$PRETTY_NAME"
	warn "$distro_name is not a tested distribution (tested: Proxmox VE 9, Debian 13, Ubuntu 24.04 and 26.04)."
	ask "Continue anyway?" || exit 1
	;;
esac
info "Installing $PKG $VER on $distro_name, kernel $(uname -r)"

dev=$(find_device)
if [ -z "$dev" ]; then
	warn "No ASPEED BMC PCIe device (1a03:2402) found. The driver will be installed but has nothing to bind."
	ask "Continue anyway?" || exit 1
else
	class=$(cat "$dev/class")
	note "Found the BMC device at ${dev##*/} (class $class, revision $(cat "$dev/revision"))"
	if [ "$class" != 0x0c0701 ]; then
		warn "The device's class is $class, not 0x0c0701 (KCS). The BMC firmware has set it up for another driver, and $MOD will not bind to it."
		ask "Continue anyway?" || exit 1
	fi
fi

# --- packages ----------------------------------------------------------------

if [ "$install_deps" = yes ]; then
	info "Updating the package lists"
	apt-get update -qq || warn "apt-get update failed; trying with the current package lists."
	pkgs=(dkms)
	kver=$(uname -r)
	if [ "$distro" = proxmox ]; then
		pkgs+=("proxmox-headers-$kver" proxmox-default-headers)
	else
		pkgs+=("linux-headers-$kver")
		# Headers for the kernels to come: the linux-headers-* metapackage
		# matching each installed linux-image-* metapackage.
		while read -r meta; do
			h=linux-headers-${meta#linux-image-}
			apt-cache show "$h" >/dev/null 2>&1 && pkgs+=("$h")
		done < <(dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' 'linux-image-*' 2>/dev/null |
			 awk '$1 == "ii" && $2 !~ /^linux-image-([0-9]|unsigned-|uc-)|-dbg/ { print $2 }')
	fi
	info "Installing packages: ${pkgs[*]}"
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}" ||
		die "apt-get failed. Install dkms and the headers for $(uname -r) yourself, then rerun with --no-deps."
fi

command -v dkms >/dev/null || die "dkms is not installed."
dkms_major=$(dkms --version | sed -n 's/^dkms-\{0,1\}\([0-9]*\).*/\1/p')
[ "${dkms_major:-0}" -ge 3 ] || warn "dkms $(dkms --version) is older than 3.x, which is untested."
[ -e "/lib/modules/$(uname -r)/build" ] ||
	die "No kernel headers for $(uname -r). Install them (or reboot into the newest kernel) and rerun."

# --- driver --------------------------------------------------------------------

for old in $(dkms status "$PKG" 2>/dev/null | sed -n "s|^$PKG/\([^,:]*\).*|\1|p" | sort -u); do
	info "Removing $PKG $old from DKMS"
	dkms remove "$PKG/$old" --all || true
	[ "$old" = "$VER" ] || rm -rf "/usr/src/$PKG-$old"
done

info "Copying the source to /usr/src/$PKG-$VER"
rm -rf "/usr/src/$PKG-$VER"
mkdir -p "/usr/src/$PKG-$VER"
cp "$HERE"/dkms/{dkms.conf,Makefile,8250_aspeed_pci.c,8250_pcilib.h} "/usr/src/$PKG-$VER/"

info "Building and installing with DKMS"
dkms add "$PKG/$VER"
built=no
for build in /lib/modules/*/build; do
	k=$(basename "$(dirname "$build")")
	# Skip headers left behind by kernels that are no longer installed.
	if [ ! -e "$build/Makefile" ] || [ ! -d "/lib/modules/$k/kernel" ]; then
		continue
	fi
	rc=0
	dkms install "$PKG/$VER" -k "$k" || rc=$?
	case $rc in
	0)	[ "$k" = "$(uname -r)" ] && built=yes ;;
	77)	note "Skipped kernel $k (older than 6.8, or it has the driver built in)" ;;
	*)	warn "DKMS could not build $PKG for kernel $k (see the make.log path above)." ;;
	esac
done
[ "$built" = yes ] || die "$MOD was not built for the running kernel $(uname -r)."

# --- Secure Boot ---------------------------------------------------------------

sb_pending=no
if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -q enabled; then
	key=$(dkms_cert)
	if [ ! -e "$key" ]; then
		warn "Secure Boot is on, but the DKMS signing key ($key) does not exist. $MOD will not load."
	elif mokutil --test-key "$key" 2>/dev/null | grep -q "is already enrolled"; then
		info "Secure Boot is on, and the DKMS signing key is already enrolled"
	else
		info "Secure Boot is on, and the DKMS signing key ($key) is not enrolled yet"
		note "Until it is, the firmware rejects $MOD (and every other DKMS module)."
		note "mokutil asks for a one-time password now. On the next boot, a blue"
		note "'MOK management' screen appears: choose 'Enroll MOK', 'Continue', 'Yes',"
		note "and type that password. Use the BMC's remote KVM for this: the serial"
		note "console does not work yet at that point. If nobody answers the screen,"
		note "it times out and boots without enrolling the key."
		if ask "Queue the key for enrollment now?"; then
			mokutil --import "$key" && sb_pending=yes
		else
			note "Later: mokutil --import $key, then reboot."
		fi
	fi
fi

# --- ipmi_si -------------------------------------------------------------------

info "Keeping ipmi_si's PCI driver off the device (/etc/modprobe.d/$PKG.conf)"
if [ "$kcs_fix" = yes ]; then
	install_owned 0755 "$HERE/files/aspeed-bmc-kcs-args" /usr/local/sbin/aspeed-bmc-kcs-args
	install_owned 0644 "$HERE/files/$PKG-kcs.conf" "/etc/modprobe.d/$PKG.conf"
	note "With --kcs-fix: ipmi_si uses BAR1 + 0xe88 ($(/usr/local/sbin/aspeed-bmc-kcs-args))"
else
	install_owned 0644 "$HERE/files/$PKG.conf" "/etc/modprobe.d/$PKG.conf"
	owned /usr/local/sbin/aspeed-bmc-kcs-args && rm -f /usr/local/sbin/aspeed-bmc-kcs-args
fi
state_set kcs_fix "$kcs_fix"

install_owned 0755 "$HERE/files/aspeed-sol-status" /usr/local/sbin/aspeed-sol-status
# The uninstaller needs nothing from this directory, so keep a copy where it
# can be found after the clone is gone.
install_owned 0755 "$HERE/uninstall.sh" /usr/local/sbin/aspeed-sol-uninstall

# --- load ----------------------------------------------------------------------

tty=
if [ -n "$dev" ] && [ "$sb_pending" = no ]; then
	bdf=${dev##*/}
	cur=$(basename "$(readlink -f "$dev/driver" 2>/dev/null)" 2>/dev/null || true)
	if [ "$cur" = "$MOD" ]; then
		note "$MOD is already bound to $bdf. The new build is used from the next boot."
	else
		if [ "$cur" = ipmi_si ]; then
			info "Unbinding ipmi_si from $bdf (it cannot use the device)"
			echo "$bdf" >/sys/bus/pci/drivers/ipmi_si/unbind
		fi
		info "Loading $MOD"
		modprobe "$MOD" || warn "modprobe $MOD failed; see dmesg."
	fi
	mapfile -t ttys < <(find_ttys "$dev")
	if [ -n "$tty_opt" ]; then
		[[ " ${ttys[*]} " == *" $tty_opt "* ]] ||
			die "$tty_opt is not a port of the BMC device (its ports: ${ttys[*]:-none})."
		tty=$tty_opt
	elif [ ${#ttys[@]} -eq 1 ]; then
		tty=${ttys[0]}
	elif [ ${#ttys[@]} -gt 1 ]; then
		info "The BMC exposes ${#ttys[@]} serial ports; only one of them carries SOL:"
		for t in "${ttys[@]}"; do
			note "/dev/$t at $(cat "/sys/class/tty/$t/iomem_base" 2>/dev/null)"
		done
		note "Usually it is the first. To check, run 'cat /dev/ttySN' on one, type"
		note "in a SOL session, and see where it arrives."
		if [ "$assume_yes" = no ] && [ -t 0 ]; then
			read -r -p "Which one carries SOL? [${ttys[0]}] " tty
			tty=${tty:-${ttys[0]}}
			[[ " ${ttys[*]} " == *" $tty "* ]] || die "$tty is not one of: ${ttys[*]}"
		else
			warn "Not choosing one without asking: rerun with --tty to set up the console."
			[ "$console" = yes ] && die "--console needs --tty here."
		fi
	fi
	if [ -n "$tty" ]; then
		note "The BMC serial port for SOL is /dev/$tty"
	elif [ ${#ttys[@]} -eq 0 ]; then
		warn "No serial port appeared. Is SOL (or the VUART) enabled in the BMC? See dmesg."
	fi
fi

# --- BMC SOL settings ----------------------------------------------------------

# Read "<name> : <value>" from `ipmitool sol info`.
sol_get() {
	sed -n "s/^$1 *: *//p" <<<"$sol_info" | head -1
}

sol_info=
if [ "$sol_tune" != no ] || [ -z "$baud" ]; then
	if ! command -v ipmitool >/dev/null && [ "$install_deps" = yes ] &&
	   { [ "$sol_tune" = yes ] || [ -t 0 ]; }; then
		info "Installing ipmitool (to read the BMC's SOL settings)"
		DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ipmitool ||
			warn "Could not install ipmitool."
	fi
	if command -v ipmitool >/dev/null; then
		modprobe ipmi_devintf 2>/dev/null || true
		modprobe ipmi_si 2>/dev/null || true
		# SOL lives on a LAN channel; over KCS the default channel has none.
		for c in 1 2 3 4 5 6 7 8 9 10 11; do
			ipmitool channel info "$c" 2>/dev/null | grep -q "Medium Type *: 802.3 LAN" ||
				continue
			sol_info=$(timeout 20 ipmitool sol info "$c" 2>/dev/null) && break
			sol_info=
		done
	fi
fi

if [ -z "$baud" ]; then
	rate=$(sol_get "Non-Volatile Bit Rate (kbps)")
	case "$rate" in
	9.6) baud=9600 ;; 19.2) baud=19200 ;; 38.4) baud=38400 ;;
	57.6) baud=57600 ;; 115.2) baud=115200 ;;
	*) baud=115200 ;;
	esac
fi

if [ "$sol_tune" != no ]; then
	if [ -z "$sol_info" ]; then
		[ "$sol_tune" = yes ] &&
			warn "Cannot read the BMC's SOL settings over KCS (no /dev/ipmi0?); not tuning them."
	else
		acc=$(sol_get "Character Accumulate Level (ms)")
		thr=$(sol_get "Character Send Threshold")
		chan=$c
		if [ "$acc" = 25 ] && [ "$thr" = 255 ]; then
			info "BMC SOL settings are already 25 ms / 255 characters"
		else
			info "BMC SOL settings: accumulate ${acc:-?} ms, send threshold ${thr:-?} characters"
			note "The BMC sends a SOL packet when a character has waited for the"
			note "accumulate interval, or when the threshold is reached. Too small, and"
			note "it sends a packet per character, which makes output slow; too large,"
			note "and typing lags. 25 ms / 255 characters fills packets while output"
			note "streams and delays a keystroke by at most 25 ms."
			if [ "$sol_tune" = yes ] || ask "Set them to 25 ms / 255 characters?"; then
				# The accumulate level is in units of 5 ms.
				if ipmitool sol set character-accumulate-level 5 "$chan" &&
				   ipmitool sol set character-send-threshold 255 "$chan"; then
					note "Set. Reconnect any open SOL session to use them."
				else
					warn "ipmitool could not change them; set them in the BMC's web interface."
				fi
			fi
		fi
	fi
fi

# --- console -------------------------------------------------------------------

if [ "$console" = ask ]; then
	if [ -z "$tty" ]; then
		console=no
	else
		note "Setting up the console puts the kernel messages and a login prompt on"
		note "/dev/$tty, i.e. on SOL. If the root file system is encrypted, the"
		note "passphrase prompt may then show only on SOL (see the README)."
		if ask_default_yes "Make /dev/$tty the kernel console with a login prompt?"; then
			console=yes
		else
			console=no
		fi
	fi
fi

if [ "$console" = yes ]; then
	[ -n "$tty" ] || die "--console needs the serial port to be present (it was not found)."
	opt="console=$tty,$baud"

	info "Loading $MOD from the initramfs, so that boot messages reach SOL"
	if ! grep -q "^$MOD\$" /etc/initramfs-tools/modules; then
		printf '%s\n%s\n' "$MARK" "$MOD" >>/etc/initramfs-tools/modules
		state_set initramfs yes
	fi

	# On proxmox-boot-tool hosts the ESPs can be set up for systemd-boot
	# ("uefi"), which reads /etc/kernel/cmdline, for GRUB, which reads
	# /etc/default/grub, or for both (after switching to Secure Boot).
	# Configure each one that is set up.
	pbt=
	if [ -s /etc/kernel/proxmox-boot-uuids ]; then
		pbt=$(proxmox-boot-tool status 2>/dev/null || true)
	fi
	done_any=no

	if [ -e /etc/kernel/cmdline ] && grep -q "configured with: uefi" <<<"$pbt"; then
		info "Adding $opt to /etc/kernel/cmdline (systemd-boot)"
		# Take out what an earlier run added (another port or speed), then
		# add the current options.
		prev=$(state_get cmdline_proxmox)
		if [ -n "$prev" ]; then
			sed -i "1s| $prev\$||; 1s| $prev | |" /etc/kernel/cmdline
			state_set cmdline_proxmox ""
		fi
		if grep -qE "(^| )console=${tty}(,| |\$)" /etc/kernel/cmdline; then
			note "It already has a console=$tty option of its own; leaving that as it is."
		else
			mkdir -p "$STATE_DIR"
			[ -e "$STATE_DIR/cmdline.orig" ] || cp /etc/kernel/cmdline "$STATE_DIR/cmdline.orig"
			add=$opt
			grep -qE "(^| )console=tty0( |\$)" /etc/kernel/cmdline || add="console=tty0 $opt"
			sed -i "1s|\$| $add|" /etc/kernel/cmdline
			state_set cmdline_proxmox "$add"
		fi
		done_any=yes
	fi

	if command -v update-grub >/dev/null &&
	   { [ -z "$pbt" ] || grep -q "grub (versions" <<<"$pbt"; }; then
		info "Adding $opt to the GRUB command line (/etc/default/grub.d/90-$PKG.cfg)"
		frag=/etc/default/grub.d/90-$PKG.cfg
		owned "$frag" || die "$frag exists and was not written by this package; move it away and rerun."
		mkdir -p /etc/default/grub.d
		cat >"$frag.tmp" <<EOF
$MARK
# The last console= is /dev/console. tty0 keeps the local screen working.
GRUB_CMDLINE_LINUX="\$GRUB_CMDLINE_LINUX console=tty0 $opt"
EOF
		mv "$frag.tmp" "$frag"
		state_set grub yes
		done_any=yes
	fi

	[ "$done_any" = yes ] ||
		warn "Unknown boot loader: add 'console=tty0 $opt' to the kernel command line yourself."

	# On proxmox-boot-tool hosts this also runs proxmox-boot-tool refresh,
	# which regenerates the GRUB configuration and the systemd-boot entries.
	update-initramfs -u -k all
	if [ -z "$pbt" ] && [ -e "/etc/default/grub.d/90-$PKG.cfg" ]; then
		update-grub
	fi

	prev=$(state_get getty)
	if [ -n "$prev" ] && [ "$prev" != "$tty" ]; then
		info "Disabling the login prompt on $prev, which an earlier run set up"
		# Not --now: the next boot ends it, and stopping it could leave a
		# console port without a user.
		systemctl disable "serial-getty@$prev.service" || true
	fi
	info "Enabling a login prompt on $tty (serial-getty@$tty)"
	systemctl enable --now "serial-getty@$tty.service"
	state_set getty "$tty"
else
	note "Console not set up. Rerun without --no-console, once the serial port"
	note "is present, to put the kernel console and a login prompt on it."
fi

state_set version "$VER"

# --- done ----------------------------------------------------------------------

echo
info "Done."
if [ "$sb_pending" = yes ]; then
	note "Reboot, and enroll the key in the MOK management screen (BMC remote KVM)."
	note "Then check with: aspeed-sol-status"
else
	note "Check with: aspeed-sol-status"
	[ "$console" = yes ] && note "Reboot to see boot messages on SOL."
	note "Uninstall with: aspeed-sol-uninstall"
fi
note "New kernels are built automatically as long as their headers are installed."
