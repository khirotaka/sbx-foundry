# syntax=docker/dockerfile:1
# Quint を npm パッケージから入れる overlay。
#
# Node は kit 専用のものを /opt/quint/node に同梱し、PATH には載せない。
# /usr/local/bin/quint はラッパーで、quint とその子プロセス（Lake など）にだけ
# /opt/quint/node/bin を PATH の先頭に足す。`quint veil install` は Lake 経由で npm を
# 呼ぶので、これで npm が見つかる。sandbox 全体の node / npm（mise など）とはぶつからない。
#
# 公開版の単一バイナリ（Node SEA）ではなく npm にしたのは、SEA が npm を含まず、
# Veil のために結局 Node 一式が要るため。
FROM debian:trixie-slim AS build
ARG TARGETARCH
ARG QUINT_VERSION
ARG QUINT_EVALUATOR_VERSION
ARG QUINT_EVALUATOR_SHA256_AMD64
ARG QUINT_EVALUATOR_SHA256_ARM64
ARG NODE_VERSION
ARG NODE_SHA256_AMD64
ARG NODE_SHA256_ARM64

# busybox-static: Veil の初回ビルドで Lake が unzip を呼ぶ（Linux で cvc5 を展開する）。
# base に unzip があるとは限らず、apt のパッケージは overlay で運べないので、
# 静的リンクの busybox を unzip として同梱する（ラッパーが PATH の末尾に足す）。
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils busybox-static \
 && rm -rf /var/lib/apt/lists/*

# Node を /opt/quint/node に展開する。最終的な配置と同じパスで作るので、
# npm が書く shebang や symlink をそのまま運べる。
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) narch=x64;   sum=$NODE_SHA256_AMD64 ;; \
      arm64) narch=arm64; sum=$NODE_SHA256_ARM64 ;; \
      *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/node.tar.xz \
      "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${narch}.tar.xz"; \
    echo "$sum  /tmp/node.tar.xz" | sha256sum -c -; \
    mkdir -p /opt/quint/node; \
    tar -xJf /tmp/node.tar.xz -C /opt/quint/node --strip-components=1 --no-same-owner; \
    test "$(/opt/quint/node/bin/node --version)" = "v${NODE_VERSION}"

# Quint 本体。--prefix を同梱 Node のものにして、/opt/quint/node/lib/node_modules に入れる。
RUN set -eux; \
    PATH=/opt/quint/node/bin:$PATH; \
    npm install -g --no-fund --no-audit "@informalsystems/quint@${QUINT_VERSION}"; \
    npm cache clean --force

# Rust evaluator。`quint run` / `test` / `repl` の既定 backend は rust で、無いと初回に
# api.github.com から取得しにいくので同梱する（install フックで ~/.quint に繋ぐ）。
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) triple=x86_64-unknown-linux-gnu;  sum=$QUINT_EVALUATOR_SHA256_AMD64 ;; \
      arm64) triple=aarch64-unknown-linux-gnu; sum=$QUINT_EVALUATOR_SHA256_ARM64 ;; \
    esac; \
    d="/opt/quint/rust-evaluator-v${QUINT_EVALUATOR_VERSION}"; \
    curl -fsSL -o /tmp/ev.tgz \
      "https://github.com/quint-co/quint/releases/download/evaluator/v${QUINT_EVALUATOR_VERSION}/quint_evaluator-${triple}.tar.gz"; \
    echo "$sum  /tmp/ev.tgz" | sha256sum -c -; \
    tar -xzf /tmp/ev.tgz -C /tmp quint_evaluator; \
    install -D -m 0755 /tmp/quint_evaluator "$d/quint_evaluator"

RUN set -eux; \
    mkdir -p /opt/quint/libexec; \
    cp /bin/busybox /opt/quint/libexec/busybox; \
    ln -s busybox /opt/quint/libexec/unzip; \
    mkdir -p /usr/local/bin; \
    printf '%s\n' \
      '#!/bin/sh' \
      '# Installed by the quint kit (tools/quint).' \
      '# 同梱の Node を、quint とその子プロセスにだけ見せる。' \
      '# - /opt/quint/node/bin を先頭に: Veil の Lake が呼ぶ npm を同梱のものにする' \
      '# - /opt/quint/libexec を末尾に: base に unzip が無いときだけ busybox の unzip を使う' \
      'PATH="/opt/quint/node/bin:${PATH:-/usr/local/bin:/usr/bin:/bin}:/opt/quint/libexec"' \
      'export PATH' \
      'exec /opt/quint/node/bin/node /opt/quint/node/lib/node_modules/@informalsystems/quint/dist/src/cli.js "$@"' \
      > /usr/local/bin/quint; \
    chmod 0755 /usr/local/bin/quint

# 固定した版が本当に入っているかを確かめる（provides の版はここで担保する）。
#  1) quint --version が QUINT_VERSION と一致する
#  2) quint が期待する evaluator の版が、同梱したものと一致する
#     （食い違うと、実行時に GitHub から別の版を取りにいく）
#  3) 同梱の evaluator だけで `quint run` が通り、取得を試みない
#  4) ラッパー経由で npm / unzip が見える（`quint veil install` の前提）
RUN set -eux; \
    q=/usr/local/bin/quint; \
    test "$($q --version)" = "$QUINT_VERSION"; \
    pinned=$(grep -rhoE "QUINT_EVALUATOR_VERSION = 'v[0-9.]+'" \
      /opt/quint/node/lib/node_modules/@informalsystems/quint/dist/src | sort -u); \
    test "$pinned" = "QUINT_EVALUATOR_VERSION = 'v${QUINT_EVALUATOR_VERSION}'" || { \
      echo "quint ${QUINT_VERSION} pins: $pinned (kit has v${QUINT_EVALUATOR_VERSION})" >&2; exit 1; }; \
    export QUINT_HOME=/tmp/qh; mkdir -p "$QUINT_HOME"; \
    ln -s "/opt/quint/rust-evaluator-v${QUINT_EVALUATOR_VERSION}" \
      "$QUINT_HOME/rust-evaluator-v${QUINT_EVALUATOR_VERSION}"; \
    printf '%s\n' \
      'module counter {' \
      '  var n: int' \
      '  action init = n'"'"' = 0' \
      '  action step = n'"'"' = n + 1' \
      '  val ok = n >= 0' \
      '}' > /tmp/counter.qnt; \
    $q run --max-samples=5 --max-steps=3 --invariant=ok /tmp/counter.qnt > /tmp/run.log 2>&1 \
      || { cat /tmp/run.log >&2; exit 1; }; \
    ! grep -q 'Fetching Rust evaluator' /tmp/run.log; \
    PATH=/opt/quint/node/bin:$PATH npm --version; \
    /opt/quint/libexec/busybox --list | grep -qx unzip

# パッケージの tar は公開者の uid を持ち込むことがあるので root に揃える。
RUN mkdir -p /out/opt /out/usr/local/bin \
 && cp -a /opt/quint /out/opt/quint \
 && cp -a /usr/local/bin/quint /out/usr/local/bin/quint \
 && chown -R 0:0 /out

# overlay: どの glibc の base にも載る。
FROM scratch
COPY --from=build /out /
