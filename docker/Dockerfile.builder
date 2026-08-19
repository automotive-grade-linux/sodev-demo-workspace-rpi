# SPDX-License-Identifier: Apache-2.0
# Single build image for the whole sodev-demo-workspace-rpi workspace.
#
#   docker build -f docker/Dockerfile.builder docker/ \
#     --build-arg USER_ID="$(id -u)" --build-arg USER_GID="$(id -g)" \
#     -t sodev-builder
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
#   - Zephyr SDK 0.16.3 (aarch64-zephyr-elf)    -> Zephyr Dom0 (DOM0_OS=zephyr).
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
        g++-multilib gcc-multilib libc6-dev-i386 \
        lib32ncurses-dev libncurses5-dev lib32z1-dev zlib1g-dev \
        libxml2-utils libxml-simple-perl libgl1-mesa-dev \
        gperf imagemagick libjpeg-dev libpng-dev libsdl1.2-dev \
        libwxgtk3.0-gtk3-dev squashfs-tools xsltproc fontconfig \
        # Zephyr build host tools
        cmake device-tree-compiler \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# Downgrade tar version to workaround fakeroot issue
RUN apt-get update && apt-get install -y \
	--allow-downgrades \
	--allow-change-held-packages \
	tar=1.34+dfsg-1build3

# moulin 0.28 (known-good git pin; pulls gpt-image, pyyaml,
# mako, ...) + west (Zephyr meta-tool, required by the DOM0_OS=zephyr component)
# + meson (AOSP host-tool build).
RUN pip3 install --no-cache-dir \
        "git+https://github.com/xen-troops/moulin@83e80587c4b1348714237d3ff53129857288a420" \
        west 'meson>=1.4.0' \
    && ln -sf /usr/local/bin/meson /usr/bin/meson

# Google repo + bazelisk (AOSP).
# Pins for reproducibility: bazelisk is pinned to a fixed release (not
# releases/latest) so the image is deterministic; bazelisk itself only launches the
# bazel version each AOSP tree requests via .bazelversion. The `repo` launcher is
# the canonical Google bootstrap — its effective version is pinned per-manifest by
# the repo-rev and by REPO_SKIP_SELF_UPDATE=1 at sync time (see build.sh / README).
ARG BAZELISK_VERSION=v1.20.0
RUN curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
        -o /usr/local/bin/repo \
    && chmod 0755 /usr/local/bin/repo \
    && curl -fsSL -o /usr/local/bin/bazel \
        https://github.com/bazelbuild/bazelisk/releases/download/${BAZELISK_VERSION}/bazelisk-linux-amd64 \
    && chmod 0755 /usr/local/bin/bazel

# Zephyr build Python deps (west is installed above) + the Zephyr SDK 0.16.3
# (aarch64-zephyr-elf, matching the Zephyr 3.6 dom0 sources). --retry rides out a
# flaky proxy. Kept as a LATE layer so it never invalidates the moulin git-install
# cache above.
RUN pip3 install --no-cache-dir \
        pyelftools pykwalify packaging anytree intelhex pyyaml canopen
ARG ZSDK=0.16.3
RUN cd /opt \
    && curl -fSL --retry 5 --retry-delay 5 --retry-all-errors \
        -O https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v${ZSDK}/zephyr-sdk-${ZSDK}_linux-x86_64_minimal.tar.xz \
    && tar xf zephyr-sdk-${ZSDK}_linux-x86_64_minimal.tar.xz \
    && rm zephyr-sdk-${ZSDK}_linux-x86_64_minimal.tar.xz \
    && cd zephyr-sdk-${ZSDK} \
    && curl -fSL --retry 5 --retry-delay 5 --retry-all-errors \
        -O https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v${ZSDK}/toolchain_linux-x86_64_aarch64-zephyr-elf.tar.xz \
    && tar xf toolchain_linux-x86_64_aarch64-zephyr-elf.tar.xz \
    && rm toolchain_linux-x86_64_aarch64-zephyr-elf.tar.xz \
    && ./setup.sh -c
ENV ZEPHYR_SDK_INSTALL_DIR=/opt/zephyr-sdk-0.16.3

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
