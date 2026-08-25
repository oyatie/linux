# Reproducible cross-build environment for kvmhost.
#
# The host may be arm64 (Apple silicon) or x86_64; the target is x86_64 OR
# arm64 (KARCH).  We always use the cross toolchain, even when host==target,
# so that every developer produces byte-identical objects.
# Base pinned BY DIGEST, not by the floating trixie-slim tag: `make repro`
# otherwise proves only same-container determinism, while the container
# itself could change under us.  Update deliberately.
FROM debian:trixie-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        bc \
        binutils-x86-64-linux-gnu \
        bison \
        bzip2 \
        ca-certificates \
        cpio \
        curl \
        dwarves \
        flex \
        gcc-x86-64-linux-gnu \
        libc6-dev-amd64-cross \
        binutils-aarch64-linux-gnu \
        gcc-aarch64-linux-gnu \
        libc6-dev-arm64-cross \
        gcc \
        git \
        kmod \
        libelf-dev \
        libncurses-dev \
        libssl-dev \
        lz4 \
        sbsigntool \
        erofs-utils \
        cryptsetup-bin \
        mtools \
        dosfstools \
        uuid-runtime \
        ovmf \
        efitools \
        python3-virt-firmware \
        systemd-boot-efi \
        systemd-ukify \
        qemu-system-x86 \
        qemu-system-arm \
        qemu-utils \
        swtpm \
        iproute2 \
        make \
        openssl \
        pahole \
        python3 \
        rsync \
        xz-utils \
        zstd \
    && rm -rf /var/lib/apt/lists/*

# KBUILD_BUILD_VERSION pins the per-build counter (.version increments each
# link otherwise -> "#1" vs "#17" in the version string -> non-reproducible).
ENV ARCH=x86_64 \
    CROSS_COMPILE=x86_64-linux-gnu- \
    KBUILD_BUILD_USER=kvmhost \
    KBUILD_BUILD_HOST=builder \
    KBUILD_BUILD_TIMESTAMP="Thu Jan  1 00:00:00 UTC 1970" \
    KBUILD_BUILD_VERSION=1 \
    SOURCE_DATE_EPOCH=0

WORKDIR /build
