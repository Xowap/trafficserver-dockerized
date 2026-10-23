# Global build arguments
ARG BASE_IMAGE=default
ARG ATS_VERSION=10.1.0
ARG GO_VERSION=1.26.2
ARG LLVM_VERSION=18
ARG QUICHE_VERSION=0.28.0
ARG NGHTTP3_VERSION=v1.15.0
ARG NGTCP2_VERSION=v1.22.1
ARG NGHTTP2_VERSION=v1.69.0
ARG CURL_VERSION=curl-8_20_0
ARG UBUNTU_VERSION=noble
# Brotli patch release for CVE-2026-111497. Ubuntu noble still ships the
# vulnerable 1.1.0, so we build the fixed upstream release ourselves.
ARG BROTLI_VERSION=v1.1.1

# ----------------- Stage 0: Patched Brotli (CVE-2026-111497) -----------------
# CVE-2026-111497 is an out-of-bounds write in the Brotli decoder
# (c/dec/decode.c) affecting every release from 1.0.3 up to and including
# 1.2.0. It is reachable over the network through any `Content-Encoding: br`
# payload, so it also impacts ATS itself and every other consumer of brotli in
# this image. Ubuntu has not published a patched libbrotli1 for noble yet, so
# we build the fixed release and install it under /usr/local, which takes
# precedence over /usr/lib/<triplet> in the dynamic loader search path.
FROM ubuntu:${UBUNTU_VERSION} AS brotli

ARG BROTLI_VERSION

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update \
 && apt install --no-install-recommends --yes \
    ca-certificates \
    build-essential \
    cmake \
    ninja-build \
    git \
 && apt clean --yes \
 && git clone --depth 1 -b ${BROTLI_VERSION} https://github.com/google/brotli.git \
 && cd brotli \
 && cmake \
     -B build \
     -G Ninja \
     -DCMAKE_BUILD_TYPE=Release \
     -DBUILD_SHARED_LIBS=ON \
     -DCMAKE_INSTALL_PREFIX=/usr/local \
 && cmake --build build --parallel $(nproc) \
 && cmake --install build \
 && cd .. \
 && rm -rf brotli \
 # Refuse to produce a "patched" layer that is still vulnerable.
 && installed="$(basename "$(readlink -f /usr/local/lib/libbrotlidec.so.1)" | sed 's/^libbrotlidec\.so\.//')" \
 && dpkg --compare-versions "${installed}" ge 1.1.1 \
 && echo "Built patched brotli decoder: ${installed}"

# ----------------- Stage 1: Build Setup (shared by both variants) -----------------
FROM ubuntu:${UBUNTU_VERSION} AS build-setup

ARG LLVM_VERSION
ARG BASE=/opt
ARG GO_VERSION
ARG QUICHE_VERSION
ARG NGHTTP3_VERSION
ARG NGTCP2_VERSION
ARG NGHTTP2_VERSION
ARG CURL_VERSION
ARG UBUNTU_VERSION

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update \
 && apt upgrade --yes \
 && apt install --no-install-recommends --yes \
    ca-certificates \
    clang-${LLVM_VERSION} \
    libc++-${LLVM_VERSION}-dev \
    # Provides clang-scan-deps, required by CMake >= 3.28 when a subproject
    # raises its policy level to CMP0155 NEW (the yaml-cpp bundled by ATS
    # 10.1.3+ does exactly that, and the build then needs CXX module scanning).
    clang-tools-${LLVM_VERSION} \
    cmake \
    ninja-build \
    libc-ares-dev \
    libsystemd-dev \
    libev-dev \
    libevent-dev \
    zlib1g-dev \
    rustup \
    wget \
    git \
    libtool \
    make \
    pkg-config \
    libpsl-dev \
    libxml2-dev \
    libjemalloc-dev \
    libhwloc-dev \
    libfmt-dev \
    libpcre2-dev \
    libpcre3-dev \
    hwloc \
    libbrotli-dev \
    libzstd-dev \
    luajit \
    libluajit-5.1-dev \
    libcap-dev \
    libmagick++-dev \
    libmaxminddb-dev \
    libcjose-dev \
    libcjose0 \
    libjansson-dev \
    libssl-dev \
    python3 \
    python3-yaml \
 && apt clean --yes

# Set up cc and c++
RUN update-alternatives --install /usr/bin/cc cc /usr/bin/clang-${LLVM_VERSION} 100 \
    && update-alternatives --install /usr/bin/c++ c++ /usr/bin/clang++-${LLVM_VERSION} 100 \
    && update-alternatives --install /usr/bin/clang clang /usr/bin/clang-${LLVM_VERSION} 100 \
    && update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-${LLVM_VERSION} 100

RUN rustup default stable

RUN mkdir -p ${BASE} && chmod a+rX ${BASE}

RUN if [ `uname -m` = "arm64" -o `uname -m` = "aarch64" ]; then echo "arm64" > /arch; else echo "amd64" > /arch; fi \
  && wget -qO- https://go.dev/dl/go${GO_VERSION}.linux-$(cat /arch).tar.gz | tar -C ${BASE} -xzf -

ENV CC=clang-${LLVM_VERSION}
ENV CXX=clang++-${LLVM_VERSION}
ENV GO_BINARY_PATH=${BASE}/go/bin/go

# Build against the patched brotli (CVE-2026-111497) rather than the version
# shipped by Ubuntu, so that what we link against is what we ship. Note that the
# directory form of COPY is required here: a wildcard over the individual files
# would dereference the SONAME symlinks and break dynamic linking.
COPY --from=brotli /usr/local/lib /usr/local/lib
COPY --from=brotli /usr/local/include/brotli /usr/local/include/brotli
RUN ldconfig

# Build BoringSSL
RUN git clone https://boringssl.googlesource.com/boringssl \
 && cd boringssl \
 && git checkout 45b2464158379f48cec6e35a1ef503ddea1511a6 \
 && cmake \
  -B build-shared \
  -G Ninja \
  -DGO_EXECUTABLE=${GO_BINARY_PATH} \
  -DCMAKE_INSTALL_PREFIX=${BASE}/boringssl \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_FLAGS='-Wno-error=ignored-attributes -UBORINGSSL_HAVE_LIBUNWIND' \
  -DBUILD_SHARED_LIBS=1 \
 && cmake \
  -B build-static \
  -G Ninja \
  -DGO_EXECUTABLE=${GO_BINARY_PATH} \
  -DCMAKE_INSTALL_PREFIX=${BASE}/boringssl \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_FLAGS='-Wno-error=ignored-attributes -UBORINGSSL_HAVE_LIBUNWIND' \
  -DBUILD_SHARED_LIBS=0 \
 && cmake --build build-shared  \
 && cmake --build build-static  \
 && cmake --install build-shared \
 && cmake --install build-static \
 && cd .. \
 && rm -rf boringssl

ENV QUICHE_BASE="${BASE}/quiche"

# Build Quiche
RUN git clone -b ${QUICHE_VERSION} --depth 1 https://github.com/cloudflare/quiche.git \
 && cd quiche \
 && QUICHE_BSSL_PATH=${BASE}/boringssl/lib QUICHE_BSSL_LINK_KIND=dylib \
    cargo build -j$(nproc) --package quiche --release --features ffi,pkg-config-meta,qlog \
 && mkdir -p ${QUICHE_BASE}/lib/pkgconfig \
 && mkdir -p ${QUICHE_BASE}/include \
 && cp target/release/libquiche.a ${QUICHE_BASE}/lib/ \
 && cp target/release/libquiche.so ${QUICHE_BASE}/lib/ \
 && ln -sf ${QUICHE_BASE}/lib/libquiche.so ${QUICHE_BASE}/lib/libquiche.so.0 \
 && cp quiche/include/quiche.h ${QUICHE_BASE}/include/ \
 && cp target/release/quiche.pc ${QUICHE_BASE}/lib/pkgconfig \
 && cd .. \
 && rm -rf quiche

ENV LDFLAGS="-Wl,-rpath,${BASE}/boringssl/lib"
ENV CFLAGS="-O3"
ENV CXXFLAGS="-O3"
ENV PKG_CONFIG_PATH="${BASE}/lib/pkgconfig:${BASE}/boringssl/lib/pkgconfig:${BASE}/quiche/lib/pkgconfig"

# Build nghttp3
RUN git clone --depth 1 -b ${NGHTTP3_VERSION} https://github.com/ngtcp2/nghttp3.git \
 && cd nghttp3 \
 && git submodule update --init \
 && autoreconf -if \
 && ./configure \
  --prefix=${BASE} \
  PKG_CONFIG_PATH=${BASE}/lib/pkgconfig:${BASE}/boringssl/lib/pkgconfig \
  CFLAGS="${CFLAGS}" \
  CXXFLAGS="${CXXFLAGS}" \
  LDFLAGS="${LDFLAGS}" \
  --enable-lib-only \
 && make -j $(nproc) \
 && make install \
 && cd .. \
 && rm -rf nghttp3

# Build ngtcp2
RUN git clone --depth 1 -b ${NGTCP2_VERSION} https://github.com/ngtcp2/ngtcp2.git \
 && cd ngtcp2 \
 && autoreconf -if \
 && ./configure \
  --prefix=${BASE} \
  --with-boringssl \
  BORINGSSL_CFLAGS="-I${BASE}/boringssl/include" \
  BORINGSSL_LIBS="-L${BASE}/boringssl/lib -lssl -lcrypto" \
  CFLAGS="${CFLAGS} -fPIC" \
  CXXFLAGS="${CXXFLAGS} -fPIC" \
  LDFLAGS="${LDFLAGS}" \
  --enable-lib-only \
 && make -j $(nproc) \
 && make install \
 && cd .. \
 && rm -rf ngtcp2

# Build nghttp2
RUN git clone --depth 1 -b ${NGHTTP2_VERSION} https://github.com/tatsuhiro-t/nghttp2.git \
 && cd nghttp2 \
 && git submodule update --init \
 && autoreconf -if \
 && ./configure \
  --prefix=${BASE} \
  CFLAGS="${CFLAGS} -I${BASE}/boringssl/include" \
  CXXFLAGS="${CXXFLAGS} -I${BASE}/boringssl/include" \
  LDFLAGS="${LDFLAGS}" \
  OPENSSL_LIBS="-L${BASE}/boringssl/lib -lcrypto -lssl" \
  --enable-http3 \
  --disable-examples \
  --enable-app \
 && make -j $(nproc) \
 && make install \
 && cd .. \
 && rm -rf nghttp2

# Build Curl
RUN git clone --depth 1 -b ${CURL_VERSION} https://github.com/curl/curl.git \
 && cd curl \
 && autoreconf -fi \
 && ./configure \
  --prefix=${BASE} \
  --with-openssl="${BASE}/boringssl" \
  --with-nghttp2=${BASE} \
  --with-nghttp3=${BASE} \
  --with-ngtcp2=${BASE} \
  LDFLAGS="${LDFLAGS} -L${BASE}/boringssl/lib -Wl,-rpath,${BASE}/boringssl/lib" \
  CFLAGS="${CFLAGS}" \
  CXXFLAGS="${CXXFLAGS}" \
 && make -j $(nproc) \
 && make install \
 && cd .. \
 && rm -rf curl


# ----------------- Stage 2a: Build default -----------------
FROM build-setup AS build-default

ARG ATS_VERSION
ARG BASE=/opt

RUN git clone --depth 1 -b ${ATS_VERSION} https://github.com/apache/trafficserver.git \
 && sed -i 's/target_link_libraries(cripts PUBLIC/target_link_libraries(cripts PUBLIC tscore tsutil/' trafficserver/src/cripts/CMakeLists.txt \
 && cmake \
     -Strafficserver \
     -Bbuild \
     -GNinja \
     # ATS has no C++ modules; disabling the scan keeps the build independent
     # of clang-scan-deps (upstream does the same in its newest Dockerfile).
     -DCMAKE_CXX_SCAN_FOR_MODULES=OFF \
     -DCMAKE_INSTALL_PREFIX=${BASE} \
     -DCMAKE_BUILD_TYPE=Release \
     -DBUILD_TESTING=OFF \
     -DBUILD_REGRESSION_TESTING=OFF \
     -DENABLE_AUTEST=OFF \
     -DBUILD_EXPERIMENTAL_PLUGINS=ON \
     -DENABLE_JEMALLOC=ON \
     -DENABLE_MALLOC_ALLOCATOR=ON \
     -DENABLE_QUICHE=ON \
     -DENABLE_CRIPTS=ON \
     -DENABLE_EXAMPLE=OFF \
     -DENABLE_LUAJIT=ON \
     -DENABLE_HWLOC=ON \
     -DOPENSSL_ROOT_DIR=${BASE}/boringssl \
     -Dquiche_ROOT=${QUICHE_BASE} \
 && cmake --build build \
 && cmake --install build \
 && rm -rf build trafficserver


# ----------------- Stage 2b: Build no-hwloc -----------------
FROM build-setup AS build-no-hwloc

ARG ATS_VERSION
ARG BASE=/opt

RUN git clone --depth 1 -b ${ATS_VERSION} https://github.com/apache/trafficserver.git \
 && sed -i 's/target_link_libraries(cripts PUBLIC/target_link_libraries(cripts PUBLIC tscore tsutil/' trafficserver/src/cripts/CMakeLists.txt \
 && cmake \
     -Strafficserver \
     -Bbuild \
     -GNinja \
     # ATS has no C++ modules; disabling the scan keeps the build independent
     # of clang-scan-deps (upstream does the same in its newest Dockerfile).
     -DCMAKE_CXX_SCAN_FOR_MODULES=OFF \
     -DCMAKE_INSTALL_PREFIX=${BASE} \
     -DCMAKE_BUILD_TYPE=Release \
     -DBUILD_TESTING=OFF \
     -DBUILD_REGRESSION_TESTING=OFF \
     -DENABLE_AUTEST=OFF \
     -DBUILD_EXPERIMENTAL_PLUGINS=ON \
     -DENABLE_JEMALLOC=ON \
     -DENABLE_MALLOC_ALLOCATOR=ON \
     -DENABLE_QUICHE=ON \
     -DENABLE_CRIPTS=ON \
     -DENABLE_EXAMPLE=OFF \
     -DENABLE_LUAJIT=ON \
     -DENABLE_HWLOC=OFF \
     -DOPENSSL_ROOT_DIR=${BASE}/boringssl \
     -Dquiche_ROOT=${QUICHE_BASE} \
 && cmake --build build \
 && cmake --install build \
 && rm -rf build trafficserver


# ----------------- Stage 3a: Base default -----------------
FROM ubuntu:${UBUNTU_VERSION} AS base-default

ARG UBUNTU_VERSION

# Install runtime dependencies for default variant (includes hwloc)
RUN apt update \
 && apt upgrade --yes \
 && apt install --no-install-recommends --yes \
    ca-certificates \
    libjemalloc2 \
    libxml2 \
    hwloc \
    libmaxminddb0 \
    libfmt9 \
    libpcre2-8-0 \
    libpcre3 \
    libbrotli1 \
    luajit \
    libcap2 \
    libevent-2.1-7t64 \
    libev4t64 \
    libcares2 \
    libmagick++-6.q16-9t64 \
    libmagickcore-6.q16-7t64 \
    libmagickwand-6.q16-7t64 \
    libcjose0 \
    libjansson4 \
    python3 \
    python3-yaml \
 && apt clean --yes

COPY --from=build-default /opt /opt


# ----------------- Stage 3b: Base no-hwloc -----------------
FROM ubuntu:${UBUNTU_VERSION} AS base-no-hwloc

ARG UBUNTU_VERSION

# Install runtime dependencies for no-hwloc variant (omits hwloc)
RUN apt update \
 && apt upgrade --yes \
 && apt install --no-install-recommends --yes \
    ca-certificates \
    libjemalloc2 \
    libxml2 \
    libmaxminddb0 \
    libfmt9 \
    libpcre2-8-0 \
    libpcre3 \
    libbrotli1 \
    luajit \
    libcap2 \
    libevent-2.1-7t64 \
    libev4t64 \
    libcares2 \
    libmagick++-6.q16-9t64 \
    libmagickcore-6.q16-7t64 \
    libmagickwand-6.q16-7t64 \
    libcjose0 \
    libjansson4 \
    python3 \
    python3-yaml \
 && apt clean --yes

COPY --from=build-no-hwloc /opt /opt


# ----------------- Stage 4: Final Stage -----------------
FROM base-${BASE_IMAGE}

# --- Security: CVE-2026-111497 (Brotli decoder out-of-bounds write) -----------
# Ubuntu noble ships the vulnerable brotli 1.1.0. Drop it and use the patched
# build instead, so that every consumer in the image (ATS, ImageMagick, ...)
# decompresses `Content-Encoding: br` with the fixed decoder. COPY of the
# directory (rather than of a wildcard) keeps the SONAME symlinks intact.
COPY --from=brotli /usr/local/lib /usr/local/lib
RUN rm -f /usr/lib/*-linux-gnu/libbrotli*.so* \
    && ldconfig \
    && installed="$(basename "$(readlink -f /usr/local/lib/libbrotlidec.so.1)" | sed 's/^libbrotlidec\.so\.//')" \
    && dpkg --compare-versions "${installed}" ge 1.1.1 \
    && echo "Patched brotli decoder in use: ${installed}" \
    && ldconfig -p | grep libbrotlidec

# Create native 'trafficserver' system user and group (matching GID 101 / UID 100)
RUN groupadd -g 101 trafficserver \
    && useradd -u 100 -g trafficserver -d /run/trafficserver -s /bin/false -r trafficserver

# Create compatibility symlinks and directories
RUN rm -rf /etc/trafficserver \
    && ln -s /opt/etc/trafficserver /etc/trafficserver \
    && rm -rf /var/log/trafficserver \
    && ln -s /opt/var/log/trafficserver /var/log/trafficserver \
    && rm -rf /var/cache/trafficserver \
    && ln -s /opt/var/trafficserver /var/cache/trafficserver \
    && ln -sf /opt/bin/traffic_server /usr/bin/traffic_server \
    && ln -sf /opt/bin/traffic_ctl /usr/bin/traffic_ctl \
    && ln -sf /opt/bin/traffic_layout /usr/bin/traffic_layout \
    && mkdir -p /run/trafficserver \
    && chown -R trafficserver:trafficserver /run/trafficserver \
    && mkdir -p /opt/var/trafficserver \
    && chown -R trafficserver:trafficserver /opt/var/trafficserver \
    && mkdir -p /opt/var/log/trafficserver \
    && chown -R trafficserver:trafficserver /opt/var/log/trafficserver

RUN mkdir -p /opt/ats/utils \
    && ln -s /opt/ats/utils/start_ats.py /usr/local/bin/start_ats

COPY utils/start_ats.py /opt/ats/utils/start_ats.py
RUN chmod +x /opt/ats/utils/start_ats.py

ENV PATH="$PATH:/opt/bin"

EXPOSE 8080

CMD ["start_ats"]
