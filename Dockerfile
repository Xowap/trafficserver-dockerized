ARG BASE_IMAGE=default

FROM debian:bookworm as builder

ENV DEBIAN_FRONTEND=noninteractive

RUN sed 's/^Types: deb/Types: deb-src/' /etc/apt/sources.list.d/debian.sources > /etc/apt/sources.list.d/debian-src.sources

RUN apt-get update \
    && apt-get install -y fakeroot \
    && apt-get build-dep -y trafficserver

RUN adduser --disabled-password --gecos '' user

USER user

WORKDIR /home/user

COPY utils/build_ats.sh build_ats.sh

RUN ./build_ats.sh

FROM debian:bookworm as base-no-hwloc

RUN mkdir -p /opt/ats/packages

COPY --from=builder /home/user/trafficserver.deb /opt/ats/packages

RUN apt-get update && \
    apt-get install -y python3 python3-yaml /opt/ats/packages/trafficserver.deb && \
    rm -rf /var/lib/apt/lists/*

FROM debian:bookworm as base-default

RUN apt-get update && \
    apt-get install -y python3 python3-yaml trafficserver && \
    rm -rf /var/lib/apt/lists/*

FROM base-${BASE_IMAGE}

RUN mkdir -p /opt/ats/utils \
    && ln -s /opt/ats/utils/start_ats.py /usr/local/bin/start_ats \
    && mkdir -p /run/trafficserver \
    && chown -R trafficserver:trafficserver /run/trafficserver

COPY utils/start_ats.py /opt/ats/utils/start_ats.py

EXPOSE 8080

CMD ["start_ats"]
