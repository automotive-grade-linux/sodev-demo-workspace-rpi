/*
 * SPDX-License-Identifier: Apache-2.0
 */
package com.android.xt.domawifirelay;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * Starts {@link RelayService} at boot.
 *
 * <p>BOOT_COMPLETED is one of the few implicit broadcasts a manifest-declared receiver
 * may still register for. CONFIGURED_NETWORKS_CHANGED, the broadcast this app actually
 * cares about, is not, so it is registered at runtime by the service. That is also the
 * only way to receive it reliably: WifiConfigManager sends it with
 * FLAG_RECEIVER_REGISTERED_ONLY_BEFORE_BOOT (WifiConfigManager:1145).
 */
public final class BootReceiver extends BroadcastReceiver {
    private static final String TAG = "DomaWifiRelay";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (!Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) {
            return;
        }
        // Started UNCONDITIONALLY, and the service checks the daemon's state and the
        // Settings Wi-Fi toggle on every sweep instead of at startup.
        //
        // WHY: gating the start on the switch would make a later setprop
        // ineffective. The setprop starts or stops the DAEMON (init has
        // property triggers for it), but nothing would start this SERVICE --
        // BOOT_COMPLETED has already fired, and android:persistent starts the
        // process, not the service. Starting always and deciding per sweep
        // costs one idle receiver and lets both switches take effect at the
        // next sweep.
        context.startService(new Intent(context, RelayService.class));
    }
}
