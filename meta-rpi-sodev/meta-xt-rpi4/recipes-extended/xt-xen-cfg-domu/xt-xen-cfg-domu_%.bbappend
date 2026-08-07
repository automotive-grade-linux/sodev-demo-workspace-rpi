# RPi4: pin DomU's vcpu to pcpu 2 instead of pcpu 1.
#
# WHY
# The shared domu.cfg pins DomU to pcpu 1, and its comment states the intent:
# "DomU -> pcpu 1 (shares cpu1 with DomD; AAOS gets 2-3, Dom0 gets 0)". On this
# RPi4 bench there is no DomA/AAOS yet, so that layout left DomU sharing one core
# with BOTH of DomD's vcpus while pcpu 2 and 3 sat completely idle -- measured
# 2026-08-04 with `xl vcpu-list` sampling:
#
#   Domain-0    vcpu0  pcpu 0     1.7%     hard affinity 0
#   dom0less-1  vcpu0  pcpu 0-1  31.9%     hard affinity 0-1
#   dom0less-1  vcpu1  pcpu 0-1  33.9%
#   DomU        vcpu0  pcpu 1    60.3%     hard affinity 1   <-- contended
#   (pcpu 2, pcpu 3: no vcpu can ever run there)
#
# MEASURED EFFECT (do not over-claim this: it is small)
#   DomU CPU (Xen view)      60.3% -> 65.5%
#   DomU steal (guest view)  37.6% -> 33.0%
#   DomD steal                3.6% ->  0.5%
#   V3D render occupancy     78.3% -> 83.6%
#   frame rate (commit/paint)  20/17 -> 21/18
# So this mainly cleans up DomD's steal and hands the slack to the GPU. DomU's
# remaining ~33% "steal" is NOT pcpu contention -- it persists with DomU alone on
# a core -- see review/FIX-STATUS.md. Do not expect this change to fix frame rate.
#
# G4 CONSEQUENCE -- READ BEFORE ADDING DomA
# pcpu 2-3 are the cores the upstream layout reserves for AAOS. With this append,
# a 4-domain bring-up puts DomU and DomA on the same core unless DomA is moved to
# 3 only (doma.cfg `cpus`). Revisit both files together at G4; do not discover
# this by watching the two guests thrash.
#
# NOTE: no backticks anywhere below. In a bb shell function a backtick is command
# substitution even inside a bbfatal message string, so "re-derive it from
# `xl vcpu-list`" would try to RUN xl on the build host.

RPI4_DOMU_CPUS_FROM ?= 'cpus = "1"'
RPI4_DOMU_CPUS_TO ?= 'cpus = "2"'

do_install[postfuncs] += "rpi4_domu_cpu_pin"
do_install[vardeps] += "RPI4_DOMU_CPUS_FROM RPI4_DOMU_CPUS_TO"

rpi4_domu_cpu_pin() {
    cfg="${D}${sysconfdir}/xen/domu.cfg"
    if [ ! -f "$cfg" ]; then
        bbfatal "xt-xen-cfg-domu.bbappend (rpi4): $cfg not installed"
    fi

    # Refuse to guess. Silently doing nothing here would leave the board running
    # the upstream pinning while every note claims otherwise.
    if ! grep -qxF '${RPI4_DOMU_CPUS_FROM}' "$cfg"; then
        if grep -qxF '${RPI4_DOMU_CPUS_TO}' "$cfg"; then
            bbnote "xt-xen-cfg-domu.bbappend (rpi4): DomU already pinned to pcpu 2"
            return
        fi
        bbfatal "xt-xen-cfg-domu.bbappend (rpi4): expected '${RPI4_DOMU_CPUS_FROM}' in \
$cfg. Upstream changed the pinning -- re-derive the CPU map with 'xl vcpu-list' on \
the board before touching this."
    fi

    sed -i 's|^${RPI4_DOMU_CPUS_FROM}$|${RPI4_DOMU_CPUS_TO}|' "$cfg"

    n=$(grep -cxF '${RPI4_DOMU_CPUS_TO}' "$cfg")
    if [ "$n" != "1" ]; then
        bbfatal "xt-xen-cfg-domu.bbappend (rpi4): expected exactly one \
'${RPI4_DOMU_CPUS_TO}' after the sed, found $n in $cfg"
    fi
    if grep -qxF '${RPI4_DOMU_CPUS_FROM}' "$cfg"; then
        bbfatal "xt-xen-cfg-domu.bbappend (rpi4): '${RPI4_DOMU_CPUS_FROM}' still present in $cfg"
    fi
    bbnote "xt-xen-cfg-domu.bbappend (rpi4): DomU vcpu pinning -> ${RPI4_DOMU_CPUS_TO}"
}
