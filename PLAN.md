# systat — Roadmap & Status

## Completed

- [x] Nix flake with Zig 0.15.2 + SDL3
- [x] Build system with DVUI + TOML deps
- [x] Build/test scripts
- [x] DVUI hello world window
- [x] RingBuffer (comptime capacity, TDD)
- [x] Module vtable interface
- [x] Layout engine (priority-based grid)
- [x] SystemStats vtable + mock backend
- [x] Data processing (aggregation, formatBytes)
- [x] Config structs with defaults
- [x] Theme system (neon_orange, neon_cyan, custom → dvui.Theme)
- [x] CPU Hogs module (data + rendering)
- [x] Memory Hogs module (data + rendering)
- [x] CPU Graph module (ring buffer + plot rendering)
- [x] Ping Monitor module (per-host ring buffers + multi-line plot)
- [x] App wiring with module registry
- [x] Module rendering with DVUI widgets (grids, plots)
- [x] Status bar and menu bar
- [x] macOS platform backend (ps, top, ping)
- [x] Config hot-reload with file watcher
- [x] Example config file
- [x] Documentation

## Future Work

- [ ] TOML config parsing (wire up sam701/zig-toml)
- [ ] Linux platform backend (/proc/stat, /proc/meminfo)
- [ ] Windows platform backend (WMI / performance counters)
- [ ] Per-core CPU graph (multiple lines)
- [ ] Disk I/O module
- [ ] Network I/O module
- [ ] GPU utilization module
- [ ] App bundling (macOS .app, Linux AppImage, Windows installer)
- [ ] TUI mode (terminal rendering backend)
- [ ] WASM web backend
- [ ] Config editor dialog in GUI
- [ ] kqueue/inotify file watcher (replace polling)
