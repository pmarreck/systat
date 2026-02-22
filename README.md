# systat

[![CI](https://github.com/pmarreck/systat/actions/workflows/ci.yml/badge.svg?branch=yolo)](https://github.com/pmarreck/systat/actions/workflows/ci.yml)
[![built with garnix](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2Fpmarreck%2Fsystat%3Fbranch%3Dyolo)](https://garnix.io)

Cross-platform system monitoring GUI built in pure Zig with [DVUI](https://github.com/david-vanderson/dvui) and SDL3.

![systat screenshot](assets/screenshot.png)

## Features

- **CPU Usage Graph** — real-time line chart with 5-minute sliding window
- **Web Ping Monitor** — HTTP latency for multiple hosts with bot-detection-resistant headers
- **CPU Hogs** — top processes by CPU usage, aggregated by command, with system load summary
- **Memory Hogs** — top processes by RSS, with wired/compressor/swap stats
- **Cyberpunk Theme** — neon orange (default), neon cyan, or fully custom via TOML
- **Hot-Reload Config** — edit `config.toml` and changes apply instantly
- **Window State Persistence** — remembers size and position across sessions

## Requirements

- [Nix](https://nixos.org/) with flakes enabled (recommended), **or**
- [Zig 0.15.2](https://ziglang.org/) installed manually

## Quick Start

```bash
# With Nix
nix develop
zig build run

# Without Nix (requires Zig 0.15.2)
zig build run
```

## Configuration

Copy the example config and customize:

```bash
cp config.example.toml config.toml
```

See [config.example.toml](config.example.toml) for all available options.

## Building & Testing

```bash
zig build          # build the app
zig build run      # build and run
zig build test     # run all tests
```

Or use the convenience scripts:

```bash
scripts/build-systat   # build
scripts/test-systat    # test
scripts/bm             # benchmark build time
```

## Architecture

Pure Zig, no C dependencies beyond what SDL3 provides. Key design decisions:

- **DVUI** for rendering — pure Zig GUI toolkit with built-in plotting, testing backend, and on-demand rendering
- **Dependency injection** via vtable interfaces (like `std.mem.Allocator`) for testability
- **Ring buffers** for time-series data with fixed memory footprint
- **Platform abstraction** — macOS backend via `top`/`ps`/`curl`, mock backend for testing
- **Module system** — flat registry with priority-based layout

## License

[MIT](LICENSE)
