FROM golang:1.25 AS build

WORKDIR /src

# Minimal module definition for this standalone webhook
COPY security-harderner.go /src/security-harderner.go

RUN set -eux; \
  go mod init security-hardener || true; \
  go mod tidy; \
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o /out/security-hardener /src/security-harderner.go

FROM gcr.io/distroless/static-debian12:nonroot

WORKDIR /

COPY --from=build /out/security-hardener /security-hardener

EXPOSE 8443

# Expects TLS secret mounted at /tls/tls.crt and /tls/tls.key
ENTRYPOINT ["/security-hardener"]
