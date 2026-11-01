/*
 * SPDX-License-Identifier: Apache-2.0
 */
package com.android.xt.domawifirelay;

import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.net.wifi.SupplicantState;
import android.net.wifi.WifiConfiguration;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import android.os.FileObserver;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.Process;
import android.os.SystemProperties;
import android.provider.Settings;
import android.system.ErrnoException;
import android.system.Os;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Makes an arbitrary real AP connectable from the AAOS Wi-Fi screen.
 *
 * <h2>The problem</h2>
 * DomA has no radio. Its {@code wlan0} is a {@code mac80211_hwsim} station that
 * associates with a local hostapd (the "shadow AP") on {@code wlan2}, and the real
 * association is performed by DomD. The password the user types is therefore validated
 * by the LOCAL hostapd, whose passphrase comes from
 * {@code /data/vendor/wifi/shadow/aps.conf}. A shadow AP cannot learn a PSK from the
 * 4-way handshake -- only a MIC crosses the air -- so an SSID whose PSK is not already
 * in that file cannot be connected to, and the framework does not merely retry:
 *
 * <pre>
 *   config_wifiDisableReasonByWrongPasswordThreshold  = 1
 *   config_wifiDisableReasonByWrongPasswordDurationMs = -1   (permanent)
 * </pre>
 *
 * so ONE failed handshake sets
 * {@link WifiConfiguration.NetworkSelectionStatus#DISABLED_BY_WRONG_PASSWORD} and the
 * network stops being attempted.
 *
 * <h2>What this service does</h2>
 * It is CORRECTIVE: it acts on a config ALREADY disabled -- for a wrong password, or as
 * NO_INTERNET_PERMANENT while DomD has its SSID -- and on the shadow AP's request to
 * cycle Wi-Fi. While the normal path (an SSID whose PSK aps.conf already holds) works it
 * changes no config, so a bug in the repair cannot break that path. On a config disabled
 * for a wrong password it:
 *
 * <ol>
 *   <li>reads the plaintext passphrase with
 *       {@link WifiManager#getPrivilegedConfiguredNetworks()} (the only sanctioned
 *       route; it returns {@code preSharedKey} unmasked),</li>
 *   <li>hands it to {@code /vendor/bin/doma-wifi-relay}, which puts it into
 *       {@code aps.conf}, regenerates {@code hostapd.conf}, restarts hostapd and
 *       forwards a {@code connect} message to DomD over virtio-serial,</li>
 *   <li>calls {@link WifiManager#connect(int, WifiManager.ActionListener)}, which
 *       clears the permanent disable unconditionally:
 *       {@code ConnectHelper.connectToNetwork()} then
 *       {@code WifiConfigManager.updateBeforeConnect()} then {@code enableNetwork()}
 *       then {@code WifiBlocklistMonitor.setNetworkSelectionEnabled()}, which resets the
 *       status, the reason AND {@code clearDisableReasonCounter()}. The same call's
 *       {@code onEnableNetwork()} also drops the SSID's BSSID blocklist entries
 *       (WifiBlocklistMonitor:755-775), so the retry re-attempts the same BSS.</li>
 * </ol>
 *
 * <p>The retry therefore succeeds: hostapd now holds the passphrase the user typed.
 *
 * <p>Besides that repair, it does what the daemons ask for through the drop-box and may
 * not do themselves from a vendor domain: the Wi-Fi cycle doma-shadow-ap needs once
 * it has made the radios ({@link #handleWifiCycle}), and the "no internet" repair below.
 *
 * <h2>Loop safety</h2>
 * Every (netId, passphrase) pair is attempted at most once. If the passphrase really is
 * wrong for the real AP, DomD's association fails while the local one succeeds, and the
 * user sees "connected, no internet" rather than an endless reconnect storm. Typing a
 * different password produces a different pair and gets one fresh attempt, and so does
 * a network that has since joined the shadow AP successfully (see
 * {@link #forgetAttemptsOfAssociated}).
 *
 * <h2>"No internet" from before DomD had the network</h2>
 * DomA's station joins the shadow BSS at once, while DomD may still be joining the real
 * AP, so the framework's internet check can run before there is a route behind it. A
 * network that fails its first check is marked
 * {@link WifiConfiguration.NetworkSelectionStatus#DISABLED_NO_INTERNET_PERMANENT} and
 * not joined again on its own. The daemon writes {@link #STATE} each time DomD joins an
 * SSID (and when it loses it); while DomD has that SSID, a saved network of it disabled
 * that way is enabled again ({@link #recheckInternet}), once per DomD report. A network
 * DomA is still connected to needs nothing: NetworkMonitor keeps probing, and its first
 * pass clears the disable (ClientModeImpl, NETWORK_STATUS_VALID).
 *
 * <p>LAB USE ONLY. The passphrase is written to a file and crosses a virtio-serial
 * channel in the clear. Same warning as {@code domd_wifi_agent.py}.
 */
public final class RelayService extends Service {
    private static final String TAG = "DomaWifiRelay";

    /**
     * Drop-box the daemon polls. init.xenvm-hwsim.rc creates it 0770 wifi:<b>system</b>
     * precisely so this app -- uid/gid system,
     * because NETWORK_SETTINGS and READ_WIFI_CREDENTIAL are signature permissions and
     * android.uid.system is the only way to hold them -- can create the file in it.
     *
     * <p><b>Owning the last directory is not enough.</b> Creating a file here also needs
     * the search (x) bit on <em>every</em> parent, and both {@code /data/vendor/wifi}
     * and {@code /data/vendor/wifi/shadow} are 0770 wifi:wifi, which uid system is not a
     * member of (platform.xml grants no {@code gid="wifi"} through any permission).
     * Measured on a PC with the same owners and modes (2026-09-08):
     * both parents 0770 -> EACCES; only {@code /data/vendor/wifi} given o+x -> still
     * EACCES; both given o+x (0771) -> the write succeeds, while {@code hostapd.conf}
     * stays unreadable (0660 wifi:wifi) and the directory stays unlistable. So the rc
     * adds o+x -- traversal only -- on {@code sys.boot_completed}, which is
     * after the unconditional {@code on boot} block where cuttlefish's
     * init.vendor.rc:85 sets {@code /data/vendor/wifi} back to 0770 (init's
     * mkdir re-applies the mode to an existing directory:
     * system/core/init/builtins.cpp:394-436). Under SELinux the same two parents need
     * {@code search} for system_app, and the directory has a type of its own
     * (sepolicy/system_app.te).
     *
     * <p>The daemon runs as uid wifi, which is in group system and not the owner of
     * what this app writes, so {@link #REQ} is made 0640 before it is renamed into place
     * (the app's umask gives 0600). The other way round, the daemon makes
     * {@link #STATE} 0640 group system.
     */
    private static final File REQ_DIR = new File("/data/vendor/wifi/shadow/req");
    private static final File REQ = new File(REQ_DIR, "relay.req");
    private static final File REQ_TMP = new File(REQ_DIR, "relay.req.tmp");
    /**
     * Written by the daemon, one line {@code "<kind>\t<seq>\t<SSID>"}: {@code up} when it
     * starts (no SSID; a sweep then runs, since the daemon may start after this
     * service's first sweep), {@code online} each time DomD has joined an SSID, and
     * {@code offline} when DomD has lost it or could not join it. {@code <seq>} is new
     * on every write.
     */
    private static final File STATE = new File(REQ_DIR, "relay.state");
    /**
     * Written by doma-shadow-ap once it has made the radios: Wi-Fi is then cycled, if it
     * is saved on, so the Wi-Fi HAL lists them (the script's step 6 says why). Only its
     * presence counts.
     */
    private static final File WIFI_CYCLE = new File(REQ_DIR, "wifi-cycle");
    /**
     * {@link #WIFI_CYCLE}, renamed by this app while the cycle has Wi-Fi off: if the
     * process dies before Wi-Fi is on again, its next start turns it on.
     */
    private static final File WIFI_CYCLE_OFF = new File(REQ_DIR, "wifi-cycle.off");
    /** How long a cycle waits for Wi-Fi to be off before it turns it on anyway. */
    private static final long CYCLE_OFF_TIMEOUT_MS = 10000;
    /** How often to look for {@link #REQ_DIR} again until it can be watched. */
    private static final long WATCH_RETRY_MS = 5000;

    /**
     * One polling window. The daemon's own loop reads the channel with {@code read -t 2},
     * so 4 s is two of its ticks. Waiting too little is the failure that matters:
     * connect() would race hostapd, fail the handshake again and re-arm
     * DISABLED_BY_WRONG_PASSWORD.
     */
    private static final long DAEMON_GRACE_MS = 4000;

    /**
     * How many {@link #DAEMON_GRACE_MS} windows to wait for the daemon to take the
     * request. {@link #connectWhenConsumed} looks at the drop-box each window
     * and only connects once the request is gone.
     *
     * <p>The bound comes from the daemon's own worst case rather than from its poll
     * interval. In one iteration of doma-wifi-relay.sh, {@code restart_hostapd} can
     * spend its whole poll loop (100 iterations of {@code sleep 0.1}) plus
     * {@code confirm_hostapd_running} (6 x 0.5 s) -- about 13 s; its own
     * comment says the wait STALLS THE MAIN LOOP FOR UP TO 10 s -- and BOTH
     * {@code handle_aps} and {@code flush_pending_restart} can fire it in the
     * same iteration, with
     * {@code read -t 2} on top: roughly 28 s. (The one figure actually measured on a PC
     * is 10.371 s for a single restart_hostapd, which does not include the confirm
     * window.) 10 x 4 s = 40 s therefore covers a healthy-but-busy daemon, and the cost
     * is zero on the normal path, where the request is gone at the first check.
     */
    private static final int REQ_POLLS = 10;

    /**
     * The daemon's init service state: the on/off switch of this service, not a liveness
     * test. The switch itself, {@code persist.vendor.doma.wifi_relay}, is a vendor
     * property, which a core domain may not read (system/sepolicy/private/property.te,
     * the {@code coredomain} neverallow on {@code vendor_property_type}); what it does
     * is start or stop this service in init.xenvm-hwsim.rc, and that is what is read
     * here. "running" is set in the PARENT right after fork
     * (system/core/init/service.cpp:817) whether or not the child survives, and the
     * value is EMPTY before the first start, so a request can still sit unconsumed
     * (see {@link #repair}). init.xenvm-hwsim.rc declares the relay as
     * {@code doma_wifi_relay}, without the {@code vendor.} prefix the hostapd service
     * carries: this app is system_app, i.e. coredomain, which reads the
     * {@code init.svc.} type (private/coredomain.te) and not the vendor one.
     */
    private static final String PROP_RELAY_SVC_STATE = "init.svc.doma_wifi_relay";

    private WifiManager mWifi;
    private HandlerThread mThread;
    private Handler mHandler;
    /** Watches {@link #REQ_DIR}; null until the directory can be reached. */
    private FileObserver mObserver;
    /** The {@code <seq>} of the last {@link #STATE} line acted on (mHandler thread). */
    private String mStateSeq = "";
    /** The SSID DomD has, from the last {@code online} line; null after anything else. */
    private String mOnlineSsid;
    /**
     * {@code seq + " " + netId} of the networks {@link #recheckInternet} has enabled
     * again: once per DomD report, so a network that really has no internet behind DomD
     * goes back to disabled instead of round after round.
     */
    private final Set<String> mReEnabled = new HashSet<>();
    /**
     * (netId, psk) pairs whose single repair attempt has been SPENT. The key is
     * {@code netId + " " + psk}. It is cleared for a network only once that network
     * has associated with the shadow AP ({@link #forgetAttemptsOfAssociated}); short
     * of that, recovery needs a different password, forget+re-add, or a restart of
     * this process -- the permanent disable itself survives reboots (WifiConfigStore's
     * XmlUtil). Only the mHandler thread touches it, so no synchronisation is needed.
     *
     * <p>An entry is added only AFTER the request is in the drop-box, and is
     * removed again if the daemon never takes it: adding it before
     * {@link #repair} would burn the attempt even when nothing was written, and
     * since the key never expires that network would stay disabled forever.
     */
    private final Set<String> mAttempted = new HashSet<>();

    /** init has the daemon running, i.e. the switch is on (see {@link #PROP_RELAY_SVC_STATE}). */
    static boolean isEnabled() {
        return "running".equals(SystemProperties.get(PROP_RELAY_SVC_STATE, ""));
    }

    private final BroadcastReceiver mReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            if (WifiManager.NETWORK_STATE_CHANGED_ACTION.equals(intent.getAction())) {
                mHandler.post(RelayService.this::forgetAttemptsOfAssociated);
            } else if (WifiManager.WIFI_STATE_CHANGED_ACTION.equals(intent.getAction())
                    && intent.getIntExtra(WifiManager.EXTRA_WIFI_STATE, -1)
                            == WifiManager.WIFI_STATE_DISABLED) {
                mHandler.post(RelayService.this::finishWifiCycle);
            } else {
                mHandler.post(RelayService.this::sweep);
            }
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        // The system user only. BOOT_COMPLETED also reaches this app as the AAOS driver
        // user (10), which would start a second instance: Wi-Fi is one for the device, so
        // both would repair the same config, cycle Wi-Fi and race for the one drop-box
        // (measured on the board, 2026-10-18: two processes, uid system and u10_system).
        if (!Process.myUserHandle().isSystem()) {
            Log.i(TAG, "not the system user; stopping");
            stopSelf();
            return;
        }
        // NOT gated on isEnabled() here. The daemon's state is read per sweep instead, so
        // `setprop persist.vendor.doma.wifi_relay false` takes effect without a reboot --
        // see BootReceiver for why starting conditionally did not work.
        mWifi = getSystemService(WifiManager.class);
        if (mWifi == null) {
            Log.e(TAG, "no WifiManager; stopping");
            stopSelf();
            return;
        }
        mThread = new HandlerThread(TAG);
        mThread.start();
        mHandler = new Handler(mThread.getLooper());

        // Runtime registration, not the manifest: CONFIGURED_NETWORKS_CHANGED is an
        // implicit broadcast a manifest receiver may not register for, and it is sent
        // with FLAG_RECEIVER_REGISTERED_ONLY_BEFORE_BOOT (WifiConfigManager:1145).
        // WIFI_STATE_CHANGED as well, so a config left disabled while the Settings Wi-Fi
        // toggle was off is repaired as soon as the toggle comes back on.
        final IntentFilter filter =
                new IntentFilter(WifiManager.CONFIGURED_NETWORKS_CHANGED_ACTION);
        filter.addAction(WifiManager.WIFI_STATE_CHANGED_ACTION);
        // And the station's state, to re-arm a network once it has associated.
        filter.addAction(WifiManager.NETWORK_STATE_CHANGED_ACTION);
        registerReceiver(mReceiver, filter);
        Log.i(TAG, "started (" + PROP_RELAY_SVC_STATE + "=" + relaySvcState() + ")");
        mHandler.post(this::sweep);
        mHandler.post(this::watchReqDir);
    }

    /**
     * Watch {@link #REQ_DIR} for {@link #STATE} and {@link #WIFI_CYCLE}, and handle what
     * is already there. Until the directory can be reached -- init gives its parents o+x
     * only at sys.boot_completed, which may come after this service starts -- look again
     * every {@link #WATCH_RETRY_MS}: a watch on a directory that cannot be reached fails
     * without telling the caller.
     */
    private void watchReqDir() {
        if (mObserver != null) {
            return;
        }
        if (!REQ_DIR.isDirectory()) {
            mHandler.postDelayed(this::watchReqDir, WATCH_RETRY_MS);
            return;
        }
        mObserver = new FileObserver(REQ_DIR, FileObserver.MOVED_TO | FileObserver.CLOSE_WRITE
                | FileObserver.DELETE_SELF | FileObserver.MOVE_SELF) {
            @Override
            public void onEvent(int event, String path) {
                if ((event & (FileObserver.DELETE_SELF | FileObserver.MOVE_SELF)) != 0) {
                    // The directory went (a /data wipe while running): the watch is
                    // dead, so watch the one init or the daemon makes next.
                    mHandler.post(RelayService.this::rewatchReqDir);
                } else if (STATE.getName().equals(path)) {
                    mHandler.post(RelayService.this::handleState);
                } else if (WIFI_CYCLE.getName().equals(path)) {
                    mHandler.post(RelayService.this::handleWifiCycle);
                }
            }
        };
        mObserver.startWatching();
        handleState();
        handleWifiCycle();
    }

    private void rewatchReqDir() {
        if (mObserver != null) {
            mObserver.stopWatching();
            mObserver = null;
        }
        watchReqDir();
    }

    /**
     * doma-shadow-ap asked for a Wi-Fi cycle: off, and on again once it IS off.
     *
     * <p>Only while Wi-Fi is saved on (Settings.Global.WIFI_ON 1, or 2 = on in airplane
     * mode, WifiSettingsStore): with it saved off the framework has not started the HAL,
     * and the user's own ON lists the radios; turning it on here would override the
     * Settings toggle. Saved, not current: the HAL that listed no radios may have failed
     * to start the station, and Wi-Fi then is not enabled although it is saved on.
     *
     * <p>Off and on in one go does nothing: setWifiEnabled() saves the toggle at once and
     * stops the station asynchronously, so by the time the state machine handles the off,
     * the toggle is on again and it keeps the station and the HAL running
     * (ActiveModeWarden handleStaToggleChangeInEnabledState). Hence on only at
     * WIFI_STATE_DISABLED ({@link #finishWifiCycle}), or after
     * {@link #CYCLE_OFF_TIMEOUT_MS}.
     *
     * <p>setWifiEnabled() from a NETWORK_SETTINGS holder counts as the user's toggle:
     * the framework also turns auto-join back on (setAutoJoinEnabledExternal) and counts
     * a toggle in its metrics. This happens once a boot, with Wi-Fi saved on.
     */
    private void handleWifiCycle() {
        if (WIFI_CYCLE_OFF.exists()) {
            // A cycle this process (or one killed in it) left with Wi-Fi off.
            finishWifiCycle();
            return;
        }
        if (!WIFI_CYCLE.exists()) {
            return;
        }
        final int on = Settings.Global.getInt(getContentResolver(), Settings.Global.WIFI_ON, 0);
        if (on != 1 && on != 2) {
            if (!WIFI_CYCLE.delete()) {
                Log.e(TAG, "cannot remove " + WIFI_CYCLE);
            }
            Log.i(TAG, "wifi-cycle: Wi-Fi is saved off; the next ON lists the radios");
            return;
        }
        if (!WIFI_CYCLE.renameTo(WIFI_CYCLE_OFF)) {
            // Not cycling again and again on a file that cannot go.
            Log.e(TAG, "cannot rename " + WIFI_CYCLE + "; Wi-Fi not cycled");
            WIFI_CYCLE.delete();
            return;
        }
        Log.i(TAG, "wifi-cycle: cycling Wi-Fi so the HAL lists the hwsim radios");
        mWifi.setWifiEnabled(false);
        mHandler.postDelayed(mFinishWifiCycle, CYCLE_OFF_TIMEOUT_MS);
    }

    private final Runnable mFinishWifiCycle = this::finishWifiCycle;

    /** The second half of {@link #handleWifiCycle}: Wi-Fi on again. */
    private void finishWifiCycle() {
        if (!WIFI_CYCLE_OFF.exists()) {
            return;
        }
        mHandler.removeCallbacks(mFinishWifiCycle);
        mWifi.setWifiEnabled(true);
        if (!WIFI_CYCLE_OFF.delete()) {
            Log.e(TAG, "cannot remove " + WIFI_CYCLE_OFF);
        }
        Log.i(TAG, "wifi-cycle: Wi-Fi on again");
    }

    /** A new {@link #STATE} line: act on it once. */
    private void handleState() {
        final String line;
        try {
            line = new String(Files.readAllBytes(STATE.toPath()), StandardCharsets.UTF_8);
        } catch (IOException e) {
            return;  // not written yet
        }
        final String[] f = line.endsWith("\n")
                ? line.substring(0, line.length() - 1).split("\t", 3) : new String[0];
        if (f.length < 2 || f[1].equals(mStateSeq)) {
            return;
        }
        mStateSeq = f[1];
        mReEnabled.clear();
        mOnlineSsid = "online".equals(f[0]) && f.length == 3 && !f[2].isEmpty() ? f[2] : null;
        if ("up".equals(f[0])) {
            sweep();
        } else {
            recheckInternet();
        }
    }

    /**
     * DomD has {@link #mOnlineSsid}: enable again a saved network of it that AAOS disabled
     * as NO_INTERNET_PERMANENT, so auto-join can pick it. Run for each DomD report and at
     * each sweep, because the verdict can come after the report: DomA's probe may fail,
     * and the network be disabled, after the report has reached this service. Once per
     * network and report.
     */
    private void recheckInternet() {
        final String ssid = mOnlineSsid;
        if (ssid == null || !isEnabled() || !mWifi.isWifiEnabled()) {
            return;
        }
        final List<WifiConfiguration> configs = mWifi.getConfiguredNetworks();
        if (configs == null) {
            return;
        }
        for (WifiConfiguration c : configs) {
            if (c != null && c.getNetworkSelectionStatus() != null
                    && c.getNetworkSelectionStatus().getNetworkSelectionDisableReason()
                    == WifiConfiguration.NetworkSelectionStatus.DISABLED_NO_INTERNET_PERMANENT
                    && ssid.equals(unquote(c.SSID))
                    && mReEnabled.add(mStateSeq + " " + c.networkId)) {
                Log.i(TAG, "DomD has " + ssid + "; enabling netId=" + c.networkId
                        + " again (it was disabled for no internet)");
                mWifi.enableNetwork(c.networkId, false);
            }
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        if (mObserver != null) {
            mObserver.stopWatching();
        }
        if (mThread != null) {
            try {
                unregisterReceiver(mReceiver);
            } catch (IllegalArgumentException ignored) {
                // Never registered, because onCreate bailed out early.
            }
            mThread.quitSafely();
        }
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    /** Find configs disabled for a wrong password and repair each one once. */
    private void sweep() {
        if (!isEnabled()) {
            // Inert, not stopped: the switch may be flipped at any time and this is
            // the only place that has to notice. The daemon's start ("up" in STATE)
            // brings the sweep back.
            return;
        }
        if (!mWifi.isWifiEnabled()) {
            // The Settings Wi-Fi toggle is off: a repair would ask DomD to associate for
            // a user who has just switched Wi-Fi off. The daemon holds requests then as
            // well; WIFI_STATE_CHANGED brings the sweep back when the toggle is on.
            return;
        }
        // A "no internet" verdict that came after DomD's report (see recheckInternet).
        recheckInternet();
        final List<WifiConfiguration> configs;
        try {
            configs = mWifi.getPrivilegedConfiguredNetworks();
        } catch (SecurityException e) {
            // Signature permissions are missing, which means the APK is not
            // platform-signed. Nothing this service does can work; say so and stop.
            // Do NOT stopSelf() here: android:persistent would restart the process and
            // the same denial would be logged in a loop. Staying up and inert keeps the
            // one diagnostic line visible in logcat, which is the whole value of this
            // branch.
            Log.e(TAG, "getPrivilegedConfiguredNetworks denied -- is the APK signed with"
                    + " the platform key and privileged?", e);
            return;
        }
        if (configs == null) {
            // WifiServiceImpl returns null, not an exception, when a permission check
            // inside its pre-T / T branches fails.
            Log.w(TAG, "getPrivilegedConfiguredNetworks returned null");
            return;
        }
        for (WifiConfiguration c : configs) {
            if (c == null || c.getNetworkSelectionStatus() == null) {
                continue;
            }
            if (c.getNetworkSelectionStatus().getNetworkSelectionDisableReason()
                    != WifiConfiguration.NetworkSelectionStatus.DISABLED_BY_WRONG_PASSWORD) {
                continue;
            }
            final String ssid = unquote(c.SSID);
            final String psk = unquote(c.preSharedKey);
            if (ssid.isEmpty() || psk.isEmpty()) {
                // An open network (no PSK) cannot fail a handshake. A 64-digit
                // hex PSK is stored unquoted, unquote() leaves it as it is, and
                // the relay takes it as a raw PSK.
                Log.w(TAG, "skipping " + ssid + ": no usable passphrase");
                continue;
            }
            final String key = c.networkId + " " + psk;
            if (mAttempted.contains(key)) {
                Log.i(TAG, "already attempted netId=" + c.networkId + "; leaving disabled");
                continue;
            }
            if (!repair(c.networkId, ssid, psk, key)) {
                // Nothing was written, so nothing is spent: try the next candidate.
                // continue rather than return -- the drop-box is untouched so there is
                // no race to lose, and no connect() was issued so this cannot loop.
                continue;
            }
            // Spend the attempt only now that the request is in the drop-box.
            mAttempted.add(key);
            // ONE PER SWEEP, AND RETURN.
            //
            // The request drop-box holds a single file and the daemon polls it every
            // 2 s, so two repairs started in the same pass would race: the second
            // renameTo(REQ) clobbers the first before the daemon reads it.
            // repair() refuses to overwrite a request that is still sitting
            // there, so a second write needs the daemon to have consumed the
            // first one inside the grace window -- and in that case the first
            // request's polling sees the second one and returns its attempt to
            // the pool. The loss is then not permanent, just a skip that the
            // next sweep retries. Returning here
            // costs nothing: connect() changes the network selection status, which
            // makes WifiConfigManager send CONFIGURED_NETWORKS_CHANGED again
            // (sendConfiguredNetworkChangedBroadcast()), and the next sweep
            // picks up the next one.
            return;
        }
    }

    /**
     * Re-arm the repair of the network the station has just associated with.
     *
     * <p>A completed association means the shadow AP accepted this network's PSK, so
     * the repair that put it there has done its job. If the shadow AP later comes back
     * with the placeholder for it -- doma-wifi-relay keeps typed passphrases, but only
     * the newest 64, and /data can be wiped -- the network is disabled again for a
     * wrong password, and it must get a fresh attempt instead of "already attempted;
     * leaving disabled" until this process restarts.
     *
     * <p>Only on COMPLETED, never on the network being enabled again: {@code connect()}
     * re-enables it at once, before the shadow AP has accepted anything, and clearing
     * the attempt there would allow a repair loop.
     */
    private void forgetAttemptsOfAssociated() {
        final WifiInfo wi = mWifi.getConnectionInfo();
        if (wi == null || wi.getNetworkId() == -1
                || wi.getSupplicantState() != SupplicantState.COMPLETED) {
            return;
        }
        final String prefix = wi.getNetworkId() + " ";
        if (mAttempted.removeIf(k -> k.startsWith(prefix))) {
            Log.i(TAG, "netId=" + wi.getNetworkId() + " associated; its repair is re-armed");
        }
    }

    /**
     * Is a request still waiting to be picked up?
     *
     * <p>This uses the SAME predicate as the daemon. doma-wifi-relay.sh tests
     * {@code [ -s "$REQ" ]} -- non-empty -- and only then moves the file aside
     * ({@code mv "$REQ" "$REQ.busy"}). Testing {@code exists()} instead would treat a
     * zero-byte file as "still pending" forever, because the daemon will never take it:
     * the drop-box lives on /data, so that would be a deadlock which survives reboots
     * and needs a manual rm. (writeRequest() writes to a temporary name and renames, so
     * a zero-byte REQ should not happen -- which is exactly why the predicates must not
     * disagree about it.)
     */
    private boolean requestPending() {
        return REQ.length() > 0;
    }

    /** Diagnostics only; see {@link #PROP_RELAY_SVC_STATE}. */
    private static String relaySvcState() {
        final String s = SystemProperties.get(PROP_RELAY_SVC_STATE, "");
        return s.isEmpty() ? "<unset>" : s;
    }

    /**
     * @return true if a request was written -- i.e. if the caller should spend the
     *         attempt. False means nothing was written and nothing is spent.
     */
    private boolean repair(final int netId, String ssid, String psk, final String key) {
        if (requestPending()) {
            Log.w(TAG, "a request is still unconsumed in " + REQ + "; the daemon is not"
                    + " reading it (" + PROP_RELAY_SVC_STATE + "=" + relaySvcState()
                    + "). Not attempting netId=" + netId + " -- attempt NOT spent."
                    + " Check: setprop persist.vendor.doma.wifi_relay true;"
                    + " logcat -s doma-wifi-relay");
            return false;
        }
        Log.i(TAG, "repairing netId=" + netId + " ssid=" + ssid);
        if (!writeRequest(ssid, psk)) {
            return false;
        }
        connectWhenConsumed(netId, key, REQ_POLLS);
        return true;
    }

    /**
     * Wait for the daemon to take the request, then re-trigger the connect. If it never
     * takes it, return the attempt to the pool instead of burning it.
     */
    private void connectWhenConsumed(final int netId, final String key, final int polls) {
        mHandler.postDelayed(new Runnable() {
            @Override
            public void run() {
                if (requestPending()) {
                    if (polls > 1) {
                        connectWhenConsumed(netId, key, polls - 1);
                        return;
                    }
                    mAttempted.remove(key);
                    Log.w(TAG, "daemon did not consume the request within "
                            + (REQ_POLLS * DAEMON_GRACE_MS) + " ms ("
                            + PROP_RELAY_SVC_STATE + "=" + relaySvcState()
                            + "); not connecting netId=" + netId
                            + ", attempt NOT spent. Check: logcat -s doma-wifi-relay");
                    return;
                }
                Log.i(TAG, "re-triggering connect netId=" + netId);
                mWifi.connect(netId, new WifiManager.ActionListener() {
                    @Override
                    public void onSuccess() {
                        Log.i(TAG, "connect(" + netId + ") accepted");
                    }

                    @Override
                    public void onFailure(int reason) {
                        Log.w(TAG, "connect(" + netId + ") rejected, reason=" + reason);
                    }
                });
            }
        }, DAEMON_GRACE_MS);
    }

    /**
     * Write one tab-separated {@code psk} request line for the daemon.
     *
     * <p>Written to a temporary name and renamed, so the daemon can never read a partial
     * line: it polls for the final name only, and its own first action is to move the
     * file aside.
     */
    private boolean writeRequest(String ssid, String psk) {
        if (!REQ_DIR.isDirectory()) {
            // isDirectory() is also false when the directory exists but a parent denies
            // search, which is the failure this path actually hit (see the field's
            // javadoc). Saying "missing" there sends the reader looking for the daemon
            // instead of at the modes, so name both causes.
            Log.e(TAG, REQ_DIR + " is not reachable -- either doma-wifi-relay has not "
                    + "created it yet, or a parent lacks o+x (check: ls -ld "
                    + "/data/vendor/wifi /data/vendor/wifi/shadow -- both need 0771)");
            return false;
        }
        try (FileOutputStream fos = new FileOutputStream(REQ_TMP);
                OutputStreamWriter w = new OutputStreamWriter(fos, StandardCharsets.UTF_8)) {
            w.write("psk\t" + ssid + "\t" + psk + "\n");
            w.flush();
            fos.getFD().sync();
            // Group-readable for the daemon (uid wifi, group system); see REQ_DIR.
            Os.fchmod(fos.getFD(), 0640);
        } catch (IOException | ErrnoException e) {
            Log.e(TAG, "cannot write " + REQ_TMP, e);
            REQ_TMP.delete();
            return false;
        }
        if (!REQ_TMP.renameTo(REQ)) {
            Log.e(TAG, "cannot rename " + REQ_TMP + " to " + REQ);
            REQ_TMP.delete();
            return false;
        }
        return true;
    }

    /** WifiConfiguration keeps SSID and preSharedKey wrapped in literal double quotes. */
    private static String unquote(String s) {
        if (s == null) {
            return "";
        }
        if (s.length() >= 2 && s.charAt(0) == '"' && s.charAt(s.length() - 1) == '"') {
            return s.substring(1, s.length() - 1);
        }
        return s;
    }
}
