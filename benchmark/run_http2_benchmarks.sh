#!/bin/bash
set -e

cd "$(dirname "$0")/.."

echo "=== HTTP/2 Benchmark with TLS ==="
echo "Date: $(date)"
echo ""

DURATION="30s"
CONNECTIONS=100

cleanup() {
    pkill -9 -f "http_server" 2>/dev/null || true
    pkill -9 -f "go_http2" 2>/dev/null || true
    sleep 1
}

trap cleanup EXIT

# ============================================
# PONY HTTP/2 Benchmark
# ============================================
echo ""
echo "============================================"
echo "PONY HTTP/2 with TLS (Port 8443)"
echo "============================================"
./http_server --port 8443 --tls-enabled --tls-cert-file cert.pem --tls-key-file key.pem --log-level error > /tmp/bench_pony_h2.log 2>&1 &
sleep 2

echo "Testing with curl (HTTP/2)..."
curl -k --http2 https://127.0.0.1:8443/ping

echo ""
echo "Running hey with HTTP/2 support..."
# hey doesn't support HTTP/2 well, use h2load if available
if which h2load > /dev/null 2>&1; then
    echo "Using h2load..."
    h2load -n100000 -c100 -m10 https://127.0.0.1:8443/ping 2>&1 | tee /tmp/h2load_pony.txt
else
    echo "h2load not available, using hey with TLS skip..."
    hey -z $DURATION -c $CONNECTIONS -disable-keepalive false https://127.0.0.1:8443/ping 2>&1 | tee /tmp/hey_pony_h2_fixed.txt
fi

cleanup

# ============================================
# GO HTTP/2 Benchmark
# ============================================
echo ""
echo "============================================"
echo "GO HTTP/2 with TLS (Port 9443)"
echo "============================================"
cd benchmark
./go_http2 > /tmp/bench_go_h2.log 2>&1 &
cd ..
sleep 2

echo "Testing with curl (HTTP/2)..."
curl -k --http2 https://127.0.0.1:9443/

echo ""
echo "Running hey with HTTP/2 support..."
if which h2load > /dev/null 2>&1; then
    echo "Using h2load..."
    h2load -n100000 -c100 -m10 https://127.0.0.1:9443/ 2>&1 | tee /tmp/h2load_go.txt
else
    hey -z $DURATION -c $CONNECTIONS https://127.0.0.1:9443/ 2>&1 | tee /tmp/hey_go_h2_fixed.txt
fi

cleanup

echo ""
echo "============================================"
echo "HTTP/2 Benchmark Complete"
echo "============================================"
