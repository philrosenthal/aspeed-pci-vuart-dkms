/* SPDX-License-Identifier: GPL-2.0 */
#ifndef ASPEED_DKMS_8250_COMPAT_H
#define ASPEED_DKMS_8250_COMPAT_H

#include <linux/err.h>
#include <linux/serial_8250.h>

/*
 * Linux 7.4 replaces integer line numbers with port pointers in the 8250
 * registration, removal and PM interfaces. Infer the handle from the target
 * headers so that backported API changes work too. Both interfaces take the
 * registration result directly in unregister/suspend/resume.
 */
typedef typeof(serial8250_register_8250_port((const struct uart_8250_port *)0))
	aspeed_8250_handle;

static inline int aspeed_8250_line_error(int line)
{
	return line < 0 ? line : 0;
}

static inline int aspeed_8250_port_error(struct uart_8250_port *port)
{
	return IS_ERR(port) ? PTR_ERR(port) : 0;
}

static inline int aspeed_8250_register_port(const struct uart_8250_port *uart,
					   aspeed_8250_handle *handle)
{
	aspeed_8250_handle port = serial8250_register_8250_port(uart);
	int ret = _Generic(port,
		int: aspeed_8250_line_error,
		struct uart_8250_port *: aspeed_8250_port_error)(port);

	if (!ret)
		*handle = port;
	return ret;
}

#endif
