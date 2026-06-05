ARG DEBIAN_VERSION=bookworm
ARG ZIG_VERSION=0.16.0

FROM debian:${DEBIAN_VERSION}-slim AS builder

ARG ZIG_VERSION
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        libcairo2-dev \
        librsvg2-dev \
        libpango1.0-dev \
        pkg-config \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
        amd64) zig_arch="x86_64-linux" ;; \
        arm64) zig_arch="aarch64-linux" ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl --retry 5 --retry-delay 2 --connect-timeout 20 --max-time 300 -fsSL \
        "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-${ZIG_VERSION}.tar.xz" \
        -o /tmp/zig.tar.xz; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz

ENV PATH="/opt/zig:${PATH}"

WORKDIR /src
COPY build.zig ./build.zig
COPY release/VERSION ./release/VERSION
COPY src ./src
COPY stdlib ./stdlib
COPY scripts/setup-md4c.sh ./scripts/setup-md4c.sh

ARG SS_VERSION=0.1.0-dev
ARG SS_COMMIT=unknown

RUN scripts/setup-md4c.sh \
    && zig build -Doptimize=ReleaseSafe -Dversion="${SS_VERSION}" -Dcommit="${SS_COMMIT}"

FROM debian:${DEBIAN_VERSION}-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        fontconfig \
        fonts-noto-cjk \
        fonts-noto-color-emoji \
        imagemagick \
        libcairo2 \
        libpango-1.0-0 \
        libpangocairo-1.0-0 \
        librsvg2-2 \
        poppler-utils \
        qpdf \
        texlive-full; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/zig-out/bin/ss /usr/local/bin/ss
COPY release/docker/render/docker-entrypoint.sh /usr/local/bin/ss-docker-entrypoint

RUN chmod +x /usr/local/bin/ss-docker-entrypoint

ENV SS_CACHE_MAX_BYTES="512M"

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/ss-docker-entrypoint"]
