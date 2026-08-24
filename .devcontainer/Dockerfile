FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# Build tools + Verilator (from source, ~5 min) + Python deps for the bridge
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential git make g++ python3 python3-pip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --break-system-packages pyserial

# Verilator 5.x from source (oss-cad-suite not available in slim containers)
RUN git clone --depth 1 --branch v5_026 https://github.com/verilator/verilator.git /opt/verilator-src \
    && cd /opt/verilator-src \
    && ./configure --prefix=/usr/local \
    && make -j"$(nproc)" \
    && make install \
    && rm -rf /opt/verilator-src \
    && ldconfig

WORKDIR /workspace
