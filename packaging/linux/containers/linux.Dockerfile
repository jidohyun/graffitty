# All shipped native code is built against Jammy's glibc 2.35.
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential clang lld cmake ninja-build pkg-config git curl ca-certificates \
    python3 python3-pip python3-venv scons patchelf binutils unzip xz-utils nasm gettext \
    libssl-dev libasound2-dev libudev-dev libdbus-1-dev libva-dev libdrm-dev \
    libx11-dev libxcursor-dev libxinerama-dev libxrandr-dev libxi-dev \
    libwayland-dev wayland-protocols libxkbcommon-dev libgl1-mesa-dev \
    libvulkan-dev libfontconfig1-dev libspeechd-dev \
    zstd libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libatspi2.0-0 libcairo2 libcups2 \
    libpango-1.0-0 libxcomposite1 libxdamage1 libgbm1 && rm -rf /var/lib/apt/lists/*
RUN python3 -m venv /opt/build-tools && /opt/build-tools/bin/pip install 'scons==4.9.1' 'tomli==2.2.1' 'version-pioneer==0.0.16' 'uv==0.13.8'
ENV PATH="/opt/build-tools/bin:/root/.cargo/bin:/opt/zig:${PATH}"
WORKDIR /work
ENTRYPOINT ["python3", "packaging/linux/build_native.py"]
