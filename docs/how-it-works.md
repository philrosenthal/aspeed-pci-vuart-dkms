# How it works

## The device

ASPEED's AST2600 BMC can present a PCIe "BMC device" function to the host,
1a03:2402. With the vendor BMC firmware (for example ASUS's) it looks like
this:

```
09:01.0 IPMI Interface [0c07]: ASPEED Technology, Inc. Device [1a03:2402] (rev 01) (prog-if 01 [KCS])
        Memory at 84000000 (32-bit, non-prefetchable) [size=1M]
        Memory at 84100000 (32-bit, non-prefetchable) [size=256K]
        Capabilities: [50] MSI: Enable+ Count=32/32 Maskable- 64bit+
```

- **BAR0** (1 MiB) is a memory window into the BMC. Nothing in it is used
  with the stock firmware.
- **BAR1** (256 KiB) mirrors the BMC's LPC I/O space: an LPC I/O address
  `A` appears at `BAR1 + (A << 2)`, one 32-bit register per byte-wide
  register. In it:
  - the KCS interface at `0xe88`/`0xe8c` (I/O `0x3a2`/`0x3a3`), which the
    BIOS describes in ACPI and `ipmi_si` uses;
  - up to two 16550-compatible virtual UARTs (VUARTs) at `0xfe0`
    (I/O `0x3f8`) and `0xbe0` (I/O `0x2f8`). The BMC bridges one of them to
    IPMI Serial over LAN. A VUART the BMC has not enabled reads all ones.
- **Interrupts:** no INTx pin. 32 MSI vectors; which one a VUART raises
  depends on how the BMC firmware set it up (vector 20 on the W680-ACE).

## Why nothing drives the serial port

- `8250_pci` has no entry for 1a03:2402, and the upstream maintainers do not
  want new quirks there, hence a separate driver.
- `ipmi_si` binds the function through its PCI driver, which matches the IPMI
  KCS class code. It then looks for the KCS registers at the start of BAR0,
  finds nothing, and stays bound anyway. While it is bound, no other driver
  can bind the function. (The proposed upstream series also stops `ipmi_si`
  from doing that; this package uses `ipmi_si trypci=0` instead.)
- `ipmi_si` separately finds the KCS interface through ACPI, which is why
  `ipmitool` works with or without this package.

## The driver

`8250_aspeed_pci` maps the first 4 KiB of BAR1, registers each VUART that
does not read all ones as an 8250 port (`PORT_ASPEED_VUART`, 32-bit
registers, register shift 2), and leaves KCS alone. It does not request the
BAR, since `ipmi_si` uses part of it.

To find each VUART's MSI vector, it allocates all 32 vectors and puts a
test handler on vectors 1-31. Then, for each VUART, it watches four 10 ms
windows: one with the UART's interrupts off, two with the
transmitter-empty interrupt on (which fires right away on an idle UART),
and another with interrupts off. A vector that fires in both "on" windows
and in neither "off" window is the VUART's. If none qualifies, or MSI is not
available, the ports are polled. This takes about 50 ms per VUART at probe.

Vector 0 is never used. With multiple MSI vectors, the kernel writes the
function's MSI address when vector 0 is activated and clears it when
vector 0 is shut down, which would cut off every vector.

## Other firmware

BMCs running OpenBMC with Grégoire Layet's patches present the function with
class `0xff0000` and fixed MSI vectors 16 and 17, for the host driver in his
series. This driver matches only class `0x0c0701`, so the two do not
overlap. It also declines the AST2700 (revision `0x27`), whose layout is not
known to be the same.
