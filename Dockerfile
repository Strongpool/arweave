FROM ghcr.io/strongpool/erlang:23.3.4.4 AS builder

RUN apt-get -y update && apt-get -y install \
    build-essential \
    cmake \
    git \
    libgmp-dev \
    libsqlite3-dev

RUN mkdir /build
WORKDIR /build

COPY apps/ ./apps/
COPY bin/ ./bin/
COPY config/ ./config/
COPY data/ ./data/
COPY rebar* ./
COPY scripts/ ./scripts/

RUN ./rebar3 as prod release

FROM builder AS test

RUN epmd -daemon && ./bin/test

FROM ghcr.io/strongpool/debian:buster

RUN apt-get -y update && apt-get -y install \
    libssl1.1 \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /arweave \
    && cd /arweave

COPY --from=builder /build/_build/prod/rel/arweave/ /arweave/

RUN mkdir -p /data

VOLUME ["/data"]

EXPOSE 1984/tcp

HEALTHCHECK CMD curl -f http://localhost:1984/ || exit 1

ADD ./entrypoint /entrypoint

ENTRYPOINT ["/entrypoint"]
