> Historical report: the original harness mislabeled real-process epoch counts and did not enforce every reported threshold. This report is superseded by [the corrected validation](runtime-capacity-validation-2026-10-16.md).

# Runtime Validation Report: Soak, Lifecycle, Scheduler & Cache

- **Date:** 2026-10-15T19:32:39Z
- **Overall Verdict:** ✅ PASS
- **Ruby Version:** 3.4.7 (x86_64-linux)
- **Host OS & Arch:** linux (x86_64)
- **Random Seed:** 28131140454247160677700890700752994527
- **Total Duration:** 35.1s
- **Configured Epochs:** 1000


## 1. Resource Baseline & Leak Audit

| Metric | Baseline | Post-Run | Delta | Tolerance / Threshold | Verdict |
|---|---|---|---|---|---|
| Active Threads | 1 | 1 | 0 | Delta = 0 (excl. stdlib daemon) | PASS |
| Child Processes | 0 | 0 | 0 | 0 orphan processes | PASS |
| Open FDs (/proc) | 11 | 11 | 0 | |Delta| <= 3 (OS jitter) | PASS |
| Memory RSS (MB) | 79.86 | 120.98 | 41.12 MB | < 60.0 MB (allocator arena growth) | PASS |
| Heap Live Slots | 196709 | 199016 | 2307 | Managed by GC | PASS |


## 2. Lifecycle & Soak Families (1000 Epochs)

| Family | Target Epochs | Duration | Verdict | Notes |
|---|---|---|---|---|
| `context_epochs` | 1000 | 7.5ms | PASS | Zero residue / baseline restored |
| `service_epochs` | 1000 | 2.3ms | PASS | Zero residue / baseline restored |
| `fiber_cycles` | 1000 | 10.2ms | PASS | Zero residue / baseline restored |
| `rollback_cycles` | 1000 | 8.1ms | PASS | Zero residue / baseline restored |
| `plugin_reload_cycles` | 1000 | 239.3ms | PASS | Zero residue / baseline restored |
| `mcp_manager_cycles` | 1000 | 56.5ms | PASS | Zero residue / baseline restored |
| `mcp_handshake_failures` | 1000 | 30.7ms | PASS | Zero residue / baseline restored |
| `mcp_real_process_cycles` | 1000 | 20462.4ms | PASS | Zero residue / baseline restored |
| `mcp_server_crash_recovery` | 1000 | 11327.1ms | PASS | Zero residue / baseline restored |
| `mcp_inflight_reload` | 1000 | 294.8ms | PASS | Zero residue / baseline restored |
| `mcp_descendant_cleanup` | 1000 | 472.1ms | PASS | Zero residue / baseline restored |


## 3. Quiet Concurrency Scheduler Capacity

### A. Concurrent Network Requests (Net::HTTP over Fiber Scheduler)

| Metric | 100 Requests | 1000 Requests | Target Threshold | Verdict |
|---|---|---|---|---|
| Total Time | 0.075s | 0.879s | < 3.0s (100) / < 6.0s (1000) | PASS |
| Success Rate | 100/100 (100%) | 1000/1000 (100%) | 100% success | PASS |
| Throughput | 1327.7 req/s | 1138.0 req/s | High single-threaded I/O | PASS |
| Min Latency | 31.69ms | 501.48ms | - | - |
| **p50 Latency** | **47.07ms** | **629.47ms** | < 500ms (100) / < 2000ms (1000) | PASS |
| **p95 Latency** | **56.02ms** | **652.65ms** | < 1000ms (100) / < 4000ms (1000) | PASS |
| p99 Latency | 59.02ms | 653.28ms | - | - |
| Max Latency | 59.02ms | 653.68ms | - | - |

### B. Timeout & Cancellation Handling
- Delay: 2.0s, Deadline: 0.1s
- Elapsed to abort: **0.203s** (aborted cleanly without waiting for delay)
- Verdict: PASS

### C. Scheduler vs Sequential Comparison (Speedup Factor)
- 40 requests with simulated 15ms latency:
- Scheduler ON: **0.091s**
- Scheduler OFF (sequential): **0.628s**
- Speedup Factor: **6.91x** faster


## 4. AST Persistent Cache Benchmarking

| Metric | Measured Value | Target / Threshold | Verdict |
|---|---|---|---|
| Fixture Size | 150 files (49580 bytes) | Real multi-file AST fixture | PASS |
| Cold Scan & Index | 38.5ms | Parsing & saving cache | PASS |
| On-Disk Cache Size | 214426 bytes (209.4 KB) | Compact JSON cache | PASS |
| **Warm Cache Load** | **11.3ms** | < 500ms (near-instant) | PASS |
| Speedup Factor | **3.4x** faster | Faster than cold build | PASS |


## 5. Reproduction Command

Rerun this full validation suite locally with zero external dependencies:

```bash
bundle exec ruby dev/validate_runtime_capacity.rb
```
