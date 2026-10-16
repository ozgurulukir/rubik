# Runtime Capacity Validation

Lifecycle and benchmark observations below were generated at review commit `d4707c1`. Subsequent scheduler I/O protocol fixes have dedicated generic-socket and buffer-offset regressions; CI reruns the full command and uploads its report for each PR head.

Date: 2026-10-16T04:57:07Z

Overall verdict: **PASS**

Ruby: 3.4.7 (x86_64-linux); OS: linux; CPU: x86_64

Seed: 151; configured epochs: 1000; duration: 1019.05s

## Resources

Snapshots follow GC; threads exclude the stdlib timeout daemon. FD/RSS and process counts use Linux /proc; unavailable probes are INCONCLUSIVE. Ruby fibers count live Fiber objects; contexts count retained Context objects after GC.

| Metric | Baseline | Final | Delta | Tolerance | Verdict |
|---|---|---|---|---|---|
| threads | 1 | 1 | 0 | <= 0 | PASS |
| child_processes | 0 | 0 | 0 | <= 0 | PASS |
| ruby_fibers | 1 | 1 | 0 | <= 0 | PASS |
| child_contexts | 0 | 0 | 0 | <= 0 | PASS |
| open_fds | 6 | 6 | 0 | <= 3 | PASS |
| rss_kb | 81684 | 112120 | 30436 | <= 61440 | PASS |

## Lifecycle Soak

| Family | Actual epochs | Duration ms | Verdict | Violations |
|---|---|---|---|---|
| context_epochs | 1000 | 1631.1 | PASS |  |
| service_epochs | 1000 | 2109.3 | PASS |  |
| fiber_cycles | 1000 | 2323.6 | PASS |  |
| rollback_cycles | 1000 | 1842.6 | PASS |  |
| plugin_reload_cycles | 1000 | 2057.7 | PASS |  |
| mcp_manager_cycles | 1000 | 1851.7 | PASS |  |
| mcp_handshake_failures | 1000 | 287761.5 | PASS |  |
| mcp_real_process_cycles | 1000 | 259882.6 | PASS |  |
| mcp_server_crash_recovery | 1000 | 454589.5 | PASS |  |
| mcp_inflight_reload | 1 | 723.6 | PASS |  |
| mcp_descendant_cleanup | 1 | 402.7 | PASS |  |

### context_epochs resource samples

```json
[
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81764,
    "ruby_fibers": 1,
    "child_contexts": 0,
    "heap_live_slots": 196865,
    "epoch": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81764,
    "ruby_fibers": 1,
    "child_contexts": 2,
    "heap_live_slots": 196915,
    "epoch": 100,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81764,
    "ruby_fibers": 1,
    "child_contexts": 2,
    "heap_live_slots": 196917,
    "epoch": 200,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81780,
    "ruby_fibers": 1,
    "child_contexts": 2,
    "heap_live_slots": 196918,
    "epoch": 300,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81780,
    "ruby_fibers": 1,
    "child_contexts": 2,
    "heap_live_slots": 196919,
    "epoch": 400,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81796,
    "ruby_fibers": 1,
    "child_contexts": 2,
    "heap_live_slots": 196920,
    "epoch": 500,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81804,
    "ruby_fibers": 1,
    "child_contexts": 2,
    "heap_live_slots": 196921,
    "epoch": 600,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81808,
    "ruby_fibers": 1,
    "child_contexts": 2,
    "heap_live_slots": 196922,
    "epoch": 700,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81816,
    "ruby_fibers": 1,
    "child_contexts": 2,
    "heap_live_slots": 196923,
    "epoch": 800,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81816,
    "ruby_fibers": 1,
    "child_contexts": 2,
    "heap_live_slots": 196924,
    "epoch": 900,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81816,
    "ruby_fibers": 1,
    "child_contexts": 2,
    "heap_live_slots": 196925,
    "epoch": 1000,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81816,
    "ruby_fibers": 1,
    "child_contexts": 0,
    "heap_live_slots": 196907,
    "epoch": 1000
  }
]
```

### service_epochs resource samples

```json
[
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81992,
    "ruby_fibers": 1,
    "child_contexts": 0,
    "heap_live_slots": 196913,
    "epoch": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81992,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196970,
    "epoch": 100,
    "inverses": 5
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81992,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196971,
    "epoch": 200,
    "inverses": 5
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81992,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196972,
    "epoch": 300,
    "inverses": 5
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81992,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196973,
    "epoch": 400,
    "inverses": 5
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81992,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196974,
    "epoch": 500,
    "inverses": 5
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81992,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196975,
    "epoch": 600,
    "inverses": 5
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81992,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196976,
    "epoch": 700,
    "inverses": 5
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81992,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196977,
    "epoch": 800,
    "inverses": 5
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81992,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196978,
    "epoch": 900,
    "inverses": 5
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81992,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196979,
    "epoch": 1000,
    "inverses": 5
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81992,
    "ruby_fibers": 1,
    "child_contexts": 0,
    "heap_live_slots": 196933,
    "epoch": 1000
  }
]
```

### fiber_cycles resource samples

```json
[
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81992,
    "ruby_fibers": 1,
    "child_contexts": 0,
    "heap_live_slots": 196936,
    "epoch": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196965,
    "epoch": 100,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196966,
    "epoch": 200,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196967,
    "epoch": 300,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196968,
    "epoch": 400,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196969,
    "epoch": 500,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196970,
    "epoch": 600,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196971,
    "epoch": 700,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196972,
    "epoch": 800,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196973,
    "epoch": 900,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196974,
    "epoch": 1000,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 0,
    "heap_live_slots": 196959,
    "epoch": 1000
  }
]
```

### rollback_cycles resource samples

```json
[
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 0,
    "heap_live_slots": 196962,
    "epoch": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196989,
    "epoch": 100,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196990,
    "epoch": 200,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196991,
    "epoch": 300,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196992,
    "epoch": 400,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196993,
    "epoch": 500,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196994,
    "epoch": 600,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196995,
    "epoch": 700,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196996,
    "epoch": 800,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196997,
    "epoch": 900,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 196998,
    "epoch": 1000,
    "inverses": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 0,
    "heap_live_slots": 196982,
    "epoch": 1000
  }
]
```

### plugin_reload_cycles resource samples

```json
[
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 81996,
    "ruby_fibers": 1,
    "child_contexts": 0,
    "heap_live_slots": 196985,
    "epoch": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82000,
    "ruby_fibers": 1,
    "child_contexts": 2,
    "heap_live_slots": 197418,
    "epoch": 100,
    "inverses": 1,
    "active_component_fibers": 1
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82000,
    "ruby_fibers": 1,
    "child_contexts": 2,
    "heap_live_slots": 197420,
    "epoch": 200,
    "inverses": 1,
    "active_component_fibers": 1
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82000,
    "ruby_fibers": 1,
    "child_contexts": 2,
    "heap_live_slots": 197421,
    "epoch": 300,
    "inverses": 1,
    "active_component_fibers": 1
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82000,
    "ruby_fibers": 1,
    "child_contexts": 2,
    "heap_live_slots": 197422,
    "epoch": 400,
    "inverses": 1,
    "active_component_fibers": 1
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82000,
    "ruby_fibers": 1,
    "child_contexts": 2,
    "heap_live_slots": 197423,
    "epoch": 500,
    "inverses": 1,
    "active_component_fibers": 1
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82000,
    "ruby_fibers": 1,
    "child_contexts": 2,
    "heap_live_slots": 197424,
    "epoch": 600,
    "inverses": 1,
    "active_component_fibers": 1
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82004,
    "ruby_fibers": 1,
    "child_contexts": 2,
    "heap_live_slots": 197425,
    "epoch": 700,
    "inverses": 1,
    "active_component_fibers": 1
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82004,
    "ruby_fibers": 1,
    "child_contexts": 2,
    "heap_live_slots": 197426,
    "epoch": 800,
    "inverses": 1,
    "active_component_fibers": 1
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82004,
    "ruby_fibers": 1,
    "child_contexts": 2,
    "heap_live_slots": 197427,
    "epoch": 900,
    "inverses": 1,
    "active_component_fibers": 1
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82004,
    "ruby_fibers": 1,
    "child_contexts": 2,
    "heap_live_slots": 197428,
    "epoch": 1000,
    "inverses": 1,
    "active_component_fibers": 1
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82004,
    "ruby_fibers": 1,
    "child_contexts": 0,
    "heap_live_slots": 197356,
    "epoch": 1000
  }
]
```

### mcp_manager_cycles resource samples

```json
[
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82004,
    "ruby_fibers": 1,
    "child_contexts": 0,
    "heap_live_slots": 197359,
    "epoch": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82008,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 197455,
    "epoch": 100,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82016,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 197457,
    "epoch": 200,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82024,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 197458,
    "epoch": 300,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82032,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 197460,
    "epoch": 400,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82036,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 197461,
    "epoch": 500,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82044,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 197462,
    "epoch": 600,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82052,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 197463,
    "epoch": 700,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82060,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 197464,
    "epoch": 800,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82064,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 197466,
    "epoch": 900,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82072,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 197467,
    "epoch": 1000,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82072,
    "ruby_fibers": 1,
    "child_contexts": 0,
    "heap_live_slots": 197447,
    "epoch": 1000
  }
]
```

### mcp_handshake_failures resource samples

```json
[
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 82072,
    "ruby_fibers": 1,
    "child_contexts": 0,
    "heap_live_slots": 197450,
    "epoch": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 84248,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198322,
    "epoch": 100,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 84308,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198323,
    "epoch": 200,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 83992,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198324,
    "epoch": 300,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 80124,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198325,
    "epoch": 400,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 80220,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198326,
    "epoch": 500,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 80316,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198327,
    "epoch": 600,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 80168,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198328,
    "epoch": 700,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 80204,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198329,
    "epoch": 800,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 80236,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198330,
    "epoch": 900,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 80252,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198331,
    "epoch": 1000,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 80264,
    "ruby_fibers": 1,
    "child_contexts": 0,
    "heap_live_slots": 198301,
    "epoch": 1000
  }
]
```

### mcp_real_process_cycles resource samples

```json
[
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 80276,
    "ruby_fibers": 1,
    "child_contexts": 0,
    "heap_live_slots": 198300,
    "epoch": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 79008,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198352,
    "epoch": 100,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 79020,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198353,
    "epoch": 200,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 78840,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198354,
    "epoch": 300,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 78848,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198355,
    "epoch": 400,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 78840,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198356,
    "epoch": 500,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 78848,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198357,
    "epoch": 600,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 78792,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198358,
    "epoch": 700,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 78804,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198359,
    "epoch": 800,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 78812,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198360,
    "epoch": 900,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 78816,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198361,
    "epoch": 1000,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 78820,
    "ruby_fibers": 1,
    "child_contexts": 0,
    "heap_live_slots": 198328,
    "epoch": 1000
  }
]
```

### mcp_server_crash_recovery resource samples

```json
[
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 78820,
    "ruby_fibers": 1,
    "child_contexts": 0,
    "heap_live_slots": 198327,
    "epoch": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 78856,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198387,
    "epoch": 100,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 78920,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198388,
    "epoch": 200,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 78940,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198389,
    "epoch": 300,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 78956,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198390,
    "epoch": 400,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 78960,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198391,
    "epoch": 500,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 78904,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198392,
    "epoch": 600,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 78912,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198393,
    "epoch": 700,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 78920,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198394,
    "epoch": 800,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 75616,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198395,
    "epoch": 900,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 77240,
    "ruby_fibers": 1,
    "child_contexts": 1,
    "heap_live_slots": 198396,
    "epoch": 1000,
    "inverses": 0,
    "registry_entries": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 77252,
    "ruby_fibers": 1,
    "child_contexts": 0,
    "heap_live_slots": 198359,
    "epoch": 1000
  }
]
```

### mcp_inflight_reload resource samples

```json
[
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 77252,
    "ruby_fibers": 1,
    "child_contexts": 0,
    "heap_live_slots": 198357,
    "epoch": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 77308,
    "ruby_fibers": 1,
    "child_contexts": 0,
    "heap_live_slots": 198379,
    "epoch": 1
  }
]
```

### mcp_descendant_cleanup resource samples

```json
[
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 77308,
    "ruby_fibers": 1,
    "child_contexts": 0,
    "heap_live_slots": 198378,
    "epoch": 0
  },
  {
    "threads": 1,
    "child_processes": 0,
    "open_fds": 6,
    "rss_kb": 77316,
    "ruby_fibers": 1,
    "child_contexts": 0,
    "heap_live_slots": 198402,
    "epoch": 1
  }
]
```

## Scheduler

Loopback HTTP, eight server workers. Durations use CLOCK_MONOTONIC. Request thresholds: 100/1000 successes; duration <3/<6s; p50 <500/<2000ms; p95 <1000/<4000ms. Comparison requires >=1.5x speedup. Timeout disables HTTP retries; cancellation interrupts a parked fiber.

### requests100: PASS

```json
{
  "count": 100,
  "success": 100,
  "failed": 0,
  "duration_s": 0.07,
  "throughput_rps": 1421.7,
  "min_ms": 36.6,
  "p50_ms": 45.48,
  "p95_ms": 50.2,
  "p99_ms": 50.48,
  "max_ms": 50.48
}
```

### requests1000: PASS

```json
{
  "count": 1000,
  "success": 1000,
  "failed": 0,
  "duration_s": 0.862,
  "throughput_rps": 1160.2,
  "min_ms": 503.76,
  "p50_ms": 606.53,
  "p95_ms": 635.85,
  "p99_ms": 636.71,
  "max_ms": 637.01
}
```

### timeout_cancel: PASS

```json
{
  "timed_out_cleanly": true,
  "elapsed_s": 0.101,
  "expected_delay_s": 2.0,
  "cancelled_cleanly": true,
  "cancel_elapsed_s": 0.05,
  "passed": true
}
```

### scheduler_comparison: PASS

```json
{
  "requests": 40,
  "scheduler_on_s": 0.094,
  "scheduler_off_s": 0.637,
  "speedup_ratio": 6.78,
  "passed": true
}
```

## AST Cache: PASS

Synthetic Ruby fixture, cold extraction + save versus warm validated load; requires all fixture entries, warm load <500ms, nonempty cache, and warm faster than cold.

```json
{
  "file_count": 150,
  "total_source_bytes": 49580,
  "cold_duration_ms": 46.8,
  "warm_duration_ms": 8.4,
  "cache_size_bytes": 214576,
  "speedup_ratio": 5.56,
  "loaded_entries": 150,
  "passed": true
}
```

## Reproduction

```sh
bundle exec ruby dev/validate_runtime_capacity.rb --epochs=1000 --seed=151
```

Exit status: 0 PASS, 1 FAIL, 2 INCONCLUSIVE. No external API or credentials required.