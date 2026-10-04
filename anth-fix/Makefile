.PHONY: build build-docker clean verify setup

PLUGIN_NAME    := secure-policy-plugin-anthfix
BIFROST_CORE   := v1.10.4
GO_VERSION     := 1.27.0
OUTPUT         := build/$(PLUGIN_NAME).so

# Build via Docker (works from Mac — spins up a linux/amd64 container)
build-docker:
	@echo "Building $(PLUGIN_NAME) via Docker (linux/amd64)..."
	@mkdir -p build
	docker run --rm \
		--platform linux/amd64 \
		-v $(PWD):/plugin \
		-w /plugin \
		golang:$(GO_VERSION) \
		sh -c "GOOS=linux GOARCH=amd64 CGO_ENABLED=1 GOAMD64=v1 \
			go build -trimpath -buildmode=plugin -mod=vendor \
			-o $(OUTPUT) main.go && strip $(OUTPUT)"
	@echo "Plugin built and stripped: $(OUTPUT)"

# Direct build — only works if a linux/amd64 C cross-toolchain is installed
build:
	@echo "Building $(PLUGIN_NAME) for linux/amd64 (native toolchain required)..."
	@mkdir -p build
	GOOS=linux GOARCH=amd64 CGO_ENABLED=1 GOAMD64=v1 \
		go build -trimpath -buildmode=plugin -mod=vendor \
		-o $(OUTPUT) main.go
	@echo "Plugin built: $(OUTPUT)"

verify:
	@echo "Verifying embedded bifrost/core version..."
	@go version -m $(OUTPUT) | grep "maximhq/bifrost/core" | tee /tmp/plugin-core-version.txt
	@grep -q "$(BIFROST_CORE)" /tmp/plugin-core-version.txt && \
		echo "OK: matches $(BIFROST_CORE)" || \
		(echo "MISMATCH: expected $(BIFROST_CORE), see above" && exit 1)

setup:
	@echo "Downloading and vendoring dependencies..."
	go mod tidy
	go mod vendor
	@echo "Vendor directory ready."

clean:
	@rm -rf build vendor
