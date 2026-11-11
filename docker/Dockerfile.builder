# SPDX-License-Identifier: Apache-2.0
# Single build image for the whole sodev-demo-workspace-rpi workspace.
#
#   docker build -f docker/Dockerfile.builder docker/ \
#     --build-arg USER_ID="$(id -u)" --build-arg USER_GID="$(id -g)" \
#     -t sodev-builder-rpi
#
# A single image for the whole workspace. It reconstructs the EPAM/xen-troops
# moulin/ninja build environment and folds in the AOSP host toolchain and the
# AGL bitbake host deps so one container can run every heavy build step:
# moulin + ninja (Dom0/DomD Yocto + Xen + Zephyr), the AOSP/AAOS (DomA) build,
# and the DomU AGL bitbake.
# V4H AGL SoDeV ships no moulin Dockerfile (it builds on the host); this image
# is the RPi5 project's docker-first equivalent (all-heavy-builds-in-docker),
# pinned to a known-good moulin revision.
#
# NOTE: the DomU AGL build historically ran in the AGL-official docker-worker
# (Ubuntu 20.04). AGL (scarthgap) bitbake host requirements are a subset of the
# Yocto host deps below and build on Ubuntu 22.04; to use the AGL-official image
# instead, pass AGL_DOCKER=<official-image> ./build.sh.
#
# Contents:
#   - moulin 0.28 (git pin) + ninja + west     -> orchestrator / Zephyr meta-tool
#   - Yocto (wrynose/scarthgap) host deps       -> Dom0/DomD + DomU AGL bitbake
#   - rouge image-builder deps                  -> userspace SD-image assembly
#       mtools/dosfstools (FAT), e2fsprogs (ext4), gpt-image (pure-python GPT),
#       android-sdk-libsparse-utils (simg2img) -> rouge's android_sparse writer.
#   - AOSP host toolchain (repo/bazel/JDK17 +   -> DomA (AAOS) build, run by the
#       multilib/ncurses/squashfs/... per          moulin `android` builder under
#       source.android.com host requirements)      ninja (repo sync + lunch + build).
#   - Zephyr SDK 1.0.1 (aarch64-zephyr-elf)     -> Zephyr Dom0 (DOM0_OS=zephyr).
#   - Python 3.12 (deadsnakes) + a 3.12 `west`  -> Zephyr 4.4+ requires >= 3.12
#       (cmake/modules/python.cmake). The Yocto/AOSP side keeps the distro
#       python3 (3.10); see the Python 3.12 layer below for why both exist.
#   - CMake 3.31 in the same venv               -> Zephyr 4.5 requires >= 3.28;
#       only `west` sees it (the distro cmake 3.22 stays for everything else).
FROM ubuntu:22.04

ARG USER_ID=1000
ARG USER_GID=1000
# No ENV for the proxy variables: that would bake them into the image, and with no
# proxy configured that means http_proxy is defined-but-EMPTY at run time -- which
# makes the AOSP `repo` launcher (`if "http_proxy" in os.environ:`) proxy through
# nothing and fail every fetch with "urlopen error no host given". They are Docker
# predefined build args, so `--build-arg http_proxy=...` still reaches the RUN steps
# below; build.sh passes them only when they have a value.
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC
ENV LANG=en_US.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        # base
        ca-certificates curl wget git gnupg locales sudo xz-utils \
        # Yocto (wrynose/scarthgap) + AGL bitbake host requirements
        gawk diffstat unzip texinfo gcc g++ build-essential chrpath socat cpio \
        bc bison flex libssl-dev debianutils iputils-ping rsync zip \
        python3 python3-pip python3-pexpect python3-git python3-jinja2 \
        python3-subunit python3-venv python3-mako python3-yaml \
        zstd lz4 file m4 \
        # rouge (moulin image builder) userspace tools
        ninja-build mtools dosfstools e2fsprogs \
        android-sdk-libsparse-utils \
        # AOSP / AAOS host requirements (source.android.com/setup/build/initializing)
        openjdk-17-jdk-headless ccache pkg-config \
        libncurses5-dev zlib1g-dev \
        libxml2-utils libxml-simple-perl libgl1-mesa-dev \
        gperf imagemagick libjpeg-dev libpng-dev libsdl1.2-dev \
        libwxgtk3.0-gtk3-dev squashfs-tools xsltproc fontconfig \
        # Zephyr build host tools
        cmake device-tree-compiler \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# 32-bit x86 libraries for the AOSP build; they only exist on amd64
RUN if [ "$(dpkg --print-architecture)" = amd64 ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            g++-multilib gcc-multilib libc6-dev-i386 lib32ncurses-dev lib32z1-dev \
        && rm -rf /var/lib/apt/lists/*; \
    fi

# Downgrade tar version to workaround fakeroot issue. Kept from upstream: a newer
# tar makes fakeroot fail during Yocto's do_package. Placed before the Zephyr
# python3.12/venv layer below; the order does not matter today, because nothing this
# image installs afterwards pulls tar in and there is no apt-get upgrade anywhere.
# `apt-mark hold` is added so that stops being a thing anyone has to remember: without
# it a future layer could quietly upgrade tar again and the fakeroot failure would come
# back with no trace of why. (--allow-change-held-packages above already assumed a hold
# that was not actually set.)
RUN apt-get update && apt-get install -y \
	--allow-downgrades \
	--allow-change-held-packages \
	tar=1.34+dfsg-1build3 \
    && apt-mark hold tar

# moulin 0.28 (known-good git pin; pulls gpt-image, pyyaml,
# mako, ...) + meson (AOSP host-tool build). west is not installed here: it lives in
# /opt/zephyr-venv below, and /usr/local/bin/west is the wrapper that runs it.
#
# Upstream also installed Zephyr's own python requirements here (pyelftools,
# pykwalify, packaging, anytree, intelhex, pyyaml, canopen) against the distro
# python3.10. They moved to /opt/zephyr-venv below, with the python3.12 that Zephyr
# 4.4 needs, so the line is gone. That also stops pip's PyYAML from shadowing the apt
# python3-yaml that moulin and bitbake use -- the collision that broke moulin once.
RUN pip3 install --no-cache-dir \
        "git+https://github.com/xen-troops/moulin@83e80587c4b1348714237d3ff53129857288a420" \
        'meson>=1.4.0' \
    && ln -sf /usr/local/bin/meson /usr/bin/meson

# Google repo + bazelisk (AOSP).
# Both are pinned to a release AND to the sha256 of the file that release published, so
# the image is deterministic and a download that is not the expected file fails the
# build instead of being installed. bazelisk itself only launches the bazel version
# each AOSP tree requests via .bazelversion. The `repo` launcher comes from a tag of
# git-repo's own gerrit (storage.googleapis.com/git-repo-downloads/repo is always the
# newest launcher, so that copy can neither be pinned nor checked; v2.71 is what it
# served when this pin was taken). The launcher only bootstraps: `repo init` clones
# the repo tool itself into .repo/repo from git-repo's `stable` branch, and
# REPO_SKIP_SELF_UPDATE=1, when exported, keeps that clone from moving at sync time
# (see build.sh / README).
ARG REPO_VERSION=v2.71
ARG BAZELISK_VERSION=v1.20.0
RUN curl -fsSL "https://gerrit.googlesource.com/git-repo/+/refs/tags/${REPO_VERSION}/repo?format=TEXT" \
        | base64 -d > /usr/local/bin/repo \
    && echo "05f571deafd6ed6da0d20fa707dde29aa5624dbf35553d697a40dbdd4c8d178a  /usr/local/bin/repo" \
        | sha256sum -c - \
    && chmod 0755 /usr/local/bin/repo \
    && arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
         amd64) bazelisk_sha=d9af1fa808c0529753c3befda75123236a711d971d3485a390507122148773a3 ;; \
         arm64) bazelisk_sha=467ec3821aca5e278c8570b7c25e0dfc1a061d2873be89e4a266aaf488148426 ;; \
         *) echo "no bazelisk sha256 pinned for $arch" >&2; exit 1 ;; \
       esac \
    && curl -fsSL -o /usr/local/bin/bazel \
        https://github.com/bazelbuild/bazelisk/releases/download/${BAZELISK_VERSION}/bazelisk-linux-${arch} \
    && echo "${bazelisk_sha}  /usr/local/bin/bazel" | sha256sum -c - \
    && chmod 0755 /usr/local/bin/bazel

# Python 3.12 for the Zephyr build only.
#
# Zephyr 4.4 and later set PYTHON_MINIMUM_REQUIRED 3.12 (cmake/modules/python.cmake) and
# Ubuntu 22.04 ships 3.10, so the Zephyr Dom0 build cannot use the distro python3.
# Yocto (wrynose/scarthgap) and the AOSP host tools, on the other hand, are only
# validated against the distro python3 here — so this does NOT replace python3;
# 3.12 is installed alongside it.
#
# The hand-off is `west`: python.cmake takes Python3_EXECUTABLE from WEST_PYTHON
# when it is not set explicitly, and `west build` passes the interpreter it is
# itself running under. Pointing /usr/local/bin/west at the 3.12 venv is therefore
# all it takes to move the whole Zephyr build onto 3.12. Nothing else changes:
# python3 and pip3 stay 3.10 and PATH is untouched. moulin DOES drive west (its
# zephyr builder runs `west build`), but it launches it as a subprocess and never
# imports it, so replacing west's interpreter is invisible to moulin and bitbake.
# Cost note: software-properties-common is only here for add-apt-repository, and it
# drags in ~50 packages (packagekit, polkit, gstreamer, appstream, gir bindings).
# They are inert in a build container - nothing runs as a daemon - but if the image
# size matters, replace this with a hand-written /etc/apt/sources.list.d entry plus
# the deadsnakes signing key and drop software-properties-common. Verified either
# way that no pre-existing package is removed or downgraded by this layer.
RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
        python3.12 python3.12-venv python3.12-dev \
    && rm -rf /var/lib/apt/lists/*

# Zephyr v4.5.0's scripts/requirements-base.txt, in its order, in a 3.12 virtualenv
# (west pinned, windows-curses left out). 4.5.0 raised requests to >=2.33.0 and
# added spdx-python-model (west spdx) and tabulate (hardenconfig) to that file.
#
# The venv is not optional. deadsnakes' python3.12 keeps /usr/lib/python3/dist-packages
# on its sys.path, i.e. it shares the *distro* package directory with python3.10.
# A plain `python3.12 -m pip install PyYAML` therefore finds the apt-installed
# PyYAML 5.4.1 there, uninstalls it, and writes 6.x into 3.12's own dist-packages —
# which silently removes yaml from python3.10 and breaks moulin
# ("ModuleNotFoundError: No module named 'yaml'"). Observed, not hypothetical.
#
# /usr/local/bin/west is the hand-off: `west build` reports its own interpreter as
# WEST_PYTHON, python.cmake adopts that as Python3_EXECUTABLE, and the venv is where
# Zephyr's python deps live. moulin and bitbake keep using the distro python3,
# untouched.
#
# CMake goes into the venv the same way. Zephyr 4.5 requires CMake 3.28
# (cmake/modules/zephyr_default.cmake) and Ubuntu 22.04 ships 3.22, but Yocto
# builds its own cmake-native and AOSP uses its prebuilts, so the distro cmake is
# left in place and the newer one is only visible to the Zephyr build. west finds
# cmake on PATH (scripts/west_commands/zcmake.py: shutil.which('cmake')), so
# /usr/local/bin/west is a two-line wrapper that puts the venv's bin first for west
# and its children, instead of a symlink. Nothing outside `west` sees the change.
#
# --retry rides out a flaky proxy. Kept as a LATE layer so it never invalidates the
# moulin git-install cache above.
RUN python3.12 -m venv /opt/zephyr-venv \
    && /opt/zephyr-venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/zephyr-venv/bin/pip install --no-cache-dir \
        'west==1.5.0' \
        'pyelftools>=0.29' 'PyYAML>=6.0' pykwalify jsonschema \
        canopen packaging 'patool>=2.0.0' 'psutil>=5.6.6' pylink-square \
        pyserial 'requests>=2.33.0' semver 'tqdm>=4.67.1' 'reuse>=6.0.0' \
        'spdx-python-model>=0.0.5' anytree tabulate intelhex \
        'cmake==3.31.6' \
    && printf '#!/bin/sh\nPATH=/opt/zephyr-venv/bin:$PATH exec /opt/zephyr-venv/bin/west "$@"\n' \
        > /usr/local/bin/west \
    && chmod 755 /usr/local/bin/west
# Make the failure mode described above impossible to repeat by hand: a bare
# `python3.12 -m pip install X` inside the container would again reach
# /usr/lib/python3/dist-packages and uninstall the distro package. Installs must go
# through a virtualenv (use /opt/zephyr-venv/bin/pip).
ENV PIP_REQUIRE_VIRTUALENV=1

# Zephyr SDK 1.0.1 (aarch64-zephyr-elf), which is what zephyr/SDK_VERSION asks for
# at Zephyr 4.5.0 (3.6 wanted 0.16.x). Two layout changes since 0.16:
#   - the toolchain tarball is named `toolchain_gnu_...`
#   - it must be unpacked under `gnu/`, not the SDK root. cmake/zephyr/gnu/generic.cmake
#     globs ${ZEPHYR_SDK_INSTALL_DIR}/gnu/*-*zephyr-* and fails with "Unable to find
#     'x86_64-zephyr-elf' or any other architecture" if the arch dir sits one level up.
# Both tarballs are checked against the sha256 the release publishes in its sha256.sum,
# for the two host architectures the image builds on.
ARG ZSDK=1.0.1
RUN cd /opt \
    && m="$(uname -m)" \
    && case "$m" in \
         x86_64)  sdk_sha=ca9bc0ff66fafca1dac9d592a36d953cf16d096a9d09b1c0357f021cf9f6a7eb \
                  gnu_sha=01c0cfe1daaab2d2a0f71165f11a066d983ef97e51c4a3753186afa6ae55c24b ;; \
         aarch64) sdk_sha=d79c5bfc68e679488659bea289a4026e52a64f03338875c8c9c850fff13cee30 \
                  gnu_sha=b3f217b7e099509e44d4eb98a0776f4782a05dfc8936b6dcbd2946134d0e13c3 ;; \
         *) echo "no Zephyr SDK sha256 pinned for $m" >&2; exit 1 ;; \
       esac \
    && curl -fSL --retry 5 --retry-delay 5 --retry-all-errors \
        -O https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v${ZSDK}/zephyr-sdk-${ZSDK}_linux-${m}_minimal.tar.xz \
    && echo "${sdk_sha}  zephyr-sdk-${ZSDK}_linux-${m}_minimal.tar.xz" | sha256sum -c - \
    && tar xf zephyr-sdk-${ZSDK}_linux-${m}_minimal.tar.xz \
    && rm zephyr-sdk-${ZSDK}_linux-${m}_minimal.tar.xz \
    && cd zephyr-sdk-${ZSDK} \
    && curl -fSL --retry 5 --retry-delay 5 --retry-all-errors \
        -O https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v${ZSDK}/toolchain_gnu_linux-${m}_aarch64-zephyr-elf.tar.xz \
    && echo "${gnu_sha}  toolchain_gnu_linux-${m}_aarch64-zephyr-elf.tar.xz" | sha256sum -c - \
    && mkdir -p gnu \
    && tar xf toolchain_gnu_linux-${m}_aarch64-zephyr-elf.tar.xz -C gnu \
    && rm toolchain_gnu_linux-${m}_aarch64-zephyr-elf.tar.xz \
    && test -d gnu/aarch64-zephyr-elf
# setup.sh -c writes the CMake package registry into $HOME/.cmake/packages, and $HOME
# is /root at this point while the build runs as `builder` - so it would not be read.
# It is not needed: ZEPHYR_SDK_INSTALL_DIR above is what FindHostTools.cmake uses,
# confirmed by CMakeCache.txt pointing at gnu/aarch64-zephyr-elf/bin/.
ENV ZEPHYR_SDK_INSTALL_DIR=/opt/zephyr-sdk-${ZSDK}

# Non-root builder aligned with host UID/GID (bitbake refuses to run as root, and
# output files stay user-owned). build.sh's in_docker uses the image default user
# (no --user) and overrides the workdir with -w "$workdir", so only uid/gid + sudo
# matter here; keep this user's HOME at /home/builder for the build tools' caches
# (bazel/gradle/pip under $HOME).
RUN groupadd --gid ${USER_GID} builder \
    && useradd --uid ${USER_ID} --gid ${USER_GID} --create-home \
                --shell /bin/bash builder \
    && echo "builder ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/builder

USER builder
WORKDIR /home/builder/workspace
RUN git config --global user.email "builder@sodev-builder.invalid" \
    && git config --global user.name "SoDeV Builder" \
    && git config --global color.ui auto
CMD ["/bin/bash"]
