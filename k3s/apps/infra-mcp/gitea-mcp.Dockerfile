FROM golang:1.24-alpine AS build
RUN go install gitea.com/gitea/gitea-mcp@v1.1.0

FROM alpine:3.21
RUN apk add --no-cache ca-certificates
COPY --from=build /go/bin/gitea-mcp /usr/local/bin/gitea-mcp
USER 65534:65534
ENTRYPOINT ["gitea-mcp"]
