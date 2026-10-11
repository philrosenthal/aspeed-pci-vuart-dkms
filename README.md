# IPMI Serial over LAN for ASPEED BMCs behind PCIe (DKMS driver)

On some boards with an ASPEED AST2600 BMC, IPMI Serial over LAN (SOL) shows
the BIOS and the boot loader, then goes silent as soon as Linux starts. This
package adds the missing Linux driver, `8250_aspeed_pci`, built with DKMS,
plus an installer that sets up the console on it.

It is a stopgap. The driver has been proposed for the mainline kernel (see
[Upstream status](#upstream-status)), and DKMS stops building it for kernels
that include it.

> This is an unofficial project, not affiliated with ASPEED, ASUS or any
> other vendor.

## Does this apply to my machine?

Yes, if all of these are true:

- SOL works in the BIOS but not once Linux is running.
- `lspci -nn` shows the BMC's PCIe function, typically as:

  ```
  09:01.0 IPMI Interface [0c07]: ASPEED Technology, Inc. Device [1a03:2402] (rev 01) (prog-if 01 [KCS])
  ```

  The bus number varies. The class must be `0c07` (IPMI) with prog-if 01
  (KCS), which is what the vendor BMC firmware sets.
- There is no extra serial port in `dmesg | grep ttyS` that SOL works on.

Known to need it: **ASUS Pro WS W680-ACE IPMI** (ASMB10-iKVM, BMC firmware
1.3.13, which `ipmitool mc info` shows as 1.03). Other boards with the same
BMC setup probably do too; please open an issue with the
`lspci -vnn -d 1a03:2402` output either way.

Boards where the BMC's serial port appears as an ordinary COM port (for
example Supermicro boards, where SOL is COM2 at I/O 0x2f8) do not need this:
the standard 8250 driver already handles them.

### Why it happens

The BMC presents one PCIe function, 1a03:2402. Its second memory BAR
contains both the BMC's KCS interface, which `ipmitool` uses, and up to two
16550-compatible serial ports, one of which the BMC bridges to SOL. There is
no separate device for the serial ports, so no serial driver ever binds them.
On top of that, the kernel's IPMI driver (`ipmi_si`) binds the function
because of its IPMI class code, although it cannot use it. Every device has a
driver, and yet nothing drives the serial port. More detail in
[docs/how-it-works.md](docs/how-it-works.md).

## Supported systems

| System | Kernel | Status |
|---|---|---|
| Proxmox VE 9 | 6.14, 6.17, 7.0 | Driver tested on hardware (7.0) |
| Debian 13 (trixie) | 6.12 | Installer tested in a VM |
| Ubuntu 26.04 LTS | 7.0 | Installer tested in a VM |
| Ubuntu 24.04 LTS | 6.8, 6.17 (HWE) | Installer tested in a VM (6.8) |

The driver needs kernel 6.8 or newer and DKMS 3.x, which all of the above
ship. It also builds against the mainline 6.17 and 6.19 kernels. "Tested in
a VM" means the installer builds, signs and loads the module there with the
distribution's own kernel, but without the BMC hardware; reports from real
machines are welcome.

## BIOS settings

SOL only shows the BIOS screens and the boot loader if the BIOS sends its
console to the BMC's serial port. On the ASUS W680-ACE (AMI Aptio setup),
these are in **Advanced → Console Redirection Settings**:

**AMT SOL/COM1(Pci Bus0,Dev22,Func3,Port0)**

| Setting | Value | Why |
|---|---|---|
| Console Redirection | Off | This is the Intel ME's (AMT) serial port, not the BMC's |

**IPMI Card SOL/COM2(Pci Bus9,Dev1,Func0,Port0)**

| Setting | Value | Why |
|---|---|---|
| Console Redirection | On | The BMC's serial port, the one SOL carries |

**Console Redirection Settings** (of the IPMI Card SOL/COM2 port)

| Setting | Value | Why |
|---|---|---|
| Terminal Type | VT-UTF8 | Box-drawing and other characters show correctly in `ipmitool` and modern terminals |
| Bits per second | 115200 | Must match the BMC's SOL bit rate and the Linux `console=` speed |
| Data Bits / Parity / Stop Bits | 8 / None / 1 | The usual 8N1 |
| Flow Control | None | Not needed over SOL |
| VT-UTF8 Combo Key Support | On | Accepts combination keys (Ctrl, Alt) from ANSI and VT100 terminals |
| Resolution 100x31 | On (optional) | A larger BIOS screen; Off gives 80x24 |
| Putty KeyPad | LINUX (optional) | Function and keypad keys as a Linux terminal sends them |

**Legacy Console Redirection Settings**

| Setting | Value | Why |
|---|---|---|
| Redirection COM Port | IPMI Card SOL/COM2(Pci Bus9,Dev1,Func0,Port0) | Sends legacy (text-mode) output, such as option ROMs, there too |
| Resolution | 80x24 | |
| Redirect After POST | Always Enable | Keeps the boot loader visible after the BIOS hands over |

The bus number in the port name follows the PCIe layout, so it may differ.
The BIOS stops driving the port once Linux starts, which is where this
driver takes over. Other boards have similar settings under similar names.

## Install

```
git clone https://github.com/philrosenthal/aspeed-pci-vuart-dkms.git
cd aspeed-pci-vuart-dkms
sudo ./install.sh
sudo reboot
```

After the reboot, check the result:

```
sudo aspeed-sol-status
```

By default the installer also makes the SOL port the kernel console, with a
login prompt (step 7 below); it asks first when run interactively. Use
`--no-console` to install only the driver, for example if you unlock an
encrypted root file system at the local keyboard (see below).

### What the installer does

1. Installs `dkms` and the kernel headers, including the headers
   metapackage, so that future kernels get the module built automatically.
2. Builds and installs the module with DKMS for every kernel that has headers.
3. If Secure Boot is on and the DKMS signing key is not enrolled, offers to
   queue it for enrollment (see [Secure Boot](#secure-boot)).
4. Adds `options ipmi_si trypci=0` in `/etc/modprobe.d/aspeed-pci-8250.conf`,
   so that `ipmi_si` no longer binds the PCIe function. `ipmi_si` still finds
   the KCS interface through ACPI, so `ipmitool` keeps working.
5. Loads the driver (unbinding `ipmi_si` from the function first, if needed)
   and reports which `ttyS` port the SOL serial port became.
6. Offers to tune the BMC's SOL settings (see
   [BMC SOL settings](#bmc-sol-settings)).
7. Unless `--no-console` is given:
   - adds the module to `/etc/initramfs-tools/modules`, so that it loads
     early enough for boot messages;
   - adds `console=tty0 console=ttyS<N>,<baud>` to the kernel command line:
     in `/etc/kernel/cmdline` for systemd-boot on Proxmox (ZFS-on-root
     installs), in `/etc/default/grub.d/90-aspeed-pci-8250.cfg` for GRUB,
     or both where `proxmox-boot-tool` has set up both;
   - enables `serial-getty@ttyS<N>` for a login prompt.

   The speed defaults to the BMC's SOL bit rate (normally 115200). The last
   `console=` on the command line is the one that gets `/dev/console`; if
   you already have other `console=` options (in `GRUB_CMDLINE_LINUX_DEFAULT`,
   say), check the order with `cat /proc/cmdline` after the reboot. Remove
   `quiet` from the command line too if you want to see all boot messages.

   **Encrypted root file system:** the last `console=` also receives prompts
   that only go to `/dev/console`, which can include the passphrase prompt
   for LUKS or ZFS native encryption. If you type that passphrase at the
   local keyboard, check after installing that the prompt still shows on the
   screen, or install with `--no-console`.

It also installs two commands in `/usr/local/sbin`: `aspeed-sol-status`, a
read-only check of all of the above, and `aspeed-sol-uninstall`.

### Options

| Option | Effect |
|---|---|
| `--no-console` | Install only the driver: no console, initramfs or getty changes |
| `--console` | Set up the console without asking (the default otherwise asks first when interactive) |
| `--baud RATE` | Console speed (9600 to 115200), if it should differ from the BMC's SOL bit rate |
| `--tty ttySN` | The port that carries SOL, when the BMC exposes two serial ports (asked interactively; without it, the console is not set up) |
| `--sol-tune` / `--no-sol-tune` | Set the BMC's SOL settings to 25 ms / 255 characters without asking, or leave them alone |
| `--kcs-fix` | Point `ipmi_si` at the KCS registers directly instead of the ACPI address (see [KCS and the BIOS](#kcs-ipmitool-and-the-bios)) |
| `--no-deps` | Do not install packages with apt |
| `-y`, `--yes` | Answer yes to every question |

Rerunning the installer upgrades the package in place, and replaces the
console settings of an earlier run (for example, after the port number or
the speed changed). The installer never replaces or removes configuration
files it did not write itself.

## Using SOL

From another machine with `ipmitool` installed, either type the BMC password
when asked:

```
ipmitool -I lanplus -H <bmc-address> -U <user> sol activate
```

or keep it in a file that only you can read, which suits scripts:

```
bash -c 'umask 077; read -rsp "BMC password: " pw; echo; printf "%s\n" "$pw" > ~/.bmc-pass'
ipmitool -I lanplus -H <bmc-address> -U <user> -f ~/.bmc-pass sol activate
```

(`-E` reads it from the `IPMI_PASSWORD` environment variable instead. Avoid
`-P <password>`: it shows up in the process list and the shell history.)

Useful while connected:

- `~.` ends the session (`~~.` when you are connected to that machine over
  SSH, since SSH uses `~.` itself).
- `~?` lists the other escapes.

If the BMC says the SOL payload is already active (a session left open
elsewhere), end it first:

```
ipmitool -I lanplus -H <bmc-address> -U <user> sol deactivate
```

## Security

With the console set up, SOL is a login to the machine like the local
console: anyone who can open a SOL session on the BMC gets a login prompt,
and sees the kernel and boot messages, including anything sensitive that
ends up there. So:

- Use strong, unique BMC passwords, and change the factory ones.
- Keep the BMC on a management network that only trusted machines can reach;
  do not expose it to the internet.
- Log out of SOL sessions when done (`exit`, then `~.`): the shell stays
  logged in when only the SOL session is closed.
- Current Debian-based systems, Proxmox included, usually let root log in
  on serial ports. If you do not want that, log in with a regular account
  and sudo, and restrict root logins on `ttyS*` (for example with
  `pam_access` or `pam_securetty`).

## BMC SOL settings

The BMC collects characters from the serial port and sends them in a packet
when one of them has waited for the *character accumulate interval*, or when
the *character send threshold* is reached. Both settings trade
responsiveness against efficiency, and the factory values are not
necessarily good ones:

- **Too small** (e.g. 5 ms / 1 character): the BMC sends a packet for about
  every character, and the console crawls when there is a lot of output.
- **Too large** (a long interval, or a threshold the output rarely reaches):
  typing feels laggy, because each keystroke's echo waits out the interval.

25 ms / 255 characters is a good middle: while output streams, the
threshold fills each packet, and a keystroke waits at most 25 ms. The
installer reads the current values over KCS and offers to change them. To do
it yourself, from the host:

```
ipmitool sol info 1                                  # see the current values
ipmitool sol set character-accumulate-level 5 1      # in 5 ms units: 5 = 25 ms
ipmitool sol set character-send-threshold 255 1
```

The trailing `1` is the LAN channel, which is 1 on most BMCs. Add
`-I lanplus -H <bmc-address> -U <user>` (and `-f <password-file>`, see
[Using SOL](#using-sol)) to run the same commands from another machine. Reconnect open SOL sessions afterwards.

## Interrupts and polling

The driver looks for the serial port's interrupt (an MSI vector) when it
loads. Which vector the port uses depends on the BMC firmware, and the host
cannot read it, so the driver makes the port raise an interrupt and watches
which vector fires. If none does, the port is polled instead. Both work; with
the interrupt, the console is about seven times faster (around 15 KB/s
instead of 2 KB/s) and an idle port costs nothing. `aspeed-sol-status` shows
which mode is in use.

## Secure Boot

DKMS signs the module with its own key: `/var/lib/dkms/mok.pub` on Debian
and Proxmox, `/var/lib/shim-signed/mok/MOK.der` on Ubuntu. If other DKMS
modules already work on the machine with Secure Boot on, that key is enrolled
and there is nothing to do.

If this is the first DKMS module, the key has to be enrolled once, or the
firmware rejects the module (`Key was rejected by service` in `dmesg`, and a
silent SOL). The installer offers to do this. By hand:

```
sudo mokutil --import /var/lib/dkms/mok.pub    # Ubuntu: /var/lib/shim-signed/mok/MOK.der
sudo reboot                                    # mokutil asks for a one-time password first
```

On the next boot, a blue *MOK management* screen appears. Choose *Enroll
MOK*, *Continue*, *Yes*, and type the password. Use the BMC's remote KVM
(the web interface's console) for this: SOL does not work yet at that point.
If nobody answers the screen, it times out and boots without enrolling, and
the import has to be repeated.

## KCS (ipmitool) and the BIOS

`ipmitool` on the host uses the KCS interface through `ipmi_si`, which finds
it through ACPI. On the ASUS W680-ACE, the ACPI tables give the right address
only when the BIOS setting **IPMI → OS type** (or similar) is set to
**Linux**. With the default, *Windows*, the BIOS describes the KCS interface
in a way that clashes with a PCIe bridge window, Linux moves the BAR, and the
address in ACPI goes stale: `ipmi_si` loads but `/dev/ipmi0` never appears.
BIOS updates reset the setting to *Windows*.

Set it to *Linux* if you can. If you cannot, `./install.sh --kcs-fix` makes
`ipmi_si` use the current address of the KCS registers (BAR1 + 0xe88, where
the ASUS firmware puts them) instead of the ACPI one. SOL itself does not
depend on this setting.

## Troubleshooting

Start with `sudo aspeed-sol-status`. Common cases:

- **SOL silent after a kernel update.** The module was not built for the new
  kernel, usually because its headers are missing. Install them (the
  installer adds the headers metapackage so that this happens automatically)
  and run `sudo dkms autoinstall`.
- **"Bound to ipmi_si".** `/etc/modprobe.d/aspeed-pci-8250.conf` is missing,
  or `ipmi_si` is built into the kernel (then add `ipmi_si.trypci=0` to the
  kernel command line).
- **No serial port appears.** The BMC has SOL or its serial port disabled; the
  driver only registers ports the BMC has enabled.
- **Boot messages show, but there is no login prompt.** Check
  `systemctl status serial-getty@ttyS<N>`.
- **The port number changed.** It depends on the other serial ports in the
  machine. Rerun `./install.sh`.
- **Do not unload the module** (`rmmod`, unbinding) while its port is the
  kernel console and no program has it open: current kernels can crash.
  Reboot instead, or keep the login prompt running while reloading.

## Uninstall

```
sudo aspeed-sol-uninstall
sudo reboot
```

The installer puts the uninstaller in `/usr/local/sbin`, so the cloned
directory is not needed for this (`sudo ./uninstall.sh` in it does the same).

This removes the DKMS package and everything the installer configured. It
does not change the BMC's SOL settings back.

## When your kernel gets its own driver

Once a driver for this device is in the kernel, this package is no longer
needed:

- If it is this driver (`CONFIG_SERIAL_8250_ASPEED_PCI`), DKMS stops building
  the package for kernels that have it, and the console setup keeps working
  with the in-tree module, which has the same name.
- `aspeed-sol-status` says when the running kernel has a driver of its own
  for the device, under whatever name.
- A weekly CI run builds the package against the supported distributions'
  kernels, mainline, linux-next and each new release, and flags a kernel
  that has a driver for the device.

Then remove the DKMS package but keep the console setup:

```
sudo aspeed-sol-uninstall --keep-console
```

If the in-tree driver has a different name, also replace `8250_aspeed_pci`
with that name in `/etc/initramfs-tools/modules` and run
`sudo update-initramfs -u -k all`. `--keep-console` asks before removing the
package from a kernel that has no driver of its own, since SOL would then go
quiet at the next boot.

## Upstream status

- v1 (a quirk in `8250_pci.c`):
  <https://lore.kernel.org/r/20261008-aspeed-vuart-v1-1-d2be17c99cd7@phil.gs>.
  The 8250 maintainers asked for a separate driver instead, which is what this
  package contains. A v2 is pending the maintainers' choice between a separate
  8250 driver and extending the driver below.
- Grégoire Layet's series for the same device, for BMCs running a modified
  OpenBMC:
  <https://lore.kernel.org/r/20260818-aspeed-driver-v6-v6-0-fd7cc0b338ea@9elements.com>.

The driver source in `dkms/8250_aspeed_pci.c` is kept identical to the
version proposed upstream; `dkms/8250_pcilib.h` holds what is needed to build
it out of tree and on older kernels.

## See also

- Discussion of the same problem on Reddit:
  <https://www.reddit.com/r/HomeServer/comments/1hbrop8/asus_w680_ace_ipmi_serial_console_setup/>

## License

GPL-2.0, like the Linux kernel. See [LICENSE](LICENSE).
