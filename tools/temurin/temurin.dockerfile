# syntax=docker/dockerfile:1
# Adoptium の公式 tarball を /opt/java/temurin に展開するだけの overlay。
# apt の JDK は overlay で運べない（dpkg の状態と共有ライブラリが base 側に要る）ので tarball にする。
FROM debian:trixie-slim AS build
ARG TARGETARCH
ARG TEMURIN_VERSION
ARG TEMURIN_BUILD
ARG TEMURIN_SHA256_AMD64
ARG TEMURIN_SHA256_ARM64

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) jarch=x64;     sum=$TEMURIN_SHA256_AMD64 ;; \
      arm64) jarch=aarch64; sum=$TEMURIN_SHA256_ARM64 ;; \
      *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    major=${TEMURIN_VERSION%%.*}; \
    tag="jdk-${TEMURIN_VERSION}%2B${TEMURIN_BUILD}"; \
    file="OpenJDK${major}U-jdk_${jarch}_linux_hotspot_${TEMURIN_VERSION}_${TEMURIN_BUILD}.tar.gz"; \
    curl -fsSL -o /tmp/jdk.tgz \
      "https://github.com/adoptium/temurin${major}-binaries/releases/download/${tag}/${file}"; \
    echo "$sum  /tmp/jdk.tgz" | sha256sum -c -; \
    mkdir -p /out/opt/java/temurin; \
    tar -xzf /tmp/jdk.tgz -C /out/opt/java/temurin --strip-components=1 --no-same-owner; \
    chown -R 0:0 /out

# 固定した版が本当に入っているかを確かめる（provides の版はここで担保する）。
RUN set -eux; \
    /out/opt/java/temurin/bin/java -version 2>&1 | tee /tmp/v; \
    grep -q "Temurin-${TEMURIN_VERSION}+${TEMURIN_BUILD}" /tmp/v

FROM scratch
COPY --from=build /out /
# 合成された image と agent のプロセスに届くよう、最終ステージで ENV にする。
# mixin の PATH は合成時に workload の PATH へ追記されるので、ここには自分の分だけ書く。
# base が java を持っていればそちらが先に見つかる。
ENV JAVA_HOME=/opt/java/temurin
ENV PATH=/opt/java/temurin/bin
