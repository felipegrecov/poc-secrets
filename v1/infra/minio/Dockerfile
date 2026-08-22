FROM golang:1.25.3-alpine3.22 AS minio-builder
ARG MINIO_VERSION=RELEASE.2025-10-15T17-29-55Z
ARG MINIO_COMMIT=9e49d5e7a648f00e26f2246f4dc28e6b07f8c84a
RUN apk add --no-cache git
RUN git clone --branch "${MINIO_VERSION}" --depth 1 https://github.com/minio/minio.git /src
WORKDIR /src
RUN test "$(git rev-parse HEAD)" = "${MINIO_COMMIT}"
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/minio

FROM golang:1.25.3-alpine3.22 AS mc-builder
ARG MC_VERSION=RELEASE.2025-08-13T08-35-41Z
ARG MC_COMMIT=7394ce0dd2a80935aded936b09fa12cbb3cb8096
RUN apk add --no-cache git
RUN git clone --branch "${MC_VERSION}" --depth 1 https://github.com/minio/mc.git /src
WORKDIR /src
RUN test "$(git rev-parse HEAD)" = "${MC_COMMIT}"
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/mc

FROM alpine:3.22.1
RUN apk add --no-cache ca-certificates && \
    addgroup -g 10001 minio && \
    adduser -D -H -u 10001 -G minio minio
COPY --from=minio-builder /out/minio /usr/local/bin/minio
COPY --from=mc-builder /out/mc /usr/local/bin/mc
USER 10001:10001
EXPOSE 9000 9001
ENTRYPOINT ["/usr/local/bin/minio"]
CMD ["server", "/data", "--console-address", ":9001"]
