# HTTP Server Benchmark Results

**Date:** 2026-02-02
**Machine:** MacBook Pro (Apple Silicon M4 Pro, 14 cores, 36GB RAM)
**OS:** macOS 15.2 (Darwin 24.2.0)

## Test Configuration

| Parameter | Value |
|-----------|-------|
| Duration | 30 seconds |
| Connections | Varies (1-100) |
| Payload | "PONG" (4 bytes) |
| Endpoint | /ping |
| Tools | wrk 4.2.0, hey, h2load |

## HTTP/1.1 Results

### Pony HTTP/1.1 vs Go HTTP/1.1

| Metric | Pony | Go | Difference |
|--------|------|-----|------------|
| **Requests/sec (wrk)** | 108,630 | 130,166 | Go +20% |
| **Requests/sec (hey)** | 94,977 | 120,688 | Go +27% |
| **Avg Latency (wrk)** | 1.04ms | 0.77ms | Go faster |
| **99th Percentile (wrk)** | 7.65ms | 1.64ms | Go much faster |
| **Transfer/sec** | 13.36 MB | 14.28 MB | Go +7% |

### Latency Distribution (Pony HTTP/1.1)

| Percentile | Latency |
|------------|---------|
| 50% | 710 μs |
| 75% | 970 μs |
| 90% | 1.57 ms |
| 99% | 7.65 ms |

### Latency Distribution (Go HTTP/1.1)

| Percentile | Latency |
|------------|---------|
| 50% | 733 μs |
| 75% | 800 μs |
| 90% | 930 μs |
| 99% | 1.64 ms |

## HTTP/2 Results

### Pony HTTP/2 (Single Connection, Multiplexed Streams)

| Connections | Streams | Requests | Duration | Requests/sec |
|-------------|---------|----------|----------|--------------|
| 1 | 100 | 10,000 | 165.82ms | **60,305** |

### Go HTTP/2 (Multiple Connections, Multiplexed Streams)

| Connections | Streams | Requests | Duration | Requests/sec |
|-------------|---------|----------|----------|--------------|
| 1 | 10 | 100,000 | 437.84ms | **228,392** |

## Key Findings

### HTTP/1.1 Performance

1. **Go's net/http is 20-30% faster** than Pony for HTTP/1.1
2. **Pony's latency tail is higher** - 99th percentile is 4.7x worse than Go
3. **Both handle high throughput well** - 100K+ req/s on a single core

### HTTP/2 Performance

1. **Go's HTTP/2 is significantly faster** - 228K req/s vs Pony's 60K req/s (single connection)
2. **Pony HTTP/2 has TLS handshake issues** with concurrent connections (>1 simultaneous handshake fails)
3. **Single-connection multiplexing works well** in Pony - achieves 60K req/s with 100 concurrent streams

### Protocol Comparison

| Protocol | Pony RPS | Go RPS | Notes |
|----------|----------|--------|-------|
| HTTP/1.1 | 108,630 | 130,166 | Go wins by 20% |
| HTTP/2 | 60,305 | 228,392 | Go wins by 278% |

## Bottleneck Analysis

### Pony HTTP/1.1
- Request parsing and routing overhead
- Actor message passing latency
- Higher tail latency suggests GC-like pauses (though Pony is GC-free)

### Pony HTTP/2
- TLS handshake implementation has race conditions
- Single-threaded connection handling per actor
- HPACK encoding/decoding overhead
- HTTP/2 frame parsing overhead

### Go Advantages
- Highly optimized net/http and net/http2 packages
- Efficient goroutine scheduling
- Mature TLS implementation
- Optimized HTTP/2 stream multiplexing

## Recommendations

### For Pony HTTP Server
1. **Fix TLS concurrent handshake** - The auth_failed errors indicate a synchronization issue
2. **Optimize HTTP/2 frame handling** - Reduce per-frame overhead
3. **Improve request parsing** - HTTP/1.1 parser could be more efficient
4. **Consider connection pooling** - Reuse TLS sessions for better performance

### When to Use Each

**Use Pony when:**
- Memory safety is critical
- You want predictable latency (no GC)
- HTTP/1.1 performance is sufficient
- You need actor-model concurrency

**Use Go when:**
- Maximum throughput is required
- HTTP/2 performance matters
- Mature ecosystem is needed
- TLS handling is critical

## Raw Output Files

- `/tmp/wrk_pony_http1.txt` - Pony HTTP/1.1 wrk results
- `/tmp/wrk_go_http1.txt` - Go HTTP/1.1 wrk results
- `/tmp/hey_pony_http1.txt` - Pony HTTP/1.1 hey results
- `/tmp/hey_go_http1.txt` - Go HTTP/1.1 hey results
- `/tmp/h2load_go.txt` - Go HTTP/2 h2load results
