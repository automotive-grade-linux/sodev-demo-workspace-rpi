#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# sodev-venus-gate.sh: the Vulkan/Venus feasibility gate for the RPi4/RPi5 cockpit.
#
# Runs the phase 0-3 checks of docs/VULKAN-VENUS.md on DomD (the domain that owns
# the real GPU and runs the guests' device models) and prints one verdict:
#
#   PASS -> the host side meets the Venus requirements; continue with the guest
#           integration (phases 4-A / 4-B).
#   FAIL -> a mandatory host requirement is missing; go to phase 5 (formalise the
#           virgl/GLES fallback) instead of starting guest work.
#
# Why a gate and not a checklist: DomU (AGL-IC) and DomA (AAOS) depend on exactly
# the same host-side properties, so answering this once is what decides whether
# either integration is worth starting.
#
# Usage (in the DomD console, as root):
#   sodev-venus-gate.sh                # all phases, then the verdict
#   sodev-venus-gate.sh --phase 1      # one phase only (0|1|2|3)
#   sodev-venus-gate.sh --no-weston    # skip phase 3's drawing test
#
# --no-weston skips the only check that PUTS SOMETHING ON THE SCREEN: phase 3 runs
# weston-simple-dmabuf-vulkan for ~8 s against the live cockpit compositor, and
# kiosk-shell routes an app-id it does not know to the default output -- so on a
# running cluster the display is covered for those 8 s. Use it when that is not
# acceptable; the verdict then loses phase 3 and nothing else.
#
# Exit status: 0 = PASS, 1 = FAIL (a mandatory requirement is missing),
#              2 = INCONCLUSIVE (a tool needed to decide is not installed).

set -u

PHASE="all"
RUN_WESTON=1
while [ $# -gt 0 ]; do
    case "$1" in
        --phase)     PHASE="${2:-all}"; shift ;;
        --no-weston) RUN_WESTON=0 ;;
        # Print the header comment block, not a hardcoded line range: the range
        # goes stale the moment the header is edited.
        -h|--help)   awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 0 ;;
        *)           echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

# A typo'd phase would select no checks at all, and the verdict at the bottom would
# then print PASS and exit 0 -- the worst possible failure for a script whose only
# job is to say PASS or FAIL. Constrain the value, and count the deciding checks so
# "nothing ran" can never read as "everything passed".
case "$PHASE" in
    all|0|1|2|3) ;;
    *) echo "ERROR: --phase must be one of 0, 1, 2, 3 or all (got '$PHASE')" >&2; exit 2 ;;
esac
DECIDED=0

# The device models reach weston through XDG_RUNTIME_DIR=/run + wayland-0
# (xendriverdomain.service.d/hack-xdg_runtime_dir.conf). vulkaninfo needs the same
# environment: without it the Wayland WSI probe enumerates nothing and phase 1
# reports a FAIL that is really a missing env var.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

FAIL=0
INCONCLUSIVE=0
INCONCLUSIVE_WHY=""
# Set only when the missing tool is one the Venus lane installs, so the verdict does
# not tell someone to rebuild with --devel over a tool that has nothing to do with it
# (--phase 2 on a host without qemu, say).
NEED_VENUS_PKGS=0

hdr()  { echo; echo "=== $* ==="; }
ok()   { echo "  [ ok ]   $*"; DECIDED=$(( DECIDED + 1 )); }
bad()  { echo "  [FAIL]   $*"; FAIL=1; DECIDED=$(( DECIDED + 1 )); }
# skip() = "cannot decide": it makes the verdict INCONCLUSIVE. Used only in the
# deciding phases; phase 0 is informational and uses note() for the same situation.
skip() { echo "  [ ??? ]  $*"; INCONCLUSIVE=1; DECIDED=$(( DECIDED + 1 )); INCONCLUSIVE_WHY="${INCONCLUSIVE_WHY}
    - $*"; }
note() { echo "           $*"; }

have() { command -v "$1" >/dev/null 2>&1; }

want_phase() { [ "$PHASE" = "all" ] || [ "$PHASE" = "$1" ]; }

# ---------------------------------------------------------------- phase 0
# Baseline: what is running now. Nothing here can fail the gate; the values are
# what a later comparison (guest vs host, pre- vs post-migration) is read against.
if want_phase 0; then
    hdr "Phase 0: baseline"

    if have qemu-system-aarch64; then
        # NB: /usr/bin/qemu-system-aarch64 is the image's wrapper script (it sets
        # SDL_VIDEO_WAYLAND_WMCLASS and LD_PRELOAD before exec'ing .bin), so this
        # reports the wrapped binary's version, which is the one that matters.
        note "qemu:          $(qemu-system-aarch64 --version 2>/dev/null | head -1)"
    else
        note "qemu:          not installed (is this DomD?)"
    fi

    # The glob is unquoted so it expands; if it matches nothing bash leaves the
    # pattern itself, which -e rejects. Say so rather than printing nothing: a
    # silent line here reads as "not checked" when it means "not installed".
    virgl_found=0
    for so in /usr/lib/libvirglrenderer.so.*; do
        if [ -e "$so" ]; then note "virglrenderer: $so"; virgl_found=1; fi
    done
    [ "$virgl_found" = 0 ] && note "virglrenderer: not installed (is this DomD?)"

    if [ -e /dev/dri/card0 ] || [ -e /dev/dri/renderD128 ]; then
        note "drm nodes:     $(ls /dev/dri 2>/dev/null | tr '\n' ' ')"
    else
        note "drm nodes:     none -- the GPU is not bound in this domain"
    fi

    note "GL baseline is measured separately (glmark2 in the guests); record it"
    note "before changing anything, so a Venus number has something to beat."
fi

# ---------------------------------------------------------------- phase 1
# The gate proper. Venus bridges to the host ICD through the standard loader, but
# it cannot work on a driver without VK_EXT_image_drm_format_modifier, and its
# blob resources need udmabuf on the host.
if want_phase 1; then
    hdr "Phase 1: host V3DV requirements for Venus"

    if have vulkaninfo; then
        VKINFO="$(vulkaninfo 2>/dev/null)"
        if [ -z "$VKINFO" ]; then
            bad "vulkaninfo produced no output -- no usable Vulkan device on the host"
            note "check that mesa-vulkan-drivers is installed (the V3DV ICD) and that"
            note "/usr/share/vulkan/icd.d contains its manifest"
        else
            DRV="$(printf '%s\n' "$VKINFO" | grep -m1 -i 'driverName' | sed 's/.*= *//')"
            API="$(printf '%s\n' "$VKINFO" | grep -m1 -i 'apiVersion' | sed 's/.*= *//')"
            [ -n "$DRV" ] && note "driverName:    $DRV"
            [ -n "$API" ] && note "apiVersion:    $API"

            # The mandatory one. Mesa's Venus does not work on a driver that does
            # not implement it, so this single line decides the whole programme.
            if printf '%s\n' "$VKINFO" | grep -qi 'VK_EXT_image_drm_format_modifier'; then
                ok "VK_EXT_image_drm_format_modifier present"
            else
                bad "VK_EXT_image_drm_format_modifier NOT present"
                note "Venus cannot work on this driver. Go to phase 5 and raise the"
                note "extension as an upstream (Mesa/Igalia) request separately."
            fi
        fi
    else
        NEED_VENUS_PKGS=1
        skip "vulkaninfo not installed (vulkan-tools)"
    fi

    # udmabuf: the host-side backing for blob resources.
    if [ -e /dev/udmabuf ]; then
        ok "/dev/udmabuf present"
    else
        bad "/dev/udmabuf missing"
        # Three outcomes, not two. With only "=y" and "else", a kernel with no
        # readable config -- the COMMON case, since CONFIG_IKCONFIG_PROC is off
        # by default and Yocto images ship no /boot/config-* -- would be
        # reported as "CONFIG_UDMABUF is not enabled", an assertion the script
        # has no evidence for.
        KCFG=""
        if zcat /proc/config.gz 2>/dev/null | head -1 >/dev/null 2>&1 &&
           zcat /proc/config.gz 2>/dev/null | grep -q 'CONFIG_'; then
            KCFG="$(zcat /proc/config.gz 2>/dev/null)"
        elif [ -r "/boot/config-$(uname -r)" ]; then
            KCFG="$(cat "/boot/config-$(uname -r)")"
        fi
        if [ -z "$KCFG" ]; then
            note "cannot tell whether CONFIG_UDMABUF is set: no readable kernel config"
            note "(no /proc/config.gz -- that needs CONFIG_IKCONFIG_PROC -- and no"
            note "/boot/config-$(uname -r)). Check the config in the build tree instead:"
            note "the Raspberry Pi kernel's own defconfigs (bcm2712 and"
            note "bcm2711) set it =y, so a missing node here is more likely"
            note "devtmpfs or permissions."
        elif printf '%s\n' "$KCFG" | grep -q '^CONFIG_UDMABUF=y'; then
            note "CONFIG_UDMABUF=y in this kernel, so the node should exist -- check"
            note "for a devtmpfs/permission problem rather than a config problem."
        else
            note "CONFIG_UDMABUF is not enabled in this kernel, which is unexpected:"
            note "the Raspberry Pi kernel's own defconfig sets it (=y at line"
            note "1489 of bcm2712_defconfig and 1487 of bcm2711_defconfig in"
            note "6.18.33), and that is the defconfig this build starts from."
            note "Check for a local kernel config change before anything else."
        fi
    fi
fi

# ---------------------------------------------------------------- phase 2
# Did the QEMU move actually produce a Venus-capable device model? This is a
# runtime question, not a version question: the property only exists if qemu was
# both new enough AND built against a virglrenderer with venus.
if want_phase 2; then
    hdr "Phase 2: is this qemu a Venus build"

    if have qemu-system-aarch64; then
        GPUHELP="$(qemu-system-aarch64 -device virtio-gpu-gl,help 2>&1)"
        if printf '%s\n' "$GPUHELP" | grep -q 'venus'; then
            ok "virtio-gpu-gl has a venus property"
            printf '%s\n' "$GPUHELP" | grep -E 'venus|blob|hostmem' | sed 's/^/           /'
        else
            bad "virtio-gpu-gl has no venus property"
            note "venus= arrived in QEMU 9.2.0. This tree pins 7.0.0 unless"
            note "GPU=vulkan selects the 11.1.2 build. If the version is"
            note "already >= 9.2, qemu was built without a venus-capable"
            note "virglrenderer -- check the virglrenderer PACKAGECONFIG."
        fi
    else
        skip "qemu-system-aarch64 not installed"
    fi
fi

# ---------------------------------------------------------------- phase 3
# Native Vulkan on the host, before any guest is involved: if weston's own Vulkan
# renderer cannot come up on V3DV here, a guest reaching the same ICD over Venus
# certainly will not. oe-core's vulkan-tools is built with -DBUILD_CUBE=OFF, so
# there is no vkcube to draw with; weston 15's renderer is the substitute.
if want_phase 3; then
    hdr "Phase 3: native Vulkan rendering on the host"

    for c in weston-simple-dmabuf-vulkan weston-simple-vulkan weston-simple-egl; do
        have "$c" && note "client available: $c"
    done

    if [ "$RUN_WESTON" = 0 ]; then
        note "--no-weston: skipping the compositor check"
    elif [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && have weston-simple-dmabuf-vulkan; then
        # PREFERRED PATH: a Vulkan CLIENT against the compositor that is already
        # running. This needs no second compositor, no display change and no
        # headless backend -- and this image's weston has no headless backend at
        # all (PACKAGECONFIG is "kms wayland egl clients ... vulkan", no
        # 'headless'), so a `weston --backend=headless` probe could only ever
        # fail here, and would report that failure as if Vulkan were broken.
        # Measured on the built rootfs:
        # only drm-backend.so and wayland-backend.so are installed.
        #
        # weston-simple-dmabuf-vulkan renders with Vulkan and hands the result over
        # as a dmabuf, which is the closest thing on the host side to what Venus
        # needs. If Vulkan or the ICD were broken the client exits at once.
        CL=weston-simple-dmabuf-vulkan
        LOG="$(mktemp /tmp/venus-gate-client.XXXXXX)"
        timeout 12 "$CL" > "$LOG" 2>&1 &
        CPID=$!
        sleep 8
        if kill -0 "$CPID" 2>/dev/null; then
            ok "$CL kept running against the live compositor (Vulkan + dmabuf work)"
            kill "$CPID" 2>/dev/null; wait "$CPID" 2>/dev/null
            # Nothing printed it, so nothing needs it. Kept on every failure
            # branch below, which tells the reader to go and read it.
            rm -f "$LOG"
        else
            wait "$CPID" 2>/dev/null
            bad "$CL exited early -- host Vulkan rendering is not working"
            tail -12 "$LOG" 2>/dev/null | sed 's/^/           /'
        fi
    elif [ -e /usr/lib/libweston-15/headless-backend.so ] || [ -e /usr/lib/libweston/headless-backend.so ]; then
        # FALLBACK, only if this image actually has the headless backend: a
        # throwaway compositor on its own socket. Judged on weston's SUCCESS-ONLY
        # line -- "vulkan" appears in the log on failure paths too (the pre-check
        # lines at vulkan-renderer.c:3786/:4411, and the dlerror text at
        # compositor.c:10440).
        WST_OK='Using Vulkan renderer'
        WST_BAD='Unable to find a suitable physical device|DRM format modifiers not supported|Failed to load module'
        LOG="$(mktemp /tmp/venus-gate-weston.XXXXXX)"
        timeout 20 weston --backend=headless --renderer=vulkan \
            --socket=venus-gate-wl --log="$LOG" >/dev/null 2>&1 &
        WPID=$!
        for _i in $(seq 1 24); do
            grep -q "$WST_OK" "$LOG" 2>/dev/null && break
            grep -qE "$WST_BAD" "$LOG" 2>/dev/null && break
            kill -0 "$WPID" 2>/dev/null || break
            sleep 0.5
        done
        WST_ALIVE=0; kill -0 "$WPID" 2>/dev/null && WST_ALIVE=1
        kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
        if grep -q "$WST_OK" "$LOG" 2>/dev/null && [ "$WST_ALIVE" = 1 ]; then
            ok "weston brought up its Vulkan renderer and stayed up (\"$WST_OK\")"
            grep -iE 'vulkan device|v3d|broadcom' "$LOG" 2>/dev/null | head -6 | sed 's/^/           /'
        elif grep -q "$WST_OK" "$LOG" 2>/dev/null; then
            # SURVIVAL IS PART OF THE VERDICT, not decoration. weston prints
            # "Using Vulkan renderer" BEFORE it imports the KMS framebuffer, and
            # that import can abort it: measured on a PC over Venus, weston logged
            # the line, then vkGetMemoryResourcePropertiesMESA failed and weston
            # died with SIGABRT ~6 s in, socket never appearing. A check that
            # grepped only for the line would have called that a pass.
            # (Root cause of that particular abort: virglrenderer built without
            # minigbm_allocation, so the framebuffer could not be exported as a
            # dma-buf and never reached the venus context -- fixed in this tree by
            # the minigbm_allocation PACKAGECONFIG; see docs/VULKAN-VENUS.md
            # section 5b. The survival check stays
            # regardless: no verdict here may report a dead compositor as success.)
            bad "weston logged \"$WST_OK\" and then DIED -- the renderer did not survive"
            note "log: $LOG"; tail -12 "$LOG" 2>/dev/null | sed 's/^/           /'
            note "if this is vkGetMemoryResourcePropertiesMESA, it is the Venus"
            note "framebuffer-import failure -- gate on a Vulkan CLIENT instead."
        elif grep -qE "$WST_BAD" "$LOG" 2>/dev/null; then
            bad "weston rejected the Vulkan renderer"
            grep -nE "$WST_BAD" "$LOG" | head -3 | sed 's/^/           /'
            note "\"DRM format modifiers not supported\" here means the same thing as a"
            note "phase-1 failure: the driver lacks VK_EXT_image_drm_format_modifier."
        elif [ "$WST_ALIVE" = 0 ]; then
            bad "weston exited before its Vulkan renderer came up"
            note "log: $LOG"; tail -12 "$LOG" 2>/dev/null | sed 's/^/           /'
        else
            skip "weston stayed up but logged neither success nor a known failure"
            note "log: $LOG -- read it by hand"
        fi
    else
        skip "no live compositor socket and no headless backend -- cannot draw here"
        note "start the cockpit compositor (weston.service) and rerun, or install a"
        note "weston built with the 'headless' PACKAGECONFIG."
    fi

    note "Guest-side equivalent, once a Venus guest boots:  vulkaninfo --summary"
    note "(expect a virtio/venus device). vkmark has no recipe in the pinned"
    note "layers; treat any benchmark number as an out-of-tree manual step."
fi

# ---------------------------------------------------------------- verdict
hdr "Verdict"
if [ "$FAIL" != 0 ]; then
    echo "  FAIL -- a mandatory host-side requirement is missing."
    echo "  Do NOT start the DomU/DomA integration. Go to phase 5 of"
    echo "  docs/VULKAN-VENUS.md and formalise the virgl (GLES) fallback."
    exit 1
fi
if [ "$INCONCLUSIVE" != 0 ]; then
    echo "  INCONCLUSIVE -- something needed to decide is not installed:${INCONCLUSIVE_WHY}"
    if [ "$NEED_VENUS_PKGS" != 0 ]; then
        echo "  Rebuild with ./build.sh --devel (the default lane is already Vulkan),"
        echo "  which installs"
        echo "  mesa-vulkan-drivers / vulkan-loader / vulkan-tools into DomD, and rerun."
    else
        echo "  Install it (or run this on DomD, which is where the GPU and the"
        echo "  device models are) and rerun."
    fi
    exit 2
fi
if [ "$DECIDED" = 0 ]; then
    echo "  INCONCLUSIVE -- no check actually ran (phase '$PHASE')."
    echo "  Nothing was decided, so this is not a pass."
    exit 2
fi
echo "  PASS -- the host side meets the Venus requirements."
echo "  Continue with phase 4-A (DomA) / 4-B (DomU) of docs/VULKAN-VENUS.md."
echo
echo "  Remaining risk, unproven by this script: host-visible blob resources map"
echo "  host memory into the guest through the virtio-gpu PCI BAR, and this"
echo "  platform has no IOMMU, uses grant-based virtio DMA, and runs the device"
echo "  model in DomD. That is where a regression would show up first."
exit 0
