/*
 * SPDX-License-Identifier: Apache-2.0
 */
package com.android.xt.domawifirelay;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.net.NetworkInfo;
import android.net.wifi.ScanResult;
import android.net.wifi.SupplicantState;
import android.net.wifi.WifiConfiguration;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import android.os.FileObserver;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.Process;
import android.os.RemoteException;
import android.os.SystemClock;
import android.os.SystemProperties;
import android.os.UserHandle;
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
import java.nio.file.NoSuchFileException;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.Predicate;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

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
 *   <li>hands it to {@code /vendor/bin/doma-wifi-relay}, which forwards a
 *       {@code connect} message to DomD over virtio-serial and, once DomD has joined
 *       the real AP with it, puts it into {@code aps.conf}, regenerates
 *       {@code hostapd.conf}, restarts hostapd and writes {@code online} to
 *       {@link #STATE},</li>
 *   <li>holds the network back meanwhile ({@link #holdBack}): the disable is cleared
 *       without a connect, so the Wi-Fi screen does not tell the user to check a
 *       password that may be right, and auto-join is off for it, so the framework
 *       does not try it against the placeholder again,</li>
 *   <li>on that {@code online}, calls
 *       {@link WifiManager#connect(int, WifiManager.ActionListener)}, which
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
 * Until DomD has joined with it, DomA's station joins nothing, so the screen does not
 * show the network as connected for a passphrase the real AP refuses (before
 * 2026-11-08 it did, until DomD's answer). When DomD refuses it, the network is
 * connected once, against the row's PSK, which the passphrase does not match, so that
 * it is disabled for a wrong password again and the screen asks for the password.
 *
 * <p>Besides that repair, it does what the daemons ask for through the drop-box and may
 * not do themselves from a vendor domain: the Wi-Fi cycle doma-shadow-ap needs once
 * it has made the radios ({@link #handleWifiCycle}), and the "no internet" repair below.
 *
 * <h2>Loop safety</h2>
 * Every (netId, passphrase) pair is attempted at most once. If the passphrase really is
 * wrong for the real AP, DomD's association fails, and the network goes back to
 * disabled for a wrong password rather than into an endless reconnect storm. When DomD
 * fails it for another reason (the AP not found, no answer), the attempt is returned,
 * and auto-join stays off for the network until it next associates: the user's tap
 * tries it again, and auto-join does not, round after round. Typing a
 * different password produces a different pair and gets one fresh attempt, and so does
 * a network that has since joined the shadow AP successfully (see
 * {@link #forgetAttemptsOfAssociated}). A passphrase DomD has refused stays spent
 * across reboots ({@link #REFUSED}).
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
     * Where the daemon moves {@link #REQ} while it handles it, and removes it from
     * after: a request is handled only once both are gone.
     */
    private static final File REQ_BUSY = new File(REQ_DIR, "relay.req.busy");
    /**
     * The networks {@link #holdBack} has turned auto-join off for, one netId per line:
     * turned on again when the network associates, and at the start of this service,
     * so that a process killed during a wait does not leave one off for good. In this
     * app's device-protected storage.
     */
    private static final String AUTOJOIN_OFF = "autojoin-off";
    /**
     * The (SSID, passphrase) pairs DomD has refused ({@code offline:wrong-key}), one
     * {@code "<SSID mac>TAB<pair mac>"} per line ({@link #refusedEntry}): no plaintext,
     * and keyed by the SSID, not the netId, which the framework hands out again at each
     * boot in the order of its store. In this app's device-protected storage, so that a reboot does not
     * send DomD a passphrase it has refused again: the network stays disabled for a
     * wrong password across reboots (WifiConfigStore), {@link #mAttempted} does not,
     * and the sweep of each boot repaired it, which told the user without a tap that
     * the password is not correct (RPi4 2026-11-08). An entry goes when a network of its
     * SSID associates ({@link #forgetAttemptsOfAssociated}) or is forgotten (the
     * framework's CHANGE_REASON_REMOVED, and at {@link #sweep} when none of the SSID is
     * saved any more: forget and add again tries the passphrase again); a new
     * passphrase is another pair. Typing the same passphrase again on the same saved
     * network does not: the framework's broadcast does not tell that from its own
     * status changes.
     */
    private static final String REFUSED = "refused";
    /** The device's random key of the macs in {@link #REFUSED}, so that the file cannot
     *  be checked against a list of passphrases elsewhere. */
    private static final String REFUSED_KEY = "refused.key";
    /**
     * Written by the daemon, one line {@code "<kind>\t<seq>\t<SSID>"}: {@code up} when it
     * starts (no SSID; a sweep then runs, since the daemon may start after this
     * service's first sweep), {@code pending} when it has forwarded a connect for the
     * SSID to DomD, {@code online} each time DomD has joined an SSID, and
     * {@code offline:<reason>} when DomD has lost it ({@code lost}) or could not join it
     * ({@code not-found}, {@code wrong-key}, {@code rejected}, {@code timeout},
     * {@code error}; {@code retry} while a later connect for it is still pending). A
     * daemon from before the reasons writes a bare {@code offline} and no
     * {@code pending}. {@code <seq>} is new on every write. A line that answers a request
     * of this app's has a fourth field, the request's token (see {@link #onWaitState}).
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
     * How often {@link #connectWhenConsumed} looks whether the daemon has handled the
     * request. Short, since the user is waiting; the daemon itself picks the request up
     * within its {@code read -t 2}.
     */
    private static final long POLL_MS = 250;

    /**
     * How many {@link #POLL_MS} looks to wait for the daemon to handle the request, i.e.
     * for {@link #REQ} and {@link #REQ_BUSY} to be gone.
     *
     * <p>The bound comes from the daemon's own worst case rather than from its poll
     * interval. In one iteration of doma-wifi-relay.sh, {@code restart_hostapd} can
     * spend its whole poll loop (100 iterations of {@code sleep 0.1}) plus
     * {@code confirm_hostapd_running} (6 x 0.25 s) -- about 11.5 s -- and BOTH
     * {@code handle_aps} and {@code flush_pending_restart} can fire it in the
     * same iteration, with
     * {@code read -t 2} on top: roughly 25 s. (The one figure actually measured on a PC
     * is 10.371 s for a single restart_hostapd, which does not include the confirm
     * window.) 160 x 250 ms = 40 s therefore covers a healthy-but-busy daemon, and the
     * cost is zero on the normal path, where the request is handled within 2 s.
     */
    private static final int REQ_POLLS = 160;

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
    /**
     * Tells the user what DomD's real join is doing (see {@link #notifyState}). DomA's
     * station joins the SHADOW BSS within seconds whatever happens to the real AP, so the
     * Wi-Fi screen alone shows a network as joined while DomD is still looking for it,
     * and drops it without a reason when DomD fails (2026-11-06: an SSID DomD could not
     * find looked joined for 30 s). Null if the service is not there.
     */
    private NotificationManager mNm;
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

    /** A repair waiting for the daemon and for DomD (see {@link #repair}). */
    private static final class Wait {
        final int netId;
        final String ssid;
        final String key;
        /** Sent with the request; the daemon gives it back in each {@link #STATE} line
         *  that answers it, so no other connect's line is taken for its answer. */
        final String token;
        /** {@link #STATE}'s {@code <seq>} just before the request was written: a line
         *  with it is from before the request (see {@link #onWaitState}). */
        final String startSeq;
        /** Its {@link #REFUSED} entry, should DomD refuse the passphrase. */
        final String refused;

        Wait(int netId, String ssid, String key, String token, String startSeq,
                String refused) {
            this.netId = netId;
            this.ssid = ssid;
            this.key = key;
            this.token = token;
            this.startSeq = startSeq;
            this.refused = refused;
        }
    }

    private final SecureRandom mRandom = new SecureRandom();

    /** The one repair under way, or null; one at a time, as the drop-box holds one. */
    private Wait mWait;
    private final Runnable mWaitTimeout = () -> finishWait(mWait, "timeout");

    /** init has the daemon running, i.e. the switch is on (see {@link #PROP_RELAY_SVC_STATE}). */
    static boolean isEnabled() {
        return "running".equals(SystemProperties.get(PROP_RELAY_SVC_STATE, ""));
    }

    private final BroadcastReceiver mReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            if (Intent.ACTION_LOCALE_CHANGED.equals(intent.getAction())) {
                mHandler.post(RelayService.this::createChannels);
            } else if (WifiManager.NETWORK_STATE_CHANGED_ACTION.equals(intent.getAction())) {
                final NetworkInfo ni = intent.getParcelableExtra(
                        WifiManager.EXTRA_NETWORK_INFO, NetworkInfo.class);
                final boolean connected = ni != null && ni.isConnected();
                mHandler.post(() -> {
                    forgetAttemptsOfAssociated();
                    onStationConnected(connected);
                });
            } else if (WifiManager.SCAN_RESULTS_AVAILABLE_ACTION.equals(intent.getAction())) {
                mHandler.post(RelayService.this::onScanResults);
            } else if (WifiManager.CONFIGURED_NETWORKS_CHANGED_ACTION.equals(intent.getAction())
                    && intent.getIntExtra(WifiManager.EXTRA_CHANGE_REASON, -1)
                            == WifiManager.CHANGE_REASON_REMOVED) {
                // The copy for the system user carries the network (WifiConfigManager
                //   sendConfiguredNetworkChangedBroadcast): a forgotten network's refused
                //   pairs go with it (REFUSED), whatever the next sweep reads.
                final WifiConfiguration gone = intent.getParcelableExtra(
                        WifiManager.EXTRA_WIFI_CONFIGURATION, WifiConfiguration.class);
                final String ssid = gone == null ? "" : unquote(gone.SSID);
                mHandler.post(() -> {
                    if (!ssid.isEmpty()) {
                        refusedForget(ssid);
                    }
                    sweep();
                });
            } else if (WifiManager.WIFI_STATE_CHANGED_ACTION.equals(intent.getAction())
                    && intent.getIntExtra(WifiManager.EXTRA_WIFI_STATE, -1)
                            == WifiManager.WIFI_STATE_DISABLED) {
                mHandler.post(RelayService.this::finishWifiCycle);
            } else if (WifiManager.CONFIGURED_NETWORKS_CHANGED_ACTION.equals(intent.getAction())) {
                // The system user's copy names the network (see the REMOVED branch).
                final WifiConfiguration changed = intent.getParcelableExtra(
                        WifiManager.EXTRA_WIFI_CONFIGURATION, WifiConfiguration.class);
                mHandler.post(() -> {
                    onRefusedConnectFailed(changed);
                    sweep();
                });
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
        mNm = getSystemService(NotificationManager.class);
        if (mNm != null) {
            createChannels();
            // One left by an earlier process of this app (killed, then restarted) names
            // a join nobody will answer to this one.
            mNm.cancelAsUser(null, NOTE_ID, UserHandle.ALL);
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
        // And scan results, to connect once the restarted shadow BSS is seen
        //   (connectAfterScan).
        filter.addAction(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION);
        // And the language, to rename the notification channels (see createChannels).
        filter.addAction(Intent.ACTION_LOCALE_CHANGED);
        registerReceiver(mReceiver, filter);
        Log.i(TAG, "started (" + PROP_RELAY_SVC_STATE + "=" + relaySvcState() + ")");
        mHandler.post(this::restoreAllAutojoin);
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
                    mHandler.post(() -> handleState(true));
                } else if (WIFI_CYCLE.getName().equals(path)) {
                    mHandler.post(RelayService.this::handleWifiCycle);
                }
            }
        };
        mObserver.startWatching();
        // Not notified on the first watch of this process: the line can be from long
        // before it (a restart of the app), and a "connecting" it names may never be
        // answered. A later watch (the directory was made again while this process
        // ran) is: the line was written while it ran, and one already acted on is
        // skipped by its seq.
        handleState(mWatchedOnce);
        mWatchedOnce = true;
        handleWifiCycle();
    }

    /** {@link #watchReqDir} has run once in this process (see there). */
    private boolean mWatchedOnce;

    /**
     * Create the notification channels, or rename them after a change of language: the
     * process is persistent, so names taken at onCreate only would stay in the language
     * of the boot. Creating a channel that exists updates its name and nothing else.
     */
    private void createChannels() {
        if (mNm == null) {
            return;
        }
        // LOW: progress and success, in the shade without a sound or a heads-up.
        // HIGH: a failure, as a heads-up, since the user is waiting on the Wi-Fi
        // screen for a network that will not come. No sound on either.
        final NotificationChannel status = new NotificationChannel(CH_STATUS,
                getString(R.string.channel_status), NotificationManager.IMPORTANCE_LOW);
        final NotificationChannel failure = new NotificationChannel(CH_FAILURE,
                getString(R.string.channel_failure), NotificationManager.IMPORTANCE_HIGH);
        failure.setSound(null, null);
        mNm.createNotificationChannel(status);
        mNm.createNotificationChannel(failure);
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

    /**
     * A new {@link #STATE} line: act on it once.
     *
     * @param notify tell the user about it ({@link #notifyState}); false for the line
     *     found when the watch starts
     */
    private void handleState(boolean notify) {
        final String[] f = readState();
        if (f.length < 2 || f[1].equals(mStateSeq)) {
            return;
        }
        mStateSeq = f[1];
        mReEnabled.clear();
        mOnlineSsid = "online".equals(f[0]) && f.length >= 3 && !f[2].isEmpty() ? f[2] : null;
        mConnectIssued = -1;
        if (mWait != null) {
            onWaitState(mWait, f[0], f[1], f.length == 4 ? f[3] : "");
        }
        if (mWait == null && mOnlineSsid != null) {
            connectHeldBack(mOnlineSsid);
        }
        if (notify) {
            // Each line replaces the notification, and the "Connected" one held back for
            //   an earlier line with it.
            dropConnectedNote();
            if (mOnlineSsid != null && mConnectIssued != -1) {
                // This app has just started DomA's station on the network: "Connected"
                //   once the station is (onStationConnected), not now, while the screen
                //   still shows it connecting (2026-11-08: 8 s before it). The
                //   "Connecting" notification stays until then.
                holdConnectedNote(mOnlineSsid, mConnectIssued);
            } else {
                notifyState(f[0], f.length >= 3 ? f[2] : "");
            }
        }
        if ("up".equals(f[0])) {
            sweep();
        } else {
            recheckInternet();
        }
    }

    /** {@link #STATE}'s fields, or none when it is not there or not a whole line. */
    private static String[] readState() {
        final String line;
        try {
            line = new String(Files.readAllBytes(STATE.toPath()), StandardCharsets.UTF_8);
        } catch (IOException e) {
            return new String[0];  // not written yet
        }
        return line.endsWith("\n")
                ? line.substring(0, line.length() - 1).split("\t", 4) : new String[0];
    }

    /**
     * A {@link #STATE} line while a repair waits: one with its token answers it --
     * connect the network on DomD's {@code online}, give up on a failure. Any other is
     * about another connect (the mirror's, an earlier one) and changes nothing, but
     * {@code up}: the daemon restarted, and no answer will come -- unless the line is
     * from before the request (the first read of {@link #STATE} in this process can
     * come after the request was written, and finds the daemon's start), or the request
     * is still in the drop-box, where the new daemon picks it up (2026-11-08: the wait
     * was given up on an old {@code up}, the daemon then sent the request to DomD, and
     * its answer told the user of a failure no one waited for).
     */
    private void onWaitState(Wait w, String kind, String seq, String token) {
        if ("up".equals(kind)) {
            // REQ.busy too: the new daemon removes it before its "up", so one after
            //   that is the request, taken by the new daemon.
            if (seq.equals(w.startSeq) || requestPending() || REQ_BUSY.exists()) {
                Log.i(TAG, "the daemon is up; netId=" + w.netId + " still waits for DomD");
                return;
            }
            finishWait(w, "up");
        } else if (w.token.equals(token)
                && ("online".equals(kind) || kind.startsWith("offline"))) {
            finishWait(w, kind);        // offline:retry too: its connect failed
        }
    }

    /**
     * End the repair w: on {@code online} connect the network; on a refused passphrase
     * connect it too, against the row's PSK (the placeholder, or a seed or learned one
     * that this passphrase does not match), so that it is disabled for a wrong
     * password again and the screen asks for one (the attempt stays spent, so it is not
     * repaired again); on anything else return the attempt and leave auto-join off
     * (see Loop safety), unless the daemon never took the request.
     */
    private void finishWait(Wait w, String outcome) {
        if (w == null || w != mWait) {
            return;
        }
        mWait = null;
        mHandler.removeCallbacks(mWaitTimeout);
        if ("online".equals(outcome)) {
            restoreAutojoin(w.netId);
            Log.i(TAG, "DomD joined " + w.ssid + "; connecting netId=" + w.netId
                    + " once its shadow BSS is seen");
            connectAfterScan(w.netId, w.ssid);
        } else if ("offline:wrong-key".equals(outcome)) {
            restoreAutojoin(w.netId);
            if (w.refused != null) {
                refusedSet(w.refused, true);
            }
            Log.i(TAG, "DomD refused the passphrase for " + w.ssid + "; connecting netId="
                    + w.netId);
            mRefusedConnectNetId = w.netId;
            mRefusedConnectUntil = SystemClock.elapsedRealtime() + REFUSED_CONNECT_WINDOW_MS;
            connect(w.netId);
        } else {
            mAttempted.remove(w.key);
            if ("unconsumed".equals(outcome)) {
                restoreAutojoin(w.netId);
            }
            Log.i(TAG, "DomD did not join " + w.ssid + " (" + outcome + "); netId=" + w.netId
                    + " is left to the user's tap, attempt NOT spent");
        }
        mHandler.post(this::sweep);
    }

    private void connect(final int netId) {
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

    /** How long {@link #connectAfterScan} waits for a scan that sees the network. */
    private static final long SCAN_WAIT_MS = 5000;
    /** How long a held-back "Connected" waits for the station (see {@link #handleState}). */
    private static final long CONNECTED_NOTE_WAIT_MS = 30_000;
    /** The network {@link #connectAfterScan} waits to see, or -1; its SSID, and since when
     *  (elapsed realtime, us: {@link ScanResult#timestamp}'s clock). */
    private int mScanNetId = -1;
    private String mScanSsid;
    private long mScanSinceUs;
    private final Runnable mScanTimeout = () -> connectScanned("no scan saw it in "
            + SCAN_WAIT_MS + " ms");
    /** The network a connect was started for, for the line handleState is acting on;
     *  -1 if none. */
    private int mConnectIssued = -1;
    /** The SSID whose "Connected" waits for DomA's station, or null; and the network. */
    private String mConnectedNote;
    private int mConnectedNoteNetId = -1;
    private final Runnable mConnectedNoteTimeout = this::dropConnectedNote;

    /**
     * Connect the network once a scan from now on sees its SSID. DomD's "online" for a
     * typed passphrase comes once hostapd has restarted with it, and the restart
     * replaces the shadow BSS: a connect right away failed at once against the BSS
     * cached from before, and the station joined only after the framework's next scan
     * (2026-11-08, about 4 s). After {@link #SCAN_WAIT_MS} it connects anyway.
     */
    private void connectAfterScan(int netId, String ssid) {
        mConnectIssued = netId;
        if (mScanNetId != -1 && mScanNetId != netId) {
            connectScanned("another network is next");
        }
        mScanNetId = netId;
        mScanSsid = ssid;
        mScanSinceUs = SystemClock.elapsedRealtime() * 1000;
        mHandler.removeCallbacks(mScanTimeout);
        mHandler.postDelayed(mScanTimeout, SCAN_WAIT_MS);
        if (!mWifi.startScan()) {
            connectScanned("the scan was refused");
        }
    }

    private void onScanResults() {
        if (mScanNetId == -1) {
            return;
        }
        final List<ScanResult> results = mWifi.getScanResults();
        if (results == null) {
            return;
        }
        for (ScanResult r : results) {
            if (r != null && r.timestamp >= mScanSinceUs && mScanSsid.equals(unquote(r.SSID))) {
                connectScanned("a scan sees it");
                return;
            }
        }
    }

    private void connectScanned(String why) {
        final int netId = mScanNetId;
        if (netId == -1) {
            return;
        }
        mScanNetId = -1;
        mHandler.removeCallbacks(mScanTimeout);
        Log.i(TAG, "connecting netId=" + netId + " (" + why + ")");
        connect(netId);
    }

    private void holdConnectedNote(String ssid, int netId) {
        if (stationConnectedTo(ssid, netId)) {
            // Connected already (the framework joined it first): the connect does
            //   nothing, and no NETWORK_STATE_CHANGED is to come.
            notifyState("online", ssid);
            return;
        }
        mConnectedNote = ssid;
        mConnectedNoteNetId = netId;
        mHandler.removeCallbacks(mConnectedNoteTimeout);
        mHandler.postDelayed(mConnectedNoteTimeout, CONNECTED_NOTE_WAIT_MS);
    }

    /** Forget a held-back "Connected"; past its wait, take the "Connecting" down too. */
    private void dropConnectedNote() {
        if (mConnectedNote == null) {
            return;
        }
        final boolean timedOut = !mHandler.hasCallbacks(mConnectedNoteTimeout);
        mConnectedNote = null;
        mHandler.removeCallbacks(mConnectedNoteTimeout);
        if (timedOut && mNm != null) {
            mNm.cancelAsUser(null, NOTE_ID, UserHandle.ALL);
        }
    }

    /** DomA's station is connected (with an IP address) to the SSID: the last, sticky
     *  NETWORK_STATE_CHANGED says connected, and the connection is that network's: not
     *  another config of the SSID on the BSS from before hostapd's restart. */
    private boolean stationConnectedTo(String ssid, int netId) {
        final Intent last = registerReceiver(null,
                new IntentFilter(WifiManager.NETWORK_STATE_CHANGED_ACTION));
        final NetworkInfo ni = last == null ? null
                : last.getParcelableExtra(WifiManager.EXTRA_NETWORK_INFO, NetworkInfo.class);
        if (ni == null || !ni.isConnected()) {
            return false;
        }
        final WifiInfo wi = mWifi.getConnectionInfo();
        return wi != null && wi.getNetworkId() == netId && ssid.equals(unquote(wi.getSSID()));
    }

    /** DomA's station is connected (with an IP address), or not: a held-back "Connected"
     *  for its SSID is shown now. */
    private void onStationConnected(boolean connected) {
        if (mConnectedNote == null || !connected) {
            return;
        }
        final WifiInfo wi = mWifi.getConnectionInfo();
        if (wi != null && wi.getNetworkId() == mConnectedNoteNetId
                && mConnectedNote.equals(unquote(wi.getSSID()))) {
            final String ssid = mConnectedNote;
            mConnectedNote = null;
            mHandler.removeCallbacks(mConnectedNoteTimeout);
            notifyState("online", ssid);
        }
    }

    /**
     * The framework's own "Failed to connect" for the network (WrongPasswordNotifier,
     * NOTE_WIFI_WRONG_PASSWORD = 42 with the tag {@code com.android.wifi}, posted by
     * package {@code android} for the current user), which the station's first
     * handshake against the placeholder posts while DomD is still trying the
     * passphrase: taken down, since the passphrase may be right. Through
     * INotificationManager with {@code android} as both the package and the op package:
     * NotificationManager names this app's package, also from
     * createPackageContextAsUser("android"), which for "android" copies this app's
     * own context (ContextImpl), and so finds nothing. NotificationManagerService
     * takes it from uid system (resolveNotificationUid compares the app id, and with
     * the two packages the same there is no op package check); the current user is
     * the driver's, to whom the framework posts it (WifiNotificationManager). Also the
     * one the connect after DomD has refused the passphrase posts
     * ({@link #onRefusedConnectFailed}): this app's own notice already says the
     * password is not correct, with a tap to the Wi-Fi settings, which is all the
     * framework's tap opens on this product (its {@code wifi_start_connect_ssid} extra
     * has no reader in Car Settings).
     */
    private void cancelFrameworkWrongPassword() {
        try {
            NotificationManager.getService().cancelNotificationWithTag("android", "android",
                    WIFI_NOTE_TAG, WIFI_NOTE_WRONG_PASSWORD, UserHandle.USER_CURRENT);
        } catch (RemoteException | RuntimeException e) {
            Log.w(TAG, "cannot take down the framework's wrong-password notification", e);
        }
    }

    /**
     * The connect finishWait issues after DomD has refused a passphrase fails against
     * the row's PSK by design, and the framework then posts its "Failed to connect"
     * (ClientModeImpl: onWrongPasswordError, then the network is disabled, which sends
     * CONFIGURED_NETWORKS_CHANGED with the network): seen 8 s after the connect on the
     * board (2026-11-08), next to this app's own notice. Taken down until this time
     * (elapsedRealtime) on that broadcast for that network
     * ({@link #mRefusedConnectNetId}) disabled for a wrong password -- not for one the
     * user tapped meanwhile, whose notice is the only one there is -- now and once more
     * 1 s later in case the post lands after it. The window stays open after a hit: the
     * auto-join this branch turns on again sends a broadcast of its own, which can still
     * carry the network disabled from the placeholder's failure, before the connect.
     */
    private long mRefusedConnectUntil;
    private int mRefusedConnectNetId = -1;
    private static final long REFUSED_CONNECT_WINDOW_MS = 20_000;

    private void onRefusedConnectFailed(WifiConfiguration changed) {
        if (mRefusedConnectNetId == -1) {
            return;
        }
        if (SystemClock.elapsedRealtime() >= mRefusedConnectUntil) {
            mRefusedConnectNetId = -1;
            return;
        }
        if (changed == null || changed.networkId != mRefusedConnectNetId
                || changed.getNetworkSelectionStatus() == null
                || changed.getNetworkSelectionStatus().getNetworkSelectionDisableReason()
                        != WifiConfiguration.NetworkSelectionStatus.DISABLED_BY_WRONG_PASSWORD) {
            return;
        }
        cancelFrameworkWrongPassword();
        mHandler.postDelayed(this::cancelFrameworkWrongPassword, 1000);
    }

    private static final String WIFI_NOTE_TAG = "com.android.wifi";
    private static final int WIFI_NOTE_WRONG_PASSWORD = 42;

    /** {@link #REFUSED}'s entry for the pair, {@code "<mac of SSID>TAB<mac of SSID, NUL,
     *  passphrase>"} (HMAC-SHA-256 with {@link #refusedKey}, hex); null if there is no
     *  key (nothing is then kept). */
    private String refusedEntry(String ssid, String psk) {
        final String sm = refusedMac(ssid.getBytes(StandardCharsets.UTF_8), null);
        final String pm = refusedMac(ssid.getBytes(StandardCharsets.UTF_8),
                psk.getBytes(StandardCharsets.UTF_8));
        return sm == null || pm == null ? null : sm + "\t" + pm;
    }

    /** The SSID part of {@link #refusedEntry}, with its TAB; null if there is no key. */
    private String refusedPrefix(String ssid) {
        final String sm = refusedMac(ssid.getBytes(StandardCharsets.UTF_8), null);
        return sm == null ? null : sm + "\t";
    }

    private String refusedMac(byte[] a, byte[] b) {
        final byte[] key = refusedKey();
        if (key == null) {
            return null;
        }
        try {
            final Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(key, "HmacSHA256"));
            mac.update(a);
            if (b != null) {
                mac.update((byte) 0);
                mac.update(b);
            }
            final StringBuilder h = new StringBuilder();
            for (byte x : mac.doFinal()) {
                h.append(String.format("%02x", x & 0xff));
            }
            return h.toString();
        } catch (GeneralSecurityException e) {
            Log.e(TAG, "no HmacSHA256", e);
            return null;
        }
    }

    /** {@link #REFUSED_KEY}, made on the first use; null if it can be neither read nor
     *  made. */
    private byte[] refusedKey() {
        if (mRefusedKey != null) {
            return mRefusedKey;
        }
        final File f = new File(createDeviceProtectedStorageContext().getFilesDir(),
                REFUSED_KEY);
        try {
            final byte[] k = Files.readAllBytes(f.toPath());
            if (k.length == 32) {
                return mRefusedKey = k;
            }
            // torn (cut off by a power loss): made again below
        } catch (NoSuchFileException e) {
            // not made yet
        } catch (IOException e) {
            // There but not readable now: no key this time, rather than a new one,
            //   which would drop every entry.
            Log.e(TAG, "cannot read " + f, e);
            return null;
        }
        final byte[] k = new byte[32];
        mRandom.nextBytes(k);
        final File tmp = new File(f.getPath() + ".tmp");
        try {
            Files.write(tmp.toPath(), k);
            if (!tmp.renameTo(f)) {
                Log.e(TAG, "cannot rename " + tmp + " to " + f);
                return null;
            }
        } catch (IOException e) {
            Log.e(TAG, "cannot write " + tmp, e);
            return null;
        }
        // A new key: entries made with another one would never match.
        refusedWrite(new HashSet<>());
        return mRefusedKey = k;
    }

    private byte[] mRefusedKey;

    /** {@link #REFUSED}, read once per process (see {@link #autojoinOffMap}). */
    private Set<String> refusedSet() {
        if (mRefused == null) {
            mRefused = new HashSet<>();
            try {
                for (String l : Files.readAllLines(refusedFile().toPath(),
                        StandardCharsets.UTF_8)) {
                    if (l.indexOf('\t') > 0) {
                        mRefused.add(l);
                    }
                }
            } catch (IOException e) {
                // none yet
            }
        }
        return mRefused;
    }

    private Set<String> mRefused;

    private File refusedFile() {
        return new File(createDeviceProtectedStorageContext().getFilesDir(), REFUSED);
    }

    /** Add (on) or remove an entry of {@link #REFUSED}. */
    private void refusedSet(String entry, boolean on) {
        final Set<String> set = new HashSet<>(refusedSet());
        if (on ? !set.add(entry) : !set.remove(entry)) {
            return;
        }
        refusedWrite(set);
    }

    /** The SSID's entries go. */
    private void refusedForget(String ssid) {
        final String pre = refusedPrefix(ssid);
        if (pre != null) {
            refusedRetain(e -> !e.startsWith(pre));
        }
    }

    /** Keep the entries {@code keep} accepts, the others go. */
    private void refusedRetain(Predicate<String> keep) {
        final Set<String> set = new HashSet<>(refusedSet());
        if (set.removeIf(keep.negate())) {
            refusedWrite(set);
        }
    }

    private void refusedWrite(Set<String> set) {
        mRefused = set;
        final File f = refusedFile();
        final File tmp = new File(f.getPath() + ".tmp");
        final StringBuilder b = new StringBuilder();
        for (String e : set) {
            b.append(e).append('\n');
        }
        try {
            Files.write(tmp.toPath(), b.toString().getBytes(StandardCharsets.UTF_8));
            if (!tmp.renameTo(f)) {
                Log.e(TAG, "cannot rename " + tmp + " to " + f);
            }
        } catch (IOException e) {
            Log.e(TAG, "cannot write " + tmp, e);
        }
    }

    /**
     * Clear the network's disable without connecting it, and turn its auto-join off
     * while DomD tries the passphrase: enableNetwork(netId, false) resets the status, the
     * reason and the counter (WifiBlocklistMonitor.setNetworkSelectionEnabled) without
     * an attempt (WifiServiceImpl.enableNetwork), so the screen no longer says to check
     * the password; with auto-join on, the framework would try it against the
     * placeholder again and disable it again. Auto-join first: both run on the wifi
     * thread in this order. The cost: allowAutojoin() also drops the user's connect
     * choices (WifiConfigManager), which turning it on again does not bring back.
     */
    private void holdBack(WifiConfiguration c) {
        if (c.allowAutojoin) {
            autojoinOff(c.networkId, unquote(c.SSID));
            mWifi.allowAutojoin(c.networkId, false);
        }
        mWifi.enableNetwork(c.networkId, false);
    }

    private File autojoinFile() {
        return new File(createDeviceProtectedStorageContext().getFilesDir(), AUTOJOIN_OFF);
    }

    /**
     * {@link #AUTOJOIN_OFF}: netId to the SSID it had when auto-join was turned off. Read
     * once per process and kept in {@link #mAutojoinOff}, so that a write that fails
     * does not make a network come back on every DomD report.
     */
    private Map<Integer, String> autojoinOffMap() {
        if (mAutojoinOff == null) {
            mAutojoinOff = readAutojoinOff();
        }
        return new HashMap<>(mAutojoinOff);
    }

    private Map<Integer, String> mAutojoinOff;

    private Map<Integer, String> readAutojoinOff() {
        final Map<Integer, String> ids = new HashMap<>();
        try {
            for (String l : Files.readAllLines(autojoinFile().toPath(),
                    StandardCharsets.UTF_8)) {
                final int tab = l.indexOf('\t');
                if (tab <= 0) {
                    continue;   // a torn line
                }
                try {
                    ids.put(Integer.parseInt(l.substring(0, tab)), l.substring(tab + 1));
                } catch (NumberFormatException ignored) {
                    // a torn line
                }
            }
        } catch (IOException e) {
            // none yet
        }
        return ids;
    }

    /** Record (ssid non-null) or forget that this app turned a network's auto-join off. */
    private void autojoinOff(int netId, String ssid) {
        final Map<Integer, String> ids = autojoinOffMap();
        if (ssid != null ? ssid.equals(ids.put(netId, ssid)) : ids.remove(netId) == null) {
            return;
        }
        mAutojoinOff = ids;
        final File f = autojoinFile();
        final File tmp = new File(f.getPath() + ".tmp");
        final StringBuilder b = new StringBuilder();
        for (Map.Entry<Integer, String> e : ids.entrySet()) {
            b.append(e.getKey()).append('\t').append(e.getValue()).append('\n');
        }
        try {
            Files.write(tmp.toPath(), b.toString().getBytes(StandardCharsets.UTF_8));
            if (!tmp.renameTo(f)) {
                Log.e(TAG, "cannot rename " + tmp + " to " + f);
            }
        } catch (IOException e) {
            Log.e(TAG, "cannot write " + tmp, e);
        }
    }

    /**
     * Turn the network's auto-join on again if this app turned it off -- only while the
     * netId still names a network of that SSID: a netId is handed out again once its
     * network is forgotten, and the new one's auto-join is the user's.
     */
    private boolean restoreAutojoin(int netId) {
        final String ssid = autojoinOffMap().get(netId);
        if (ssid == null) {
            return false;
        }
        final List<WifiConfiguration> configs = mWifi.getConfiguredNetworks();
        if (configs == null || configs.isEmpty()) {
            return false;   // not loaded yet (early in a boot): the record stays
        }
        // The record goes once the netId is looked at: back on, or no longer that
        //   SSID's (forgotten, its netId handed out again).
        autojoinOff(netId, null);
        for (WifiConfiguration c : configs) {
            if (c != null && c.networkId == netId && ssid.equals(unquote(c.SSID))) {
                mWifi.allowAutojoin(netId, true);
                Log.i(TAG, "netId=" + netId + ": auto-join on again");
                return true;
            }
        }
        return false;
    }

    /**
     * At the start of this service (see {@link #AUTOJOIN_OFF}); again at each sweep until
     * the saved networks have been read, which they may not be yet so early in a boot.
     */
    private void restoreAllAutojoin() {
        if (!mRestoreAtStart) {
            return;
        }
        final List<WifiConfiguration> configs = mWifi.getConfiguredNetworks();
        if (configs == null || configs.isEmpty()) {
            return;
        }
        mRestoreAtStart = false;
        for (int id : autojoinOffMap().keySet()) {
            restoreAutojoin(id);
        }
    }

    /** {@link #restoreAllAutojoin} has yet to run with the saved networks read. */
    private boolean mRestoreAtStart = true;

    /**
     * DomD has the SSID while no repair is waiting: a network of it this app left held
     * back (a join that took longer than DomD's answer, which DomD then completed, or a
     * restart of hostapd that came late) is connected now, with auto-join on again.
     */
    private void connectHeldBack(String ssid) {
        int first = -1;
        for (Map.Entry<Integer, String> e : autojoinOffMap().entrySet()) {
            if (ssid.equals(e.getValue()) && restoreAutojoin(e.getKey()) && first == -1) {
                first = e.getKey();
            }
        }
        // Auto-join on again for each, a connect for one: a second would replace it.
        if (first != -1) {
            Log.i(TAG, "DomD has " + ssid + "; connecting netId=" + first
                    + ", held back since its repair");
            connectAfterScan(first, ssid);
        }
    }

    private static final String CH_STATUS = "doma_wifi_status";
    private static final String CH_FAILURE = "doma_wifi_failure";
    /** One notification, replaced by each report: only the latest join matters. */
    private static final int NOTE_ID = 1;
    /** A "connecting" goes after this long: DomD's agent answers a connect in 75 s at
     *  most (a 30 s join, then up to 6 DHCP tries), and a lost answer must not leave it. */
    private static final long CONNECTING_TIMEOUT_MS = 90_000;
    private static final long CONNECTED_TIMEOUT_MS = 10_000;
    private static final long FAILED_TIMEOUT_MS = 300_000;

    /**
     * Show what DomD's real join is doing, as one notification for every user. This
     * service runs as the system user only (see onCreate), which is headless on AAOS, so
     * the notification is posted to {@link UserHandle#ALL} -- posted to the system user
     * it would never reach the driver. A failure opens the Wi-Fi settings on a tap, for
     * the current user (a plain PendingIntent made here would start them as the
     * system user). The app is uid system, which holds
     * POST_NOTIFICATIONS without asking (PermissionManager.checkPermission grants
     * SYSTEM_UID unconditionally).
     *
     * @param kind {@link #STATE}'s first field
     * @param ssid its third field, empty if there is none
     */
    private void notifyState(String kind, String ssid) {
        if (mNm == null) {
            return;
        }
        if ("up".equals(kind)) {
            // The daemon (re)started: a connect it had forwarded will not be answered
            // to it. Not while a repair still waits (onWaitState): its answer comes.
            if (mWait == null) {
                mNm.cancelAsUser(null, NOTE_ID, UserHandle.ALL);
            }
            return;
        }
        if (ssid.isEmpty()) {
            return;  // nothing to name
        }
        // offline:retry: DomD failed an earlier connect for the SSID and the later one
        // is still under way, so it is still "connecting" -- posted again, which also
        // starts its timeout again (two connects in a row are answered one after the
        // other, which can take longer than one timeout).
        final boolean connecting = "pending".equals(kind) || "offline:retry".equals(kind);
        final String title;
        String text = null;
        final boolean failure;
        final long timeout;
        if (connecting) {
            title = getString(R.string.connecting, ssid);
            text = getString(R.string.connecting_text);
            failure = false;
            timeout = CONNECTING_TIMEOUT_MS;
        } else if ("online".equals(kind)) {
            title = getString(R.string.connected, ssid);
            failure = false;
            timeout = CONNECTED_TIMEOUT_MS;
        } else if ("offline:lost".equals(kind)) {
            title = getString(R.string.lost, ssid);
            text = getString(R.string.lost_text);
            failure = true;
            timeout = FAILED_TIMEOUT_MS;
        } else if (kind.startsWith("offline:")) {
            title = getString(R.string.failed, ssid);
            text = getString(failureText(kind.substring("offline:".length())));
            failure = true;
            timeout = FAILED_TIMEOUT_MS;
        } else {
            return;  // a bare "offline" (an older daemon) says too little to show
        }
        final Notification.Builder b = new Notification.Builder(this,
                failure ? CH_FAILURE : CH_STATUS)
                .setSmallIcon(failure ? android.R.drawable.stat_sys_warning : R.drawable.ic_wifi)
                .setContentTitle(title)
                .setOnlyAlertOnce(!failure)
                .setOngoing(connecting)
                .setTimeoutAfter(timeout)
                .setCategory(failure ? Notification.CATEGORY_ERROR : Notification.CATEGORY_STATUS);
        if (failure) {
            // A tap opens the Wi-Fi settings, for the current (driver) user: this app runs
            //   as the system user, which has no screen on this headless product.
            b.setContentIntent(PendingIntent.getActivityAsUser(this, 0,
                    new Intent(Settings.ACTION_WIFI_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                                    | Intent.FLAG_ACTIVITY_CLEAR_TOP),
                    PendingIntent.FLAG_IMMUTABLE, null, UserHandle.CURRENT))
                    .setAutoCancel(true);
        }
        if (text != null) {
            b.setContentText(text);
            b.setStyle(new Notification.BigTextStyle().bigText(text));
        }
        mNm.notifyAsUser(null, NOTE_ID, b.build(), UserHandle.ALL);
    }

    private static int failureText(String reason) {
        switch (reason) {
            case "not-found":
                return R.string.reason_not_found;
            case "wrong-key":
                return R.string.reason_wrong_key;
            case "rejected":
                return R.string.reason_rejected;
            case "timeout":
                return R.string.reason_timeout;
            default:
                return R.string.reason_error;
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
        restoreAllAutojoin();
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
        if (!configs.isEmpty()) {
            // A refused pair of an SSID no longer saved goes (see REFUSED).
            final Set<String> saved = new HashSet<>();
            for (WifiConfiguration c : configs) {
                final String pre = c == null ? null : refusedPrefix(unquote(c.SSID));
                if (pre != null) {
                    saved.add(pre);
                }
            }
            refusedRetain(e -> saved.contains(e.substring(0, e.indexOf('\t') + 1)));
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
            if (mWait != null && mWait.key.equals(key)) {
                // Tapped while DomD is still trying it: the local handshake failed on the
                // placeholder. Held back again, without a second request.
                Log.i(TAG, "netId=" + c.networkId + " is waiting for DomD; held back again");
                mWifi.enableNetwork(c.networkId, false);
                cancelFrameworkWrongPassword();
                continue;
            }
            if (!mAttempted.contains(key)
                    && refusedSet().contains(refusedEntry(ssid, psk))) {
                // DomD refused this very passphrase before this process (a reboot):
                //   a new password is a new pair, and forget+re-add drops the entry.
                Log.i(TAG, "netId=" + c.networkId + ": DomD refused this passphrase before;"
                        + " left to the user");
                mAttempted.add(key);
                continue;
            }
            if (mAttempted.contains(key)) {
                Log.i(TAG, "already attempted netId=" + c.networkId + "; leaving disabled");
                continue;
            }
            if (!repair(c, ssid, psk, key)) {
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
        refusedForget(unquote(wi.getSSID()));
        restoreAutojoin(wi.getNetworkId());
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
    private boolean repair(final WifiConfiguration c, String ssid, String psk,
            final String key) {
        final int netId = c.networkId;
        if (requestPending()) {
            Log.w(TAG, "a request is still unconsumed in " + REQ + "; the daemon is not"
                    + " reading it (" + PROP_RELAY_SVC_STATE + "=" + relaySvcState()
                    + "). Not attempting netId=" + netId + " -- attempt NOT spent."
                    + " Check: setprop persist.vendor.doma.wifi_relay true;"
                    + " logcat -s doma-wifi-relay");
            return false;
        }
        if (mWait != null) {
            Log.i(TAG, "netId=" + mWait.netId + " is still waiting for DomD; netId=" + netId
                    + " after it -- attempt NOT spent");
            return false;
        }
        Log.i(TAG, "repairing netId=" + netId + " ssid=" + ssid);
        final String token = String.format("%016x", mRandom.nextLong());
        final String[] st = readState();
        final String startSeq = st.length >= 2 ? st[1] : "";
        if (!writeRequest(ssid, psk, token)) {
            return false;
        }
        final Wait w = new Wait(netId, ssid, key, token, startSeq,
                refusedEntry(ssid, psk));
        mWait = w;
        holdBack(c);
        // The framework's "Failed to connect" from the placeholder's handshake, now and
        //   once more in case it is posted just after.
        cancelFrameworkWrongPassword();
        mHandler.postDelayed(() -> {
            if (mWait == w) {
                cancelFrameworkWrongPassword();
            }
        }, 1000);
        connectWhenConsumed(w, REQ_POLLS);
        return true;
    }

    /**
     * Wait for the daemon to handle the request, then for DomD's answer (up to
     * {@link #CONNECTING_TIMEOUT_MS}, see {@link #onWaitState}). If it never takes the
     * request, return the attempt to the pool instead of burning it.
     */
    private void connectWhenConsumed(final Wait w, final int polls) {
        mHandler.postDelayed(new Runnable() {
            @Override
            public void run() {
                if (w != mWait) {
                    return;     // answered already (a request the daemon dropped)
                }
                if (requestPending() || REQ_BUSY.exists()) {
                    if (polls > 1) {
                        connectWhenConsumed(w, polls - 1);
                        return;
                    }
                    Log.w(TAG, "daemon did not consume the request within "
                            + (REQ_POLLS * POLL_MS) + " ms ("
                            + PROP_RELAY_SVC_STATE + "=" + relaySvcState()
                            + "); not connecting netId=" + w.netId
                            + ". Check: logcat -s doma-wifi-relay");
                    finishWait(w, "unconsumed");
                    return;
                }
                Log.i(TAG, "the daemon has the request for netId=" + w.netId
                        + "; waiting for DomD");
                mHandler.postDelayed(mWaitTimeout, CONNECTING_TIMEOUT_MS);
            }
        }, POLL_MS);
    }

    /**
     * Write one tab-separated {@code psk#<token>} request line for the daemon.
     *
     * <p>Written to a temporary name and renamed, so the daemon can never read a partial
     * line: it polls for the final name only, and its own first action is to move the
     * file aside.
     */
    private boolean writeRequest(String ssid, String psk, String token) {
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
            w.write("psk#" + token + "\t" + ssid + "\t" + psk + "\n");
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
