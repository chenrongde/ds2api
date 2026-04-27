FROM node:24 AS webui-builder

WORKDIR /app/webui
COPY webui/package.json webui/package-lock.json ./
RUN npm ci
COPY config.example.json /app/config.example.json
COPY webui ./
RUN npm run build

FROM golang:1.26 AS go-builder
WORKDIR /app
ARG TARGETOS
ARG TARGETARCH
ARG BUILD_VERSION
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN set -eux; \
    GOOS="${TARGETOS:-$(go env GOOS)}"; \
    GOARCH="${TARGETARCH:-$(go env GOARCH)}"; \
    BUILD_VERSION_RESOLVED="${BUILD_VERSION:-}"; \
    if [ -z "${BUILD_VERSION_RESOLVED}" ] && [ -f VERSION ]; then BUILD_VERSION_RESOLVED="$(cat VERSION | tr -d "[:space:]")"; fi; \
    CGO_ENABLED=0 GOOS="${GOOS}" GOARCH="${GOARCH}" go build -buildvcs=false -ldflags="-s -w -X ds2api/internal/version.BuildVersion=${BUILD_VERSION_RESOLVED}" -o /out/ds2api ./cmd/ds2api

FROM busybox:1.36.1-musl AS busybox-tools

FROM debian:bookworm-slim AS runtime-base
WORKDIR /app
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=busybox-tools /bin/busybox /usr/local/bin/busybox
EXPOSE 5001

FROM runtime-base AS runtime-from-source
COPY --from=go-builder /out/ds2api /usr/local/bin/ds2api

COPY --from=go-builder /app/config.example.json /app/config.example.json
COPY --from=webui-builder /app/static/admin /app/static/admin

FROM busybox-tools AS dist-extract
ARG TARGETARCH
COPY dist/docker-input/linux_amd64.tar.gz /tmp/ds2api_linux_amd64.tar.gz
COPY dist/docker-input/linux_arm64.tar.gz /tmp/ds2api_linux_arm64.tar.gz
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) ARCHIVE="/tmp/ds2api_linux_amd64.tar.gz" ;; \
      arm64) ARCHIVE="/tmp/ds2api_linux_arm64.tar.gz" ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    tar -xzf "${ARCHIVE}" -C /tmp; \
    PKG_DIR="$(find /tmp -maxdepth 1 -type d -name "ds2api_*_linux_${TARGETARCH}" | head -n1)"; \
    test -n "${PKG_DIR}"; \
    mkdir -p /out/static; \
    cp "${PKG_DIR}/ds2api" /out/ds2api; \
    cp "${PKG_DIR}/config.example.json" /out/config.example.json; \
    cp -R "${PKG_DIR}/static/admin" /out/static/admin

FROM runtime-base AS runtime-from-dist
COPY --from=dist-extract /out/ds2api /usr/local/bin/ds2api

COPY --from=dist-extract /out/config.example.json /app/config.example.json
COPY --from=dist-extract /out/static/admin /app/static/admin

FROM runtime-from-source AS final

# ============== 以下为新增内容 ==============

# 1. 复制你仓库里的 config.json 到镜像
COPY config.json /app/config.json

# 2. 创建启动脚本：启动时自动把配置文件复制到 /data/ 目录
RUN echo '#!/bin/sh' > /usr/local/bin/start.sh && \
    echo 'mkdir -p /data' >> /usr/local/bin/start.sh && \
    echo 'cp /app/config.json /data/config.json' >> /usr/local/bin/start.sh && \
    echo 'exec /usr/local/bin/ds2api' >> /usr/local/bin/start.sh && \
    chmod +x /usr/local/bin/start.sh

# 3. 用启动脚本替换原来的 CMD
CMD ["/usr/local/bin/start.sh"]
