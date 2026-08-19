/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * DomZ - Zephyr running as an unprivileged Xen guest (DomU).
 *
 * Board-independent: the guest board is `xenvm`, so this same image is valid under
 * Xen on a Raspberry Pi 5 and on a Raspberry Pi 4.
 *
 * The domain is created by the xl toolstack (DomD in the Zephyr-Dom0 flavour,
 * Dom0 in the thin-Linux flavour) from /etc/xen/domz.cfg, which loads this
 * image from SD p1 as zephyr-domz.bin. It has no display, no block device and
 * no network: its console is the Xen PV console, reachable with
 * `xl console DomZ` from the toolstack domain.
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/util.h>
#include <version.h>

LOG_MODULE_REGISTER(domz, LOG_LEVEL_INF);

int main(void)
{
	LOG_INF("DomZ up: Zephyr " KERNEL_VERSION_STRING " as Xen DomU (AGL SoDeV)");
	LOG_INF("DomZ: board=%s soc=%s", CONFIG_BOARD, CONFIG_SOC);

	if (CONFIG_DOMZ_HEARTBEAT_INTERVAL_MS <= 0) {
		return 0;
	}

	while (true) {
		k_msleep(CONFIG_DOMZ_HEARTBEAT_INTERVAL_MS);
		LOG_INF("DomZ alive, uptime %u s", (unsigned int)(k_uptime_get() / 1000));
	}

	return 0;
}
