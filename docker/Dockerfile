# Reproducible cross-build environment for kvmhost.
#
# The host may be arm64 (Apple silicon) or x86_64; the target is always
# x86_64.  We therefore always use the cross toolchain, even on x86_64
# hosts, so that every developer produces byte-identical objects.
FROM debian:trixie-slim

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
        gcc \
        git \
        kmod \
        libelf-dev \
        libncurses-dev \
        libssl-dev \
        make \
        openssl \
        pahole \
        python3 \
        rsync \
        xz-utils \
        zstd \
    && rm -rf /var/lib/apt/lists/*

ENV ARCH=x86_64 \
    CROSS_COMPILE=x86_64-linux-gnu- \
    KBUILD_BUILD_USER=kvmhost \
    KBUILD_BUILD_HOST=builder \
    KBUILD_BUILD_TIMESTAMP="Thu Jan  1 00:00:00 UTC 1970" \
    SOURCE_DATE_EPOCH=0

WORKDIR /build
