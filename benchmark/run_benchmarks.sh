#!/bin/bash
set -e

cd "$(dirname "$0")/.."

echo "=== Professional HTTP Server Benchmark ==="
echo "Date: $(date)"
echo "Machine: $(uname -a)"
echo "CPU: $(sysctl -n hw.model 2>/dev/null || echo 'Unknown')"
echo "Cores: $(sysctl -n hw.ncpu 2>/dev/null || echo 'Unknown')"
echo "Memory: $(($(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024)) GB"
echo ""

# Benchmark configuration
DURATION="30s"
CONNECTIONS=100
THREADS=4

# Build Go servers
echo "Building Go servers..."
cd benchmark
go build -o go_http1 go_http1.go
go build -o go_http2 go_http2.go
cd ..

echo ""
echo "============================================"
echo "Benchmark Configuration"
echo "============================================"
echo "Duration: $DURATION"
echo "Connections: $CONNECTIONS"
echo "Threads: $THREADS (wrk)"
echo "Endpoint: /ping (returns 'PONG')"
echo "Payload: ~4 bytes"
echo ""

# Cleanup function
cleanup() {
    pkill -9 -f "http_server" 2>/dev/null || true
    pkill -9 -f "go_http1" 2>/dev/null || true
    pkill -9 -f "go_http2" 2>/dev/null || true
    sleep 1
}

trap cleanup EXIT

# Function to extract wrk results
extract_wrk_results() {
    local file=$1
    echo "wrk Results:"
    grep "Requests/sec:" "$file" | sed 's/^/  /'
    grep "Latency" "$file" | head -1 | sed 's/^/  /'
    grep "Transfer/sec:" "$file" | sed 's/^/  /'
}

# Function to extract hey results
extract_hey_results() {
    local file=$1
    echo "hey Results:"
    grep "Requests/sec:" "$file" | sed 's/^/  /'
    grep "Average:" "$file" | head -1 | sed 's/^/  /'
    grep "99%" "$file" | head -1 | sed 's/^/  /'
}

# ============================================
# PONY HTTP/1.1 Benchmark
# ============================================
echo ""
echo "============================================"
echo "PONY HTTP/1.1 (Port 8081)"
echo "============================================"
cleanup
./http_server --port 8081 --log-level error > /tmp/bench_pony_http1.log 2>&1 &
sleep 2

echo "Running wrk..."
wrk -t$THREADS -c$CONNECTIONS -d$DURATION --latency http://127.0.0.1:8081/ping > /tmp/wrk_pony_http1.txt 2>&1
extract_wrk_results /tmp/wrk_pony_http1.txt

echo ""
echo "Running hey..."
hey -z $DURATION -c $CONNECTIONS http://127.0.0.1:8081/ping > /tmp/hey_pony_http1.txt 2>&1
extract_hey_results /tmp/hey_pony_http1.txt

cleanup

# ============================================
# GO HTTP/1.1 Benchmark
# ============================================
echo ""
echo "============================================"
echo "GO HTTP/1.1 (Port 9081)"
echo "============================================"
cd benchmark
./go_http1 > /tmp/bench_go_http1.log 2>&1 &
cd ..
sleep 2

echo "Running wrk..."
wrk -t$THREADS -c$CONNECTIONS -d$DURATION --latency http://127.0.0.1:9081/ > /tmp/wrk_go_http1.txt 2>&1
extract_wrk_results /tmp/wrk_go_http1.txt

echo ""
echo "Running hey..."
hey -z $DURATION -c $CONNECTIONS http://127.0.0.1:9081/ > /tmp/hey_go_http1.txt 2>&1
extract_hey_results /tmp/hey_go_http1.txt

cleanup

# ============================================
# PONY HTTP/2 Benchmark (TLS)
# ============================================
echo ""
echo "============================================"
echo "PONY HTTP/2 with TLS (Port 8443)"
echo "============================================"
./http_server --port 8443 --tls-enabled --log-level error > /tmp/bench_pony_http2.log 2>&1 &
sleep 2

echo "Running hey (HTTP/2)..."
hey -z $DURATION -c $CONNECTIONS https://127.0.0.1:8443/ping > /tmp/hey_pony_http2.txt 2>&1
extract_hey_results /tmp/hey_pony_http2.txt

cleanup

# ============================================
# GO HTTP/2 Benchmark (TLS)
# ============================================
echo ""
echo "============================================"
echo "GO HTTP/2 with TLS (Port 9443)"
echo "============================================"
cd benchmark
./go_http2 > /tmp/bench_go_http2.log 2>&1 &
cd ..
sleep 2

echo "Running hey (HTTP/2)..."
hey -z $DURATION -c $CONNECTIONS https://127.0.0.1:9443/ > /tmp/hey_go_http2.txt 2>&1
extract_hey_results /tmp/hey_go_http2.txt

cleanup

# ============================================
# SUMMARY TABLE
# ============================================
echo ""
echo ""
echo "============================================"
echo "BENCHMARK SUMMARY"
echo "============================================"
echo ""

# Extract RPS values
PONY_HTTP1_WRK_RPS=$(grep "Requests/sec:" /tmp/wrk_pony_http1.txt | awk '{print $2}')
GO_HTTP1_WRK_RPS=$(grep "Requests/sec:" /tmp/wrk_go_http1.txt | awk '{print $2}')
PONY_HTTP1_HEY_RPS=$(grep "Requests/sec:" /tmp/hey_pony_http1.txt | awk '{print $2}')
GO_HTTP1_HEY_RPS=$(grep "Requests/sec:" /tmp/hey_go_http1.txt | awk '{print $2}')
PONY_HTTP2_RPS=$(grep "Requests/sec:" /tmp/hey_pony_http2.txt | awk '{print $2}')
GO_HTTP2_RPS=$(grep "Requests/sec:" /tmp/hey_go_http2.txt | awk '{print $2}')

echo "Requests/sec (wrk - HTTP/1.1):"
printf "  %-20s %10s\n" "Pony HTTP/1.1:" "$PONY_HTTP1_WRK_RPS"
printf "  %-20s %10s\n" "Go HTTP/1.1:" "$GO_HTTP1_WRK_RPS"
if [ -n "$PONY_HTTP1_WRK_RPS" ] && [ -n "$GO_HTTP1_WRK_RPS" ]; then
    PONY_WRK_PCT=$(echo "scale=1; ($PONY_HTTP1_WRK_RPS / $GO_HTTP1_WRK_RPS - 1) * 100" | bc 2>/dev/null || echo "N/A")
    echo "  Pony vs Go: ${PONY_WRK_PCT}%"
fi
echo ""

echo "Requests/sec (hey - HTTP/1.1):"
printf "  %-20s %10s\n" "Pony HTTP/1.1:" "$PONY_HTTP1_HEY_RPS"
printf "  %-20s %10s\n" "Go HTTP/1.1:" "$GO_HTTP1_HEY_RPS"
if [ -n "$PONY_HTTP1_HEY_RPS" ] && [ -n "$GO_HTTP1_HEY_RPS" ]; then
    PONY_HEY_PCT=$(echo "scale=1; ($PONY_HTTP1_HEY_RPS / $GO_HTTP1_HEY_RPS - 1) * 100" | bc 2>/dev/null || echo "N/A")
    echo "  Pony vs Go: ${PONY_HEY_PCT}%"
fi
echo ""

echo "Requests/sec (hey - HTTP/2 TLS):"
printf "  %-20s %10s\n" "Pony HTTP/2:" "$PONY_HTTP2_RPS"
printf "  %-20s %10s\n" "Go HTTP/2:" "$GO_HTTP2_RPS"
if [ -n "$PONY_HTTP2_RPS" ] && [ -n "$GO_HTTP2_RPS" ]; then
    PONY_H2_PCT=$(echo "scale=1; ($PONY_HTTP2_RPS / $GO_HTTP2_RPS - 1) * 100" | bc 2>/dev/null || echo "N/A")
    echo "  Pony vs Go: ${PONY_H2_PCT}%"
fi
echo ""

echo "============================================"
echo "Detailed results saved in /tmp/"
echo "============================================"
