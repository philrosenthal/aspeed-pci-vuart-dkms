/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Out-of-tree stand-in for drivers/tty/serial/8250/8250_pcilib.h, which the
 * kernel headers packages do not ship. It also lets 8250_aspeed_pci.c, kept
 * identical to the version proposed upstream, build on older kernels.
 */
#ifndef ASPEED_DKMS_8250_PCILIB_H
#define ASPEED_DKMS_8250_PCILIB_H

#include <linux/module.h>
#include <linux/pci.h>
#include <linux/serial_8250.h>
#include <linux/types.h>
#include <linux/version.h>

/* Added to pci_ids.h in 7.0. */
#ifndef PCI_VENDOR_ID_ASPEED
#define PCI_VENDOR_ID_ASPEED		0x1a03
#endif

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 19, 0)

int serial8250_pci_setup_port(struct pci_dev *dev, struct uart_8250_port *port,
			      u8 bar, unsigned int offset, int regshift,
			      void __iomem *iomem);

#else

/*
 * Before 6.19 the kernel's helper takes no mapping and maps the whole BAR with
 * pcim_iomap() itself, which warns because the driver has already mapped it.
 * Set the port up here instead, as the 6.19 helper does for a memory BAR.
 */
static inline int aspeed_dkms_setup_port(struct pci_dev *dev,
					 struct uart_8250_port *port, u8 bar,
					 unsigned int offset, int regshift,
					 void __iomem *iomem)
{
	if (bar >= PCI_STD_NUM_BARS ||
	    !(pci_resource_flags(dev, bar) & IORESOURCE_MEM))
		return -EINVAL;

	port->port.iotype = UPIO_MEM;
	port->port.iobase = 0;
	port->port.mapbase = pci_resource_start(dev, bar) + offset;
	port->port.membase = iomem + offset;
	port->port.regshift = regshift;
	return 0;
}
#define serial8250_pci_setup_port aspeed_dkms_setup_port

/*
 * Nothing from the SERIAL_8250_PCI namespace is used then, and before 6.13
 * MODULE_IMPORT_NS() takes the namespace as a bare word, not a string.
 */
#undef MODULE_IMPORT_NS
#define MODULE_IMPORT_NS(ns)

#endif

#endif
