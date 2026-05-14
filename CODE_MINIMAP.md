# systat — Code Minimap

## Source Tree

```
src/
  app.zig           — DVUI App entrypoint (main, appInit, appFrame, appDeinit)
  app_state.zig     — AppState: owns config, modules, theme, file watcher
  config.zig        — Config structs, defaults, parseConfig stub
  data.zig          — aggregateProcesses(), formatBytes() — pure functions
  file_watcher.zig  — FileWatcher: polls file mtime for changes
  layout.zig        — computeLayout(): priority-based grid placement
  menu.zig          — Menu bar rendering (Systat → About, Quit)
  module.zig        — Module vtable interface + ModuleInfo
  ring_buffer.zig   — RingBuffer(T, N): comptime-sized circular buffer
  status_bar.zig    — StatusBar: transient/error messages at window bottom
  theme.zig         — dvui.Theme presets (neon_orange, neon_cyan), resolveTheme()

  modules/
    cpu_hogs.zig    — CpuHogs: aggregated process list by CPU%
    mem_hogs.zig    — MemHogs: aggregated process list by RSS
    cpu_graph.zig   — CpuGraph: time-series CPU% ring buffer + line plot
    ping_monitor.zig — PingMonitor: per-host latency ring buffers + multi-line plot

  platform/
    stats.zig       — SystemStats vtable interface (ProcessInfo, CpuSnapshot, etc.)
    mock.zig        — MockStats: canned data for testing
    darwin.zig      — DarwinBackend: real macOS data via ps/top/ping
```

## Key Types

| Type | File | Purpose |
|------|------|---------|
| `AppState` | app_state.zig | Central state: config, modules, theme, watcher |
| `Module` | module.zig | Type-erased vtable for any monitoring module |
| `ModuleInfo` | module.zig | Module metadata (id, name, priority, size hints) |
| `SystemStats` | platform/stats.zig | Vtable for system data collection |
| `RingBuffer(T, N)` | ring_buffer.zig | Fixed-capacity circular buffer |
| `Config` | config.zig | All user-configurable settings |
| `dvui.Theme` | (DVUI lib) | Theme colors/fonts applied to all widgets |

## Data Flow

```
SystemStats (mock or darwin)
  → Module.update() — fetches + processes data
  → Module.render() — DVUI widgets read cached data
  → dvui frame loop — composites to SDL3 window
```

## Testing

110+ tests. Run: `zig build test`

All modules use MockStats for deterministic testing.
DVUI rendering tests use `dvui.testing.init()` + `dvui.testing.step(frame_fn)`.
```
