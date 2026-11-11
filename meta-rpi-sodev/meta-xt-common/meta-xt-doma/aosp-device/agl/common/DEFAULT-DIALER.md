<!-- SPDX-License-Identifier: Apache-2.0 -->
# DomA: no incoming-call screen and no ringtone over Bluetooth HFP

Root cause, measured on the RPi5 board on 2026-09-21 with a phone paired over
HFP.

## Symptom

Incoming call on the paired phone: no incoming-call screen on the head unit, no
ringtone, no call audio. A2DP music playback worked.

## The chain

`PermissionController/res/xml/roles.xml`:

    <role name="android.app.role.DIALER" ... defaultHolders="config_defaultDialer">

`frameworks/base/core/res/res/values/config.xml:2523`:

    <string name="config_defaultDialer" translatable="false">com.android.dialer</string>

`com.android.dialer` is the phone-form-factor app and is not installed on this
build; the installed one is `com.android.car.dialer`. Nothing overrides the string
(zero hits for `config_defaultDialer` under `packages/services/Car/car_product`), so
the DIALER role is left with no holder at all.

## Measurements before the fix

    # cmd role get-role-holders --user 10 android.app.role.DIALER
    (empty)
    # cmd telecom get-default-dialer
    null

Telecom itself was healthy. `dumpsys telecom` showed the call reaching:

    CREATED -> BIND_CS (HfpClientConnectionService) -> CS_BOUND -> START_CONNECTION
    -> FILTERING_INITIATED -> BLOCK_CHECK_FINISHED (not blocked)
    -> SET_RINGING (successful incoming call) -> FILTERING_COMPLETED

but `combinedInCallServiceMap (InCalls registered):` stayed EMPTY, there was no
`BIND_IN` event for the whole call, and logcat carried the decisive line:

    Telecom : InCallController: doesConnectedDialerSupportRinging:
              no default dialer found; oh no!

That method is also what decides whether to ring, which is why the ringtone was
missing for the same reason as the screen.

## Confirmation

Setting the holder at runtime:

    cmd role add-role-holder --user 10 android.app.role.DIALER com.android.car.dialer

made the incoming-call screen appear on the very next call, with
`com.android.car.carlauncher` and
`com.android.systemui.car.telecom.InCallServiceImpl` both bound for the call's full
15.2 s and released on disconnect.

## What was NOT the cause

All of these were already correct and present, and none of them needed changing:

* `packages/modules/Bluetooth` HFP client patches (`config.xml` A2DP focus,
  `HeadsetClientStateMachine`, `client_interface_aidl.cc`, `hfp_client_interface_aidl.cc`,
  `bta_hf_client_int.h`, `bta_hf_client_sco.cc`)
* `frameworks/base` `BtHelper.java` HF-role gate (`sHfClientRole`)
* `packages/services/Car` `CarAudioService.java` HFP SCO bridge
* the three sysprops: `bluetooth.profile.hfp.hf.enabled`,
  `bluetooth.hfp.software_datapath.enabled`, `bluetooth.sco.managed_by_audio`
* the audio policy XMLs

## Note on call audio

No SCO link is expected until the call is answered ON THE HEAD UNIT. The call used
for the measurement above ended as `LOG_CALL (... code=MISSED)`, and
`CallAudioRouteController` correctly reported `isScoConnected=false` throughout.
Answering on the phone keeps the audio on the phone. Verify call audio by answering
on the AAOS screen, which was impossible before this fix because no screen appeared.

## Not an RPi4 to RPi5 porting miss

The Pi 4 product has the same gap. Its records contain no incoming-call-screen
verification at all, so the defect was simply never reached there. The string
names no board and no hardware, so the overlay lives in `device/agl/common/overlay`
and the Raspberry Pi 5 product gets it from the root it already names; the Raspberry
Pi 4 device carries the same overlay in its own repository.

## Latent, not fixed here

`dumpsys telecom` reports:

    System Dialer: ComponentInfo{com.android.dialer/
                   com.android.car.dialer.telecom.InCallServiceImpl}

Telecom builds that from its own `ui_default_package` + `incall_default_class`, and
the car RRO (`com.android.server.telecom.car.config.rro`, verified STATE_ENABLED)
overrides only the class. That component serves the system/emergency dialer path,
not ordinary InCallService binding, so it did not block this fix. It belongs to
Telecom's RRO rather than to framework-res.
