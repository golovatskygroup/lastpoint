#!/bin/bash
set -e

echo "=== HTTP Server Benchmark ==="
echo "Date: $(date)"
echo "Machine: $(uname -a)"
echo ""

# Build Go servers
echo "Building Go servers..."
go build -o go_http1 go_http1.go
go build -o go_http2 go_http2.go

# Use existing Pony binary
echo "Pony binary already built"

echo ""
echo "============================================"
echo "Test Configuration:"
echo "  - Duration: 30 seconds per test"
echo "  - Connections: 100"
echo "  - Threads: 4 (wrk)"
echo "  - Payload: 'Hello, World!' (13 bytes)"
echo "============================================"
echo ""

# Function to run wrk benchmark
run_wrk() {
    local name=$1
    local url=$2

    echo "--- $name ---"
    wrk -t4 -c100 -d30s --latency "$url" 2>&1 | tee /tmp/wrk_${name}.txt
    echo ""
}

# Function to run hey benchmark
run_hey() {
    local name=$1
    local url=$2
    local extra_args=$3

    echo "--- $name ---"
    hey -z 30s -c 100 $extra_args "$url" 2>&1 | tee /tmp/hey_${name}.txt
    echo ""
}

# Function to cleanup servers
cleanup() {
    pkill -f "./http_server" 2>/dev/null || true
    pkill -f "./go_http1" 2>/dev/null || true
    pkill -f "./go_http2" 2>/dev/null || true
}

trap cleanup EXIT

# ============================================
# PONY HTTP/1.1
# ============================================
echo "### PONY HTTP/1.1 ###"
./http_server --port 8081 > /tmp/pony_http1.log 2>&1 &
sleep 2

run_wrk "Pony_HTTP1.1" "http://127.0.0.1:8081/"
run_hey "Pony_HTTP1.1" "http://127.0.0.1:8081/"

cleanup
sleep 1

# ============================================
# PONY HTTP/2 (with TLS)
# ============================================
echo "### PONY HTTP/2 (TLS) ###"
./http_server --port 8443 --tls-enabled > /tmp/pony_http2.log 2>&1 &
sleep 2

# HTTP/2 via hey (supports TLS + HTTP/2)
run_hey "Pony_HTTP2" "https://127.0.0.1:8443/" ""

cleanup
sleep 1

# ============================================
# GO HTTP/1.1
# ============================================
echo "### GO HTTP/1.1 ###"
./go_http1 > /tmp/go_http1.log 2>&1 &
sleep 2

run_wrk "Go_HTTP1.1" "http://127.0.0.1:9081/"
run_hey "Go_HTTP1.1" "http://127.0.0.1:9081/"

cleanup
sleep 1

# ============================================
# GO HTTP/2 (with TLS)
# ============================================
echo "### GO HTTP/2 (TLS) ###"
./go_http2 > /tmp/go_http2.log 2>&1 &
sleep 2

run_hey "Go_HTTP2" "https://127.0.0.1:9443/" ""

cleanup
sleep 1

# ============================================
# SUMMARY
# ============================================
echo ""
echo "============================================"
echo "BENCHMARK SUMMARY"
echo "============================================"
echo ""

extract_wrk_rps() {
    grep "Requests/sec:" /tmp/wrk_$1.txt | awk '{print $2}'
}

extract_wrk_latency() {
    grep "Latency" /tmp/wrk_$1.txt | head -1 | awk '{print $2}'
}

extract_hey_rps() {
    grep "Requests/sec:" /tmp/hey_$1.txt | awk '{print $2}'
}

extract_hey_latency() {
    grep "Average:" /tmp/hey_$1.txt | head -1 | awk '{print $2}'
}

echo "Requests/sec (wrk - higher is better):"
echo "  Pony HTTP/1.1: $(extract_wrk_rps Pony_HTTP1.1)"
echo "  Go   HTTP/1.1: $(extract_wrk_rps Go_HTTP1.1)"
echo ""

echo "Requests/sec (hey - higher is better):"
echo "  Pony HTTP/1.1: $(extract_hey_rps Pony_HTTP1.1)"
echo "  Pony HTTP/2:   $(extract_hey_rps Pony_HTTP2)"
echo "  Go   HTTP/1.1: $(extract_hey_rps Go_HTTP1.1)"
echo "  Go   HTTP/2:   $(extract_hey_rps Go_HTTP2)"
echo ""

echo "Latency (wrk avg - lower is better):"
echo "  Pony HTTP/1.1: $(extract_wrk_latency Pony_HTTP1.1)"
echo "  Go   HTTP/1.1: $(extract_wrk_latency Go_HTTP1.1)"
echo ""

echo "Latency (hey avg - lower is better):"
echo "  Pony HTTP/1.1: $(extract_hey_latency Pony_HTTP1.1)"
echo "  Pony HTTP/2:   $(extract_hey_latency Pony_HTTP2)"
echo "  Go   HTTP/1.1: $(extract_hey_latency Go_HTTP1.1)"
echo "  Go   HTTP/2:   $(extract_hey_latency Go_HTTP2)"
echo ""

echo "============================================"
echo "Full results in /tmp/"
echo "============================================"
