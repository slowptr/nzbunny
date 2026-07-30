# syntax=docker/dockerfile:1
FROM debian:bookworm-slim AS build

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils libsqlite3-dev libarchive-dev \
    && rm -rf /var/lib/apt/lists/*

ARG TARGETARCH=amd64
ARG ZIG_VERSION=0.16.0
ARG ZIG_AMD64_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
ARG ZIG_ARM64_SHA256=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17

RUN case "$TARGETARCH" in \
      amd64) zig_arch=x86_64; zig_sha="$ZIG_AMD64_SHA256" ;; \
      arm64) zig_arch=aarch64; zig_sha="$ZIG_ARM64_SHA256" ;; \
      *) echo "Unsupported target architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && curl --fail --location --silent --show-error \
      "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz" \
      --output /tmp/zig.tar.xz \
    && echo "${zig_sha}  /tmp/zig.tar.xz" | sha256sum --check --strict \
    && mkdir /opt/zig \
    && tar --extract --xz --file /tmp/zig.tar.xz --strip-components=1 --directory /opt/zig \
    && rm /tmp/zig.tar.xz

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
RUN /opt/zig/zig build -Doptimize=ReleaseSafe --prefix /out

FROM debian:bookworm-slim AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl libsqlite3-0 libarchive13 \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system --gid 10001 nzigbunny \
    && useradd --system --uid 10001 --gid nzigbunny --home-dir /data nzigbunny \
    && mkdir -p /data /downloads \
    && chown nzigbunny:nzigbunny /data /downloads

COPY --from=build /out/bin/nzigbunny /usr/local/bin/nzigbunny

USER nzigbunny
WORKDIR /data
EXPOSE 1337
ENTRYPOINT ["/usr/local/bin/nzigbunny"]
