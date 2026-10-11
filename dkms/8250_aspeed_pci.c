// SPDX-License-Identifier: GPL-2.0
/*
 * Driver for the VUARTs of ASPEED BMCs, as seen by the host over PCIe
 *
 * The PCIe "BMC device" function of ASPEED BMCs such as the AST2600
 * (1a03:2402) can expose up to two 16550-compatible virtual UARTs to the
 * host. Their registers are in BAR1 at the VUART's LPC I/O address shifted
 * left by two, one 32-bit register per 4 bytes. The same BAR also holds the
 * BMC's KCS interface, so the BAR is mapped but not requested: the 8250 core
 * requests the registers of each VUART when it registers the port, and an
 * ipmi_si interface described by firmware (ACPI or SMBIOS) requests the KCS
 * registers.
 */

#include <linux/array_size.h>
#include <linux/atomic.h>
#include <linux/bitops.h>
#include <linux/delay.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/ioport.h>
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/pm.h>
#include <linux/serial_8250.h>
#include <linux/serial_reg.h>
#include <linux/sizes.h>
#include <linux/slab.h>
#include <linux/types.h>

#include "8250_pcilib.h"

#define PCI_DEVICE_ID_ASPEED_BMC_DEV	0x2402
#define ASPEED_PCI_REV_AST2700		0x27

#define ASPEED_VUART_BAR	1
#define ASPEED_VUART_REGSHIFT	2
/* What the 8250 core requests for a port: 8 registers */
#define ASPEED_VUART_SIZE	(8 << ASPEED_VUART_REGSHIFT)

#define ASPEED_MSI_VECTORS	32
#define ASPEED_MSI_WINDOW_MS	10

static const u16 aspeed_vuart_io[] = { 0x3f8, 0x2f8 };

struct aspeed_pci8250_irq_test {
	unsigned long fired;	/* bit n: vector n fired */
	struct aspeed_pci8250_vector {
		struct aspeed_pci8250_irq_test *test;
		unsigned int nr;
		int irq;
	} vec[ASPEED_MSI_VECTORS];
};

struct aspeed_pci8250 {
	unsigned int nr;
	int line[ARRAY_SIZE(aspeed_vuart_io)];
};

static void __iomem *aspeed_vuart_reg(void __iomem *port, unsigned int reg)
{
	return port + (reg << ASPEED_VUART_REGSHIFT);
}

/*
 * A VUART that the BMC firmware has not enabled reads back as all ones.
 * Reading MCR has no side effects, and its bits 6-7 are reserved as zero on
 * a 16550, so a VUART that is present never reads it as all ones.
 */
static bool aspeed_vuart_present(void __iomem *port)
{
	return readl(aspeed_vuart_reg(port, UART_MCR)) != ~0U;
}

/*
 * Hold the registers of a VUART while probing it, so that a VUART that
 * another driver already owns (a UART also described by firmware, say) is
 * left alone. They are released before the port is registered, as the 8250
 * core then requests them itself.
 */
static bool aspeed_vuart_hold(struct pci_dev *pdev, unsigned int offset)
{
	resource_size_t start = pci_resource_start(pdev, ASPEED_VUART_BAR);

	if (request_mem_region(start + offset, ASPEED_VUART_SIZE,
			       pci_name(pdev)))
		return true;

	pci_info(pdev, "VUART at %#x is in use, skipping\n",
		 offset >> ASPEED_VUART_REGSHIFT);
	return false;
}

static void aspeed_vuart_release(struct pci_dev *pdev, unsigned int offset)
{
	release_mem_region(pci_resource_start(pdev, ASPEED_VUART_BAR) + offset,
			   ASPEED_VUART_SIZE);
}

static irqreturn_t aspeed_pci8250_test_irq(int irq, void *data)
{
	struct aspeed_pci8250_vector *vec = data;

	set_bit(vec->nr, &vec->test->fired);

	return IRQ_HANDLED;
}

/*
 * Return the vectors that fired during a window in which the THRE interrupt
 * of the VUART was enabled (@trigger), or all VUART interrupts were disabled.
 * The window has a fixed length, so that an unrelated interrupt cannot cut it
 * short before the VUART's interrupt is seen.
 */
static unsigned long aspeed_vuart_irqs_seen(void __iomem *port,
					    struct aspeed_pci8250_irq_test *test,
					    bool trigger)
{
	int v;

	xchg(&test->fired, 0);

	if (trigger)
		writel(UART_IER_THRI, aspeed_vuart_reg(port, UART_IER));
	msleep(ASPEED_MSI_WINDOW_MS);
	writel(0, aspeed_vuart_reg(port, UART_IER));

	/*
	 * The read flushes the IER write and, as a read completion cannot pass
	 * a posted write, any MSI that the function sent before it. Then wait
	 * for handlers that are running. This does not catch an MSI that has
	 * not reached a CPU yet, but THRE fires at the start of the window.
	 */
	readl(aspeed_vuart_reg(port, UART_IER));
	for (v = 1; v < ASPEED_MSI_VECTORS; v++)
		synchronize_irq(test->vec[v].irq);

	return xchg(&test->fired, 0);
}

/*
 * Enable the THRE interrupt, which fires right away while the transmitter is
 * idle, and see which vector arrives. A vector counts as the VUART's only if
 * it arrives both times the interrupt is enabled and in neither of the quiet
 * periods around that, so that other interrupts of the function are not
 * taken for it. Returns the vector, or 0 if there is no unique one.
 */
static unsigned int aspeed_vuart_find_vector(void __iomem *port,
					     struct aspeed_pci8250_irq_test *test)
{
	unsigned long noise, found;

	noise = aspeed_vuart_irqs_seen(port, test, false);
	found = aspeed_vuart_irqs_seen(port, test, true);
	found &= aspeed_vuart_irqs_seen(port, test, true);
	noise |= aspeed_vuart_irqs_seen(port, test, false);
	found &= ~noise;

	return hweight_long(found) == 1 ? __ffs(found) : 0;
}

/*
 * The function has no INTx pin. Its MSI vector for a VUART depends on how the
 * BMC firmware set the VUART up, which the host cannot read: the vector was
 * 20 for VUART 0x3f8 on an ASUS Pro WS W680-ACE IPMI, but 16 with other BMC
 * firmware. Find the vector of each VUART by triggering an interrupt, and
 * leave a VUART polled (irq 0) if that does not work.
 */
static void aspeed_pci8250_find_irqs(struct pci_dev *pdev, void __iomem *base,
				     const unsigned int *offsets,
				     unsigned int nr, int *irqs)
{
	u32 lcr[ARRAY_SIZE(aspeed_vuart_io)];
	struct aspeed_pci8250_irq_test *test;
	bool found = false;
	unsigned int i, vec;
	int v, ret;

	/*
	 * Quiet the VUARTs before MSI is enabled, so that none of them sends
	 * an interrupt before there is a handler for it, and so that only the
	 * VUART under test raises one. Their interrupts stay disabled
	 * afterwards; the 8250 core enables them when a port is opened.
	 */
	for (i = 0; i < nr; i++) {
		lcr[i] = readl(aspeed_vuart_reg(base + offsets[i], UART_LCR));
		writel(lcr[i] & ~UART_LCR_DLAB,
		       aspeed_vuart_reg(base + offsets[i], UART_LCR));
		writel(0, aspeed_vuart_reg(base + offsets[i], UART_IER));
		/* Flush the writes before MSI is enabled. */
		readl(aspeed_vuart_reg(base + offsets[i], UART_IER));
	}

	test = kzalloc(sizeof(*test), GFP_KERNEL);
	if (!test)
		goto restore_lcr;

	ret = pci_alloc_irq_vectors(pdev, ASPEED_MSI_VECTORS,
				    ASPEED_MSI_VECTORS, PCI_IRQ_MSI);
	if (ret < 0) {
		pci_info(pdev, "no MSI (%d), polling\n", ret);
		goto restore_lcr;
	}

	/* MSI is a memory write, so the function has to be a bus master. */
	pci_set_master(pdev);

	for (v = 0; v < ASPEED_MSI_VECTORS; v++) {
		test->vec[v].test = test;
		test->vec[v].nr = v;
		test->vec[v].irq = pci_irq_vector(pdev, v);
	}

	/*
	 * Leave vector 0 alone. With multiple MSI vectors, the MSI address and
	 * data of the function are written when the vectors are allocated and
	 * when vector 0 is activated, and cleared when vector 0 is shut down,
	 * which would cut off all vectors. For the same reason, no port uses
	 * vector 0.
	 */
	for (v = 1; v < ASPEED_MSI_VECTORS; v++) {
		ret = request_irq(test->vec[v].irq, aspeed_pci8250_test_irq, 0,
				  pci_name(pdev), &test->vec[v]);
		if (ret) {
			pci_info(pdev, "cannot request MSI vector %d (%d), polling\n",
				 v, ret);
			goto free_irqs;
		}
	}

	for (i = 0; i < nr; i++) {
		vec = aspeed_vuart_find_vector(base + offsets[i], test);
		if (!vec) {
			pci_info(pdev, "no MSI from VUART at %#x, polling all VUARTs\n",
				 offsets[i] >> ASPEED_VUART_REGSHIFT);
			break;
		}
		irqs[i] = test->vec[vec].irq;
	}

	/*
	 * Use MSI only if every VUART has a vector: the 8250 core enables the
	 * interrupts of a polled port too when it is opened, and they would go
	 * to a vector that nobody handles.
	 */
	found = i == nr;
	if (!found)
		memset(irqs, 0, nr * sizeof(*irqs));

free_irqs:
	while (--v > 0)
		free_irq(test->vec[v].irq, &test->vec[v]);

	if (!found) {
		pci_free_irq_vectors(pdev);
		pci_clear_master(pdev);
	}

restore_lcr:
	for (i = 0; i < nr; i++)
		writel(lcr[i], aspeed_vuart_reg(base + offsets[i], UART_LCR));
	kfree(test);
}

static int aspeed_pci8250_probe(struct pci_dev *pdev,
				const struct pci_device_id *id)
{
	struct device *dev = &pdev->dev;
	struct aspeed_pci8250 *priv;
	unsigned int offsets[ARRAY_SIZE(aspeed_vuart_io)];
	int irqs[ARRAY_SIZE(aspeed_vuart_io)] = { };
	struct uart_8250_port uart;
	unsigned int i, nr = 0;
	bool busy = false;
	void __iomem *base;
	int ret;

	/* The VUART layout is only known up to the AST2600. */
	if (pdev->revision >= ASPEED_PCI_REV_AST2700)
		return -ENODEV;

	if (!(pci_resource_flags(pdev, ASPEED_VUART_BAR) & IORESOURCE_MEM) ||
	    pci_resource_len(pdev, ASPEED_VUART_BAR) < SZ_4K)
		return -ENODEV;

	/*
	 * Not pcim_enable_device(): that would make the MSI vectors managed,
	 * and they have to be freed when the ports fall back to polling.
	 */
	ret = pci_enable_device(pdev);
	if (ret)
		return ret;

	base = pcim_iomap(pdev, ASPEED_VUART_BAR, SZ_4K);
	if (!base) {
		ret = -ENOMEM;
		goto err_disable;
	}

	priv = devm_kzalloc(dev, sizeof(*priv), GFP_KERNEL);
	if (!priv) {
		ret = -ENOMEM;
		goto err_disable;
	}

	for (i = 0; i < ARRAY_SIZE(aspeed_vuart_io); i++) {
		offsets[nr] = aspeed_vuart_io[i] << ASPEED_VUART_REGSHIFT;
		if (!aspeed_vuart_hold(pdev, offsets[nr])) {
			busy = true;
			continue;
		}
		if (aspeed_vuart_present(base + offsets[nr]))
			nr++;
		else
			aspeed_vuart_release(pdev, offsets[nr]);
	}

	/* Leave the function to other drivers if the BMC exposes no VUART. */
	if (!nr) {
		ret = -ENODEV;
		goto err_disable;
	}

	/*
	 * MSI is set up for the whole function. Leave it alone if a VUART
	 * belongs to another driver, as that VUART could then send interrupts
	 * that nobody handles.
	 */
	if (busy)
		pci_info(pdev, "a VUART is in use by another driver, polling\n");
	else
		aspeed_pci8250_find_irqs(pdev, base, offsets, nr, irqs);

	for (i = 0; i < nr; i++) {
		/* The 8250 core requests the registers itself. */
		aspeed_vuart_release(pdev, offsets[i]);

		memset(&uart, 0, sizeof(uart));
		uart.port.dev = dev;
		uart.port.irq = irqs[i];
		uart.port.uartclk = 115200 * 16;
		uart.port.type = PORT_ASPEED_VUART;
		uart.port.flags = UPF_SKIP_TEST | UPF_BOOT_AUTOCONF |
				  UPF_FIXED_PORT | UPF_FIXED_TYPE;

		ret = serial8250_pci_setup_port(pdev, &uart, ASPEED_VUART_BAR,
						offsets[i], ASPEED_VUART_REGSHIFT,
						base);
		if (ret)
			goto err_unregister;
		uart.port.iotype = UPIO_MEM32;

		ret = serial8250_register_8250_port(&uart);
		if (ret < 0) {
			dev_err(dev, "failed to register VUART at %#x: %d\n",
				offsets[i] >> ASPEED_VUART_REGSHIFT, ret);
			goto err_unregister;
		}
		priv->line[priv->nr++] = ret;
	}

	pci_set_drvdata(pdev, priv);
	return 0;

err_unregister:
	while (++i < nr)
		aspeed_vuart_release(pdev, offsets[i]);
	while (priv->nr)
		serial8250_unregister_port(priv->line[--priv->nr]);
	pci_free_irq_vectors(pdev);
err_disable:
	pci_disable_device(pdev);
	return ret;
}

static void aspeed_pci8250_remove(struct pci_dev *pdev)
{
	struct aspeed_pci8250 *priv = pci_get_drvdata(pdev);
	unsigned int i;

	for (i = 0; i < priv->nr; i++)
		serial8250_unregister_port(priv->line[i]);

	pci_free_irq_vectors(pdev);
	pci_disable_device(pdev);
}

static int aspeed_pci8250_suspend(struct device *dev)
{
	struct aspeed_pci8250 *priv = dev_get_drvdata(dev);
	unsigned int i;

	for (i = 0; i < priv->nr; i++)
		serial8250_suspend_port(priv->line[i]);

	return 0;
}

static int aspeed_pci8250_resume(struct device *dev)
{
	struct aspeed_pci8250 *priv = dev_get_drvdata(dev);
	unsigned int i;

	for (i = 0; i < priv->nr; i++)
		serial8250_resume_port(priv->line[i]);

	return 0;
}

static DEFINE_SIMPLE_DEV_PM_OPS(aspeed_pci8250_pm_ops, aspeed_pci8250_suspend,
				aspeed_pci8250_resume);

/*
 * Match only the KCS class code, which the stock BMC firmware of these boards
 * gives the function. BMC firmware that sets the function up for a different
 * host driver changes the class code.
 */
static const struct pci_device_id aspeed_pci8250_ids[] = {
	{ PCI_DEVICE(PCI_VENDOR_ID_ASPEED, PCI_DEVICE_ID_ASPEED_BMC_DEV),
	  .class = PCI_CLASS_SERIAL_IPMI_KCS, .class_mask = 0xffffff },
	{ }
};
MODULE_DEVICE_TABLE(pci, aspeed_pci8250_ids);

static struct pci_driver aspeed_pci8250_driver = {
	.name		= "8250_aspeed_pci",
	.id_table	= aspeed_pci8250_ids,
	.probe		= aspeed_pci8250_probe,
	.remove		= aspeed_pci8250_remove,
	.driver.pm	= pm_sleep_ptr(&aspeed_pci8250_pm_ops),
};
module_pci_driver(aspeed_pci8250_driver);

MODULE_IMPORT_NS("SERIAL_8250_PCI");
MODULE_DESCRIPTION("ASPEED BMC VUART over PCIe driver");
MODULE_LICENSE("GPL");
