# Stages: deps -> test (docker build --target test .) | build -> runtime (default target)
FROM golang:1.27-alpine AS deps
ENV CGO_ENABLED=0
WORKDIR /src
COPY go.* ./
COPY *.go ./
# go mod tidy resolves the latest compatible deps and writes go.sum when it is not committed yet.
RUN go mod tidy && go mod download

# Formatting, golangci-lint (.golangci.yml), then unit tests with coverage (*_test.go).
# CI runs this before building the image.
FROM deps AS test
ARG GOLANGCI_LINT_VERSION=v2.15.0
# Built from source with this image's Go, so the linter always understands the Go version we compile with.
RUN go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@${GOLANGCI_LINT_VERSION}
COPY .golangci.yml ./
RUN unformatted="$(gofmt -l .)" && \
    if [ -n "$unformatted" ]; then echo "gofmt needed: $unformatted"; exit 1; fi && \
    go vet ./... && \
    golangci-lint run ./... && \
    mkdir -p coverage && \
    go test -count=1 -covermode=atomic -coverprofile=coverage/coverage.out ./... && \
    go tool cover -func=coverage/coverage.out

# Coverage report for SonarCloud: docker build --target coverage --output type=local,dest=out .
FROM scratch AS coverage
COPY --from=test /src/coverage/ /

FROM deps AS build
RUN go build -trimpath -ldflags="-s -w" -o /out/app .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/app /app
EXPOSE 8080
ENTRYPOINT ["/app"]
