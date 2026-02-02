# Pony HTTP/1.1 Server Makefile
# RFC 9112 compliant HTTP server implementation

# Default settings
CONFIG ?= release
HOST ?= 0.0.0.0
PORT ?= 8080
PONYC ?= /Users/nyarum/ponyc/build/debug/ponyc

# Directories
SRC_DIR = .
BUILD_DIR = build

# Compiler flags
ifeq ($(CONFIG),debug)
  PONYC_FLAGS = -d
else
  PONYC_FLAGS =
endif

# Default target
.PHONY: all build clean run test dev debug verify help

all: build

# Build the server
build:
	@echo "Building Pony HTTP/1.1 server ($(CONFIG) mode)..."
	@mkdir -p $(BUILD_DIR)
	$(PONYC) $(PONYC_FLAGS) $(SRC_DIR) -o $(BUILD_DIR)
	@echo "Build complete: $(BUILD_DIR)/http_server"

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	rm -rf $(BUILD_DIR)
	@echo "Clean complete"

# Run the server
run: build
	@echo "Starting server on $(HOST):$(PORT)..."
	@echo "Press Ctrl+C to stop"
	@echo ""
	$(BUILD_DIR)/http_server $(HOST) $(PORT)

# Development mode (debug build + run)
dev:
	@$(MAKE) CONFIG=debug build
	@echo "Starting server in debug mode..."
	$(BUILD_DIR)/http_server $(HOST) $(PORT)

# Debug build only
debug:
	@$(MAKE) CONFIG=debug build

# Quick verification build
verify: clean build
	@echo ""
	@echo "Verification complete!"
	@ls -lh $(BUILD_DIR)/http_server

# Test all endpoints (requires running server)
test:
	@echo "Testing HTTP server endpoints..."
	@echo "Note: Server must be running on $(HOST):$(PORT)"
	@echo ""
	@echo "=== Test 1: GET / ==="
	@curl -s -w "\nHTTP Status: %{http_code}\n" http://$(HOST):$(PORT)/ || echo "FAILED"
	@echo ""
	@echo "=== Test 2: GET /ping ==="
	@curl -s -w "\nHTTP Status: %{http_code}\n" http://$(HOST):$(PORT)/ping || echo "FAILED"
	@echo ""
	@echo "=== Test 3: GET /time ==="
	@curl -s -w "\nHTTP Status: %{http_code}\n" http://$(HOST):$(PORT)/time || echo "FAILED"
	@echo ""
	@echo "=== Test 4: GET /echo/hello ==="
	@curl -s -w "\nHTTP Status: %{http_code}\n" http://$(HOST):$(PORT)/echo/hello || echo "FAILED"
	@echo ""
	@echo "=== Test 5: GET /notfound (expect 404) ==="
	@curl -s -w "\nHTTP Status: %{http_code}\n" http://$(HOST):$(PORT)/notfound || echo "FAILED"
	@echo ""
	@echo "=== Test 6: POST / ==="
	@curl -s -w "\nHTTP Status: %{http_code}\n" -X POST -d "test data" http://$(HOST):$(PORT)/ || echo "FAILED"
	@echo ""
	@echo "=== Test 7: PUT / ==="
	@curl -s -w "\nHTTP Status: %{http_code}\n" -X PUT http://$(HOST):$(PORT)/ || echo "FAILED"
	@echo ""
	@echo "=== Test 8: DELETE / ==="
	@curl -s -w "\nHTTP Status: %{http_code}\n" -X DELETE http://$(HOST):$(PORT)/ || echo "FAILED"
	@echo ""
	@echo "=== Test 9: Connection keep-alive ==="
	@curl -s -w "\nHTTP Status: %{http_code}\n" -H "Connection: keep-alive" http://$(HOST):$(PORT)/ping || echo "FAILED"
	@echo ""
	@echo "All tests complete!"

# Verbose test with headers
verbose-test:
	@echo "Testing with verbose output..."
	@echo ""
	@curl -v http://$(HOST):$(PORT)/ping 2>&1 | head -20

# Check code compiles without errors
check:
	@echo "Checking code for compilation errors..."
	$(PONYC) --checktree $(SRC_DIR) 2>&1 | head -20

# Show project structure
structure:
	@echo "Project structure:"
	@find $(SRC_DIR) -name "*.pony" -o -name "*.json" -o -name "Makefile" | grep -v $(BUILD_DIR) | sort

# Help
help:
	@echo "Pony HTTP/1.1 Server - Makefile targets:"
	@echo ""
	@echo "Build targets:"
	@echo "  make build        - Build the server (default: release)"
	@echo "  make debug        - Build in debug mode"
	@echo "  make clean        - Remove build artifacts"
	@echo "  make verify       - Clean build and verify"
	@echo ""
	@echo "Run targets:"
	@echo "  make run          - Build and run the server"
	@echo "  make dev          - Debug build and run"
	@echo ""
	@echo "Test targets (requires running server):"
	@echo "  make test         - Test all endpoints"
	@echo "  make verbose-test - Test with verbose output"
	@echo ""
	@echo "Other targets:"
	@echo "  make check        - Check code compiles"
	@echo "  make structure    - Show project structure"
	@echo "  make help         - Show this help"
	@echo ""
	@echo "Variables:"
	@echo "  CONFIG=debug|release  - Build configuration (default: release)"
	@echo "  HOST=hostname         - Server bind address (default: 0.0.0.0)"
	@echo "  PORT=number           - Server port (default: 8080)"
	@echo "  PONYC=path            - Path to ponyc compiler"
