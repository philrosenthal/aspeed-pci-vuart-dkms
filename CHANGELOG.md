# Changelog

## 2.1 (2026-10-10)

First public release.

- Driver: the version of `8250_aspeed_pci` proposed upstream as v2,
  including the optional MSI patch (finds the serial port's MSI vector at
  probe, polls if there is none).
- Builds on kernels 6.8 and newer: `dkms/8250_pcilib.h` supplies what older
  kernels lack (the 6.19 form of `serial8250_pci_setup_port()`, string
  symbol namespaces from 6.13, `PCI_VENDOR_ID_ASPEED` from 7.0).
- DKMS stops building the module for kernels that have
  `CONFIG_SERIAL_8250_ASPEED_PCI`, i.e. the driver in-tree.
- `install.sh`: DKMS install for all kernels with headers, headers
  metapackage, Secure Boot key check and enrollment, `ipmi_si trypci=0`,
  optional console setup (initramfs, kernel command line for
  proxmox-boot-tool or GRUB, getty), optional BMC SOL tuning to
  25 ms / 255 characters, optional `--kcs-fix`.
- Console setup is the default (`--no-console` to opt out); on Proxmox it
  handles systemd-boot, GRUB, or both.
- Reruns replace the console settings of an earlier run; `--tty` picks the
  SOL port when the BMC exposes two; `--baud` is validated; configuration
  files the package did not write are never replaced or removed; install
  and uninstall runs are serialized with a lock.
- `uninstall.sh` (with `--keep-console` to hand over to an in-tree driver)
  and `aspeed-sol-status`, which also reports when the running kernel has
  its own driver for the device.
