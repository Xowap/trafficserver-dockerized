# Global build arguments
ARG BASE_IMAGE=default
ARG ATS_VERSION=10.1.0

# ----------------- Stage 1: Build Setup (shared by both variants) -----------------
FROM ubuntu:noble AS build-setup

ARG LLVM_VERSION=18
ARG BASE=/opt
ARG GO_VERSION=1.26.2

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update \
 && apt upgrade --yes \
 && apt install --no-install-recommends --yes \
    ca-certificates \
    clang-${LLVM_VERSION} \
    libc++-${LLVM_VERSION}-dev \
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
RUN git clone -b 0.28.0 --depth 1 https://github.com/cloudflare/quiche.git \
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
RUN git clone --depth 1 -b v1.15.0 https://github.com/ngtcp2/nghttp3.git \
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
RUN git clone --depth 1 -b v1.22.1 https://github.com/ngtcp2/ngtcp2.git \
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
RUN git clone --depth 1 -b v1.69.0 https://github.com/tatsuhiro-t/nghttp2.git \
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
RUN git clone --depth 1 -b curl-8_20_0 https://github.com/curl/curl.git \
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
 && cmake \
     -Strafficserver \
     -Bbuild \
     -GNinja \
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
 && cmake \
     -Strafficserver \
     -Bbuild \
     -GNinja \
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
FROM ubuntu:noble AS base-default

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
FROM ubuntu:noble AS base-no-hwloc

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
    && chown -R nobody:nogroup /run/trafficserver \
    && mkdir -p /opt/var/trafficserver \
    && chown -R nobody:nogroup /opt/var/trafficserver \
    && mkdir -p /opt/var/log/trafficserver \
    && chown -R nobody:nogroup /opt/var/log/trafficserver

RUN mkdir -p /opt/ats/utils \
    && ln -s /opt/ats/utils/start_ats.py /usr/local/bin/start_ats

COPY utils/start_ats.py /opt/ats/utils/start_ats.py
RUN chmod +x /opt/ats/utils/start_ats.py

ENV PATH="$PATH:/opt/bin"

EXPOSE 8080

CMD ["start_ats"]
