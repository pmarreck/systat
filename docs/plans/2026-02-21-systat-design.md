# Systat Design Document

**Date:** 2026-02-21
**Status:** Approved

## Summary

Systat is a cross-platform system monitoring GUI app built in pure Zig using DVUI for rendering. It displays prioritized, resizable subsections of system stats (CPU hogs, memory hogs, CPU usage graph, network ping monitor) with a cyberpunk dark theme. Config is TOML-based with hot-reloading.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| GUI library | DVUI (pure Zig) | No C++ dep, built-in plotting, on-demand rendering, web backend via WASM, confirmed Zig 0.15.2 |
| C FFI | Deferred | DVUI is Zig-native; no benefit to C FFI for the GUI layer now. Core stays clean for future FFI if needed. |
| DI pattern | Vtable interfaces | Same pattern as `std.mem.Allocator`. Real backends for production, mocks for tests. |
| Module architecture | Flat registry | Simple list of modules sorted by priority. Evolves cleanly into plugins later. |
| Layout model | Min/preferred size declarations | Each module declares min/preferred sizes. Layout engine sorts by priority, allocates greedily, hides what doesn't fit. |
| Config format | TOML with hot-reload | File watcher (kqueue/inotify/RDCW) detects changes. Invalid config shows error in status bar. |
| Theme | Configurable via TOML | Two built-in presets (neon_orange, neon_cyan) plus custom colors. |
| TUI mode | Deferred | Core is pure functions returning structured data. TUI frontend can consume same data later. |
| Zig version | 0.15.2 (pinned in flake) | Latest stable target. |

## Architecture

```
main.zig (entry, DVUI init, event loop)
  └── App
       ├── Config (TOML, hot-reload via file watcher)
       ├── LayoutEngine (priority sort, grid fit 1-3 columns)
       ├── ModuleRegistry
       │    ├── CpuHogsModule (table: command, procs, %CPU, %SYS)
       │    ├── MemHogsModule (table: command, procs, RSS, %MEM)
       │    ├── CpuGraphModule (line plot, ring buffer, 5min window)
       │    └── PingMonitorModule (multi-line plot, per-host ring buffers)
       ├── StatusBar (config errors, info messages)
       ├── Menu (About, Quit)
       └── SystemStats (vtable interface)
            ├── DarwinBackend (sysctl, mach APIs)
            ├── LinuxBackend (/proc, sysinfo)
            ├── WindowsBackend (WMI, perf counters)
            └── MockBackend (tests)
```

### Module Interface

```zig
const ModuleInfo = struct {
    id: []const u8,
    display_name: []const u8,
    default_priority: u8,      // 1 = highest
    min_width: u16,
    min_height: u16,
    preferred_width: u16,
    preferred_height: u16,
};

const Module = struct {
    infoFn:   *const fn (*anyopaque) ModuleInfo,
    updateFn: *const fn (*anyopaque, SystemStats) void,
    renderFn: *const fn (*anyopaque, *dvui, Rect) void,
    deinitFn: *const fn (*anyopaque) void,
    ctx: *anyopaque,
};
```

### Data Flow (Per Frame)

1. `stats.refresh()` — platform backend collects fresh data
2. `module.update(stats)` for each module — pure processing (sort, aggregate, ring buffer append)
3. Layout engine computes grid: `(window_size, []ModuleInfo) → []PlacedModule`
4. `module.render(ui, rect)` for each visible module
5. Status bar renders at bottom

### Dependency Injection Seams

- `App` accepts a `SystemStats` interface (real or mock)
- `Config` accepts a file path or `[]const u8` buffer (testable without disk)
- Module `update()` is pure: data in → state mutation on self only
- `LayoutEngine` is a pure function: dimensions + module info → placement

## MVP Modules

### 1. CPU Hogs (`cpu_hogs`)
- Table: command name (aggregated), process count, total %CPU, % of system
- Sorted by %CPU descending, configurable row count (default 15)
- Highlights process storms (configurable threshold)
- Default priority: 1

### 2. Memory Hogs (`mem_hogs`)
- Table: command name (aggregated), process count, total RSS, %MEM
- Sorted by RSS descending, human-readable sizes (KB/MB/GB)
- Same storm detection
- Default priority: 2

### 3. CPU Usage Graph (`cpu_graph`)
- Animated line chart via DVUI PlotWidget
- X: time (rolling 5min window), Y: 0-100%
- Optional per-core or user/system/idle breakdown
- 1-second update interval (configurable)
- Default priority: 3

### 4. Network Ping Monitor (`ping_monitor`)
- Multi-line plot, one colored line per host
- Y: response time (ms), timeout/failure shown as gap or marker
- Default hosts: google.com, github.com, cloudflare.com (configurable)
- 2-second ping interval (configurable), runs on background thread
- Default priority: 4

## Config

### File Locations
- **macOS:** `~/Library/Application Support/systat/config.toml` (fallback: `~/.config/systat/`)
- **Linux:** `$XDG_CONFIG_HOME/systat/config.toml`
- **Windows:** `%APPDATA%\systat\config.toml`

### Example Config
```toml
[general]
update_interval_ms = 1000
process_count = 15
theme = "neon_orange"

[modules.cpu_hogs]
priority = 1
enabled = true

[modules.mem_hogs]
priority = 2
enabled = true

[modules.cpu_graph]
priority = 3
enabled = true
history_seconds = 300

[modules.ping_monitor]
priority = 4
enabled = true
hosts = ["google.com", "github.com", "cloudflare.com"]
ping_interval_ms = 2000

[theme.custom]
background = "#1a1a2e"
primary = "#ff6600"
accent = "#9933ff"
success = "#00ff88"
warning = "#ffaa00"
error = "#ff3366"
text = "#e0e0e0"
text_dim = "#888888"
```

### Hot-Reload
- Native file watcher per platform (kqueue, inotify, ReadDirectoryChangesW)
- Valid changes applied immediately
- Invalid TOML: error shown in status bar, previous config retained

## Theme Presets

### `neon_orange` (default)
- Background: deep navy (#1a1a2e)
- Primary: orange (#FF6600)
- Accent: purple (#9933FF)

### `neon_cyan`
- Background: dark charcoal (#1a1a1a)
- Primary: cyan (#00FFFF)
- Accent: magenta (#FF00FF)

### `custom`
- User-defined via `[theme.custom]` section

## GUI Elements

### Menu Bar
- Single "Systat" menu with: About, Quit

### Status Bar
- Bottom of window
- Shows: config reload status, parse errors, last refresh timestamp

### Dynamic Layout
- 1-3 columns based on window width
- Modules sorted by effective priority (config override > default)
- Modules below min_width or min_height are hidden
- Remaining space allocated to visible modules, preferring preferred_width/height

## Testing Strategy

### Unit Tests (Zig test blocks)
- Pure data processing: aggregation, sorting, percentages, human-readable formatting
- Ring buffer: append, overflow, windowed queries
- Config parsing: valid, invalid, defaults, priority overrides
- Layout engine: grid computation, module hiding
- Mock SystemStats for module testing

### Integration Tests
- Config hot-reload: write file, modify, verify pickup
- Platform backend smoke: verify plausible ranges (CPU 0-100%, memory > 0)

### Test Runner
- `./test` bash script runs `nix develop -c zig build test`
- All assertions in Zig test blocks

### Benchmarks
- `./bm` measures: process list collection, data aggregation, ring buffer ops, config parsing
- Logs with timestamps, flags regressions
- Asserts debug build is not running

## Project Structure

```
systat/
├── build.zig
├── build.zig.zon
├── flake.nix
├── config.example.toml
├── test                    # Bash wrapper for zig build test
├── build                   # Bash wrapper, ReleaseFast default
├── bm                      # Bash wrapper for benchmarks
├── src/
│   ├── main.zig
│   ├── app.zig
│   ├── config.zig
│   ├── layout.zig
│   ├── theme.zig
│   ├── status_bar.zig
│   ├── menu.zig
│   ├── module.zig
│   ├── ring_buffer.zig
│   ├── modules/
│   │   ├── cpu_hogs.zig
│   │   ├── mem_hogs.zig
│   │   ├── cpu_graph.zig
│   │   └── ping_monitor.zig
│   └── platform/
│       ├── stats.zig
│       ├── darwin.zig
│       ├── linux.zig
│       ├── windows.zig
│       └── file_watcher.zig
├── tests/
│   ├── unit/
│   │   ├── config_test.zig
│   │   ├── layout_test.zig
│   │   ├── ring_buffer_test.zig
│   │   ├── cpu_hogs_test.zig
│   │   ├── mem_hogs_test.zig
│   │   └── mock_stats.zig
│   ├── integration/
│   │   └── platform_smoke_test.zig
│   └── benchmark/
│       └── bench_main.zig
├── docs/plans/
│   └── 2026-02-21-systat-design.md
├── PLAN.md
├── CODE_MINIMAP.md
└── PROJECT_SPEC.md
```

## Future Considerations (Not MVP)

- **TUI mode:** Core returns structured data; a TUI frontend (e.g., using ANSI escape codes or a Zig TUI lib) can consume the same module output.
- **C FFI:** If external consumers need it, the pure core functions are easily wrappable.
- **Plugin system:** The flat `Module` interface is the plugin API. Add `std.DynLib.open()` to load modules from shared libraries.
- **Additional modules:** Disk I/O, network bandwidth, GPU usage, battery, temperature sensors.
- **i18n:** Groundwork for 30-language support per CLI conventions. Defer actual translations until UI stabilizes.
- **Web deployment:** DVUI's WASM backend allows running systat in a browser. Could be useful for remote monitoring.
