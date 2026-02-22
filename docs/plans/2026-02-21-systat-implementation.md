# Systat Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a cross-platform system monitoring GUI app using DVUI (pure Zig) with four modules: CPU hogs, memory hogs, CPU usage graph, and network ping monitor.

**Architecture:** Pure Zig core with vtable-style dependency injection for platform backends. DVUI handles all rendering via SDL3. Modules are a flat registry sorted by priority. Config is TOML with hot-reload via native file watchers.

**Tech Stack:** Zig 0.15.2, DVUI 0.4.0-dev (SDL3 backend), sam701/zig-toml, Nix flake for dependencies.

**Design doc:** `docs/plans/2026-02-21-systat-design.md`

---

## TDD Execution Protocol: Split-Context Red/Green

**All TDD tasks use two separate agent contexts to prevent confirmation bias:**

### Test Agent (Red Phase)
- Sees: design doc, interface contracts, and this plan's behavioral specifications
- Does NOT see: implementation code or suggested algorithms
- Creates: file with type definitions, function signatures (stubs returning `error.NotImplemented` or `unreachable`), and comprehensive tests
- Focus: "What is the contract? What are the edge cases? What are the invariants? What could go wrong?"
- Commits the test file with stubs

### Implementation Agent (Green Phase)
- Sees: the committed test file with failing tests
- Does NOT see: the design doc's suggested implementation pseudocode
- Creates: minimal correct implementation to make all tests pass
- Focus: "How do I satisfy this contract with the least code?"
- If a test appears genuinely wrong (tests incorrect behavior per the spec), flags it for human review rather than silently fixing it
- Commits the implementation

### Why This Matters
The same agent writing both test and implementation can unconsciously write weak tests that match a lazy implementation. Splitting contexts enforces honest TDD — the test author is incentivized to be thorough (specifying the contract completely), and the implementer is forced to satisfy a contract they didn't author.

### GUI Testing Note
DVUI provides a `.testing` backend with:
- Synthetic input: `dvui.testing.moveTo("tag")`, `.click(.left)`, `.pressKey()`, `.writeText()`
- Instant frame advancement: `step(frame_fn)` and `settle(frame_fn)` with no real-time delays
- State assertions: `expectFocused("tag")`, `expectVisible("tag")`, `tagGet("tag").rect`
- Snapshot hashing for regression detection

This means GUI behavior (module visibility, layout changes, menu interactions) CAN be TDD'd too.

---

## Task 1: Project Scaffolding - Nix Flake

**Files:**
- Create: `flake.nix`

**Step 1: Create `flake.nix`**

```nix
{
  description = "systat - cross-platform system monitoring GUI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ zig-overlay.overlays.default ];
        };
        zig = pkgs.zigpkgs."0.15.2";
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            zig
            pkgs.hyperfine
            pkgs.SDL3       # DVUI backend; if not available, SDL2 as fallback
          ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            pkgs.darwin.apple_sdk.frameworks.Cocoa
            pkgs.darwin.apple_sdk.frameworks.Metal
            pkgs.darwin.apple_sdk.frameworks.QuartzCore
          ];
        };
      }
    );
}
```

Note: SDL3 may not be in nixpkgs yet. If `pkgs.SDL3` fails, try `pkgs.SDL2` and adjust the DVUI backend accordingly. Check with `nix develop -c zig version` to confirm Zig 0.15.2.

**Step 2: Verify the flake works**

Run: `nix develop -c zig version`
Expected: `0.15.2`

**Step 3: Commit**

```bash
git add flake.nix
git commit -m "Add Nix flake with Zig 0.15.2 and SDL3"
```

---

## Task 2: Build System - build.zig and build.zig.zon

**Files:**
- Create: `build.zig.zon`
- Create: `build.zig`

**Step 1: Fetch dependencies and create build.zig.zon**

Run:
```bash
nix develop -c zig fetch --save git+https://github.com/david-vanderson/dvui#main
nix develop -c zig fetch --save git+https://github.com/sam701/zig-toml
```

This creates `build.zig.zon` with the correct hashes. If `zig fetch` auto-generates the file, review it. If not, create it manually and fill in the hashes from the output.

The `build.zig.zon` should look something like:
```zig
.{
    .name = .systat,
    .version = "0.1.0",
    .paths = .{""},
    .dependencies = .{
        .dvui = .{
            .url = "git+https://github.com/david-vanderson/dvui?ref=main#<COMMIT_HASH>",
            .hash = "<HASH_FROM_ZIG_FETCH>",
        },
        .toml = .{
            .url = "git+https://github.com/sam701/zig-toml#<COMMIT_HASH>",
            .hash = "<HASH_FROM_ZIG_FETCH>",
        },
    },
}
```

**Step 2: Create build.zig**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    // --- DVUI dependency ---
    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
    });

    // --- TOML dependency ---
    const toml_dep = b.dependency("toml", .{});

    // --- Main executable ---
    const exe = b.addExecutable(.{
        .name = "systat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    exe.root_module.addImport("sdl-backend", dvui_dep.module("sdl3"));
    exe.root_module.addImport("toml", toml_dep.module("toml"));

    b.installArtifact(exe);

    // --- Run step ---
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run systat");
    run_step.dependOn(&run_cmd.step);

    // --- Unit tests ---
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    unit_tests.root_module.addImport("toml", toml_dep.module("toml"));

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
```

Note: The DVUI backend may need adjustment. If SDL3 is not available via Nix, fall back to `.sdl2` and `dvui_sdl2`. The build.zig may also need tweaks based on actual DVUI API — consult `dvui-demo/build.zig` for the latest patterns.

**Step 3: Create minimal src/main.zig placeholder**

```zig
const std = @import("std");

pub fn main() !void {
    std.debug.print("systat starting...\n", .{});
}
```

**Step 4: Verify build**

Run: `nix develop -c zig build`
Expected: Compiles without errors, produces `zig-out/bin/systat`

Run: `nix develop -c zig build run`
Expected: Prints "systat starting..."

**Step 5: Commit**

```bash
git add build.zig build.zig.zon src/main.zig
git commit -m "Add build system with DVUI and TOML dependencies"
```

---

## Task 3: Build/Test Scripts

**Files:**
- Create: `build` (executable bash script)
- Create: `test` (executable bash script)
- Create: `bm` (executable bash script)

**Step 1: Create the `build` script**

```bash
#!/usr/bin/env bash
set -euo pipefail

OPTIMIZE="ReleaseFast"
for arg in "$@"; do
	case "$arg" in
		--debug) OPTIMIZE="Debug" ;;
		--test) exec nix develop -c zig build test ;;
		--help|-h) echo "Usage: ./build [--debug|--test]"; exit 0 ;;
	esac
done

nix develop -c zig build -Doptimize="$OPTIMIZE"
echo "Build complete (${OPTIMIZE}): zig-out/bin/systat"
```

**Step 2: Create the `test` script**

```bash
#!/usr/bin/env bash
set -euo pipefail
nix develop -c zig build test 2>&1
exit_code=$?
if [ $exit_code -eq 0 ]; then
	echo "All tests passed."
else
	echo "Tests FAILED (exit code: $exit_code)"
fi
exit $exit_code
```

**Step 3: Create the `bm` script**

```bash
#!/usr/bin/env bash
set -euo pipefail
echo "Benchmark suite not yet implemented."
exit 0
```

**Step 4: Make scripts executable**

Run: `chmod +x build test bm`

**Step 5: Verify**

Run: `./build`
Expected: Builds successfully

Run: `./test`
Expected: Tests pass (currently no tests, but should not error)

**Step 6: Commit**

```bash
git add build test bm
git commit -m "Add build, test, and bm scripts"
```

---

## Task 4: DVUI Hello World Window

**Files:**
- Modify: `src/main.zig`

**Step 1: Replace main.zig with DVUI App pattern**

Use the App pattern (simpler, more portable). This is based on `dvui/examples/app.zig`:

```zig
const std = @import("std");
const dvui = @import("dvui");

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 900.0, .h = 700.0 },
            .title = "systat",
        },
    },
    .frameFn = appFrame,
    .initFn = appInit,
    .deinitFn = appDeinit,
};

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

pub fn appInit(win: *dvui.Window) !void {
    _ = win;
}

pub fn appDeinit() void {}

pub fn appFrame() !dvui.App.Result {
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .window });
    defer scroll.deinit();

    var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .font = .theme(.title) });
    tl.addText("systat - System Monitor", .{});
    tl.deinit();

    if (dvui.button(@src(), "Quit", .{}, .{})) {
        return .close;
    }

    return .ok;
}
```

Note: The exact DVUI App API may differ from examples. If `dvui.App` doesn't exist or has a different signature, fall back to the standalone pattern (see design research notes). Consult `dvui/src/App.zig` or `dvui/examples/` for the correct API.

**Step 2: Build and run**

Run: `nix develop -c zig build run`
Expected: A window opens titled "systat" with "systat - System Monitor" text and a Quit button. Clicking Quit closes the window.

**Step 3: Verify debug build announces itself**

Run: `nix develop -c zig build -Doptimize=Debug run`
Expected: "DEBUG BUILD" printed to stderr in yellow (add this after confirming the window works — see AGENTS.md requirement).

If the debug announcement isn't happening yet, add it to `appInit`:
```zig
pub fn appInit(win: *dvui.Window) !void {
    _ = win;
    if (comptime @import("builtin").mode == .Debug) {
        std.debug.print("\x1b[33mDEBUG BUILD\x1b[0m\n", .{});
    }
}
```

**Step 4: Commit**

```bash
git add src/main.zig
git commit -m "Add DVUI hello world window with quit button"
```

---

## Task 5: Ring Buffer (TDD)

This is a pure data structure with no dependencies. Perfect for TDD.

**Files:**
- Create: `src/ring_buffer.zig`

**Step 1: Write failing tests**

Add tests at the bottom of `src/ring_buffer.zig`:

```zig
const std = @import("std");

/// A fixed-capacity ring buffer for time-series data.
/// Stores up to `capacity` items. When full, new items overwrite the oldest.
pub fn RingBuffer(comptime T: type) type {
    return struct {
        // Implementation goes here in step 3
    };
}

// ===== Tests =====

const testing = std.testing;

test "RingBuffer: push and read back" {
    var rb = RingBuffer(f64).init(5);
    rb.push(1.0);
    rb.push(2.0);
    rb.push(3.0);
    const slice = rb.slice();
    try testing.expectEqual(@as(usize, 3), slice.len);
    try testing.expectApproxEqAbs(@as(f64, 1.0), slice[0], 0.001);
    try testing.expectApproxEqAbs(@as(f64, 2.0), slice[1], 0.001);
    try testing.expectApproxEqAbs(@as(f64, 3.0), slice[2], 0.001);
}

test "RingBuffer: overflow wraps around" {
    var rb = RingBuffer(f64).init(3);
    rb.push(1.0);
    rb.push(2.0);
    rb.push(3.0);
    rb.push(4.0); // overwrites 1.0
    const slice = rb.slice();
    try testing.expectEqual(@as(usize, 3), slice.len);
    try testing.expectApproxEqAbs(@as(f64, 2.0), slice[0], 0.001);
    try testing.expectApproxEqAbs(@as(f64, 3.0), slice[1], 0.001);
    try testing.expectApproxEqAbs(@as(f64, 4.0), slice[2], 0.001);
}

test "RingBuffer: empty buffer" {
    var rb = RingBuffer(f64).init(5);
    const slice = rb.slice();
    try testing.expectEqual(@as(usize, 0), slice.len);
}

test "RingBuffer: len tracks correctly" {
    var rb = RingBuffer(u32).init(4);
    try testing.expectEqual(@as(usize, 0), rb.len());
    rb.push(10);
    try testing.expectEqual(@as(usize, 1), rb.len());
    rb.push(20);
    rb.push(30);
    rb.push(40);
    try testing.expectEqual(@as(usize, 4), rb.len());
    rb.push(50); // overflow
    try testing.expectEqual(@as(usize, 4), rb.len());
}

test "RingBuffer: clear resets state" {
    var rb = RingBuffer(f64).init(3);
    rb.push(1.0);
    rb.push(2.0);
    rb.clear();
    try testing.expectEqual(@as(usize, 0), rb.len());
    const slice = rb.slice();
    try testing.expectEqual(@as(usize, 0), slice.len);
}
```

**Step 2: Run tests to verify they fail**

Run: `nix develop -c zig build test`
Expected: Compilation errors (struct has no fields/methods yet).

**Step 3: Implement RingBuffer**

The ring buffer uses a comptime-sized backing array (no allocator needed). This keeps it stack-friendly and simple:

```zig
pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();
        const max_capacity = 8192; // compile-time max

        buffer: [max_capacity]T = undefined,
        capacity: usize,
        head: usize = 0,   // next write position
        count: usize = 0,  // current number of items

        pub fn init(capacity: usize) Self {
            std.debug.assert(capacity > 0 and capacity <= max_capacity);
            return .{ .capacity = capacity };
        }

        pub fn push(self: *Self, item: T) void {
            self.buffer[self.head] = item;
            self.head = (self.head + 1) % self.capacity;
            if (self.count < self.capacity) {
                self.count += 1;
            }
        }

        pub fn len(self: *const Self) usize {
            return self.count;
        }

        pub fn clear(self: *Self) void {
            self.head = 0;
            self.count = 0;
        }

        /// Returns a slice of items in chronological order (oldest first).
        /// Note: this copies into a contiguous buffer since the ring may wrap.
        /// For iteration without copying, use `get(index)`.
        pub fn slice(self: *const Self) []const T {
            if (self.count == 0) return &[_]T{};
            if (self.count < self.capacity) {
                // No wraparound yet
                return self.buffer[0..self.count];
            }
            // When wrapped, head points to the oldest item
            // Return from head to end, then start to head
            // But we can't return a discontiguous slice...
            // So we need a different approach. Let's use get() instead
            // and return the underlying buffer reordered.
            // Actually, for simplicity, if not wrapped, return directly.
            // If wrapped, the caller should use get().
            // BUT the tests expect slice() to work... so we need a copy buffer.
            // Let's store a separate output buffer.
            return self.buffer[0..0]; // placeholder - see note below
        }

        /// Get the item at logical index (0 = oldest).
        pub fn get(self: *const Self, index: usize) T {
            std.debug.assert(index < self.count);
            if (self.count < self.capacity) {
                return self.buffer[index];
            }
            return self.buffer[(self.head + index) % self.capacity];
        }
    };
}
```

**Important design note:** A `slice()` that returns contiguous data from a wrapped ring buffer requires either:
- A second copy buffer (doubles memory)
- An allocator (against the design)
- Returning two slices (awkward API)

**Recommended approach:** Use `get(index)` for iteration and provide `toSlice(out_buf)` that copies into a caller-provided buffer. Adjust the tests in step 1 accordingly:

Replace `slice()` tests with `get()` tests or provide a `toSlice` that writes into a caller-provided `[]T`. The implementer should decide the cleanest API and adjust tests to match. The key invariants to test are:
- Push N items, read them back in order
- Overflow preserves newest N items
- `len()` never exceeds capacity
- `clear()` resets everything

**Step 4: Run tests to verify they pass**

Run: `nix develop -c zig build test`
Expected: All 5 RingBuffer tests pass.

**Step 5: Commit**

```bash
git add src/ring_buffer.zig
git commit -m "Add RingBuffer with comptime capacity and TDD tests"
```

---

## Task 6: Module Interface Definition

**Files:**
- Create: `src/module.zig`

**Step 1: Define the Module interface**

```zig
const std = @import("std");

pub const ModuleInfo = struct {
    id: []const u8,
    display_name: []const u8,
    default_priority: u8, // 1 = highest, 255 = lowest
    min_width: u16, // pixels
    min_height: u16,
    preferred_width: u16,
    preferred_height: u16,
};

/// Vtable-style module interface. All monitoring modules implement this.
pub const Module = struct {
    ctx: *anyopaque,
    infoFn: *const fn (ctx: *anyopaque) ModuleInfo,
    updateFn: *const fn (ctx: *anyopaque) void,
    renderFn: *const fn (ctx: *anyopaque) void,
    deinitFn: *const fn (ctx: *anyopaque) void,

    pub fn info(self: Module) ModuleInfo {
        return self.infoFn(self.ctx);
    }

    pub fn update(self: Module) void {
        self.updateFn(self.ctx);
    }

    pub fn render(self: Module) void {
        self.renderFn(self.ctx);
    }

    pub fn deinit(self: Module) void {
        self.deinitFn(self.ctx);
    }

    /// Helper to create a Module from any concrete type that has the right methods.
    pub fn from(ptr: anytype) Module {
        const Ptr = @TypeOf(ptr);
        const T = @typeInfo(Ptr).pointer.child;
        return .{
            .ctx = @ptrCast(ptr),
            .infoFn = @ptrCast(&T.moduleInfo),
            .updateFn = @ptrCast(&T.moduleUpdate),
            .renderFn = @ptrCast(&T.moduleRender),
            .deinitFn = @ptrCast(&T.moduleDeinit),
        };
    }
};

// ===== Tests =====

const testing = std.testing;

const MockModule = struct {
    update_count: u32 = 0,
    render_count: u32 = 0,

    pub fn moduleInfo(_: *MockModule) ModuleInfo {
        return .{
            .id = "mock",
            .display_name = "Mock Module",
            .default_priority = 5,
            .min_width = 200,
            .min_height = 150,
            .preferred_width = 400,
            .preferred_height = 300,
        };
    }

    pub fn moduleUpdate(self: *MockModule) void {
        self.update_count += 1;
    }

    pub fn moduleRender(self: *MockModule) void {
        self.render_count += 1;
    }

    pub fn moduleDeinit(_: *MockModule) void {}
};

test "Module: vtable dispatch works" {
    var mock = MockModule{};
    const m = Module.from(&mock);

    const info_val = m.info();
    try testing.expectEqualStrings("mock", info_val.id);
    try testing.expectEqual(@as(u8, 5), info_val.default_priority);

    m.update();
    m.update();
    m.render();

    try testing.expectEqual(@as(u32, 2), mock.update_count);
    try testing.expectEqual(@as(u32, 1), mock.render_count);
}
```

Note: The `Module.from()` helper uses `@ptrCast` which requires matching function signatures. The exact Zig 0.15 casting semantics may require adjustment. If `@ptrCast` doesn't work for function pointer casting, use explicit wrapper functions instead (similar to how `std.mem.Allocator` does it with `@fieldParentPtr`).

**Step 2: Run tests**

Run: `nix develop -c zig build test`
Expected: Module vtable test passes.

**Step 3: Commit**

```bash
git add src/module.zig
git commit -m "Add Module vtable interface with mock test"
```

---

## Task 7: Layout Engine (TDD)

**Files:**
- Create: `src/layout.zig`

**Step 1: Write failing tests**

```zig
const std = @import("std");
const module = @import("module.zig");

pub const Rect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
};

pub const PlacedModule = struct {
    module_index: usize, // index into the input module list
    rect: Rect,
};

/// Compute grid layout for modules.
/// Returns which modules are visible and where they go.
/// Pure function: no I/O, no side effects.
///
/// Parameters:
/// - window_w, window_h: available space (excluding status bar)
/// - infos: module info for each module
/// - priorities: effective priority for each module (config override or default)
///
/// Returns: slice of PlacedModule (allocated with provided allocator).
pub fn computeLayout(
    allocator: std.mem.Allocator,
    window_w: u16,
    window_h: u16,
    infos: []const module.ModuleInfo,
    priorities: []const u8,
) ![]PlacedModule {
    _ = allocator;
    _ = window_w;
    _ = window_h;
    _ = infos;
    _ = priorities;
    // Stub - will be implemented in step 3
    return &[_]PlacedModule{};
}

// ===== Tests =====

const testing = std.testing;

fn makeInfo(id: []const u8, priority: u8, min_w: u16, min_h: u16, pref_w: u16, pref_h: u16) module.ModuleInfo {
    return .{
        .id = id,
        .display_name = id,
        .default_priority = priority,
        .min_width = min_w,
        .min_height = min_h,
        .preferred_width = pref_w,
        .preferred_height = pref_h,
    };
}

test "Layout: empty module list" {
    const result = try computeLayout(testing.allocator, 800, 600, &.{}, &.{});
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "Layout: single module fits" {
    const infos = [_]module.ModuleInfo{
        makeInfo("cpu", 1, 200, 150, 400, 300),
    };
    const priorities = [_]u8{1};
    const result = try computeLayout(testing.allocator, 800, 600, &infos, &priorities);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 1), result.len);
    // Module should be placed and have reasonable dimensions
    try testing.expect(result[0].rect.w >= 200);
    try testing.expect(result[0].rect.h >= 150);
}

test "Layout: module too wide is hidden" {
    const infos = [_]module.ModuleInfo{
        makeInfo("wide", 1, 500, 150, 600, 300),
    };
    const priorities = [_]u8{1};
    // Window is only 400px wide, module needs 500 min
    const result = try computeLayout(testing.allocator, 400, 600, &infos, &priorities);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "Layout: modules sorted by priority" {
    const infos = [_]module.ModuleInfo{
        makeInfo("low", 5, 200, 150, 300, 200),
        makeInfo("high", 1, 200, 150, 300, 200),
        makeInfo("mid", 3, 200, 150, 300, 200),
    };
    const priorities = [_]u8{ 5, 1, 3 };
    const result = try computeLayout(testing.allocator, 800, 600, &infos, &priorities);
    defer testing.allocator.free(result);
    // All should fit in 800x600
    try testing.expectEqual(@as(usize, 3), result.len);
    // First placed should be the highest priority (index 1 = "high")
    try testing.expectEqual(@as(usize, 1), result[0].module_index);
}

test "Layout: 1 column for narrow window" {
    const infos = [_]module.ModuleInfo{
        makeInfo("a", 1, 200, 150, 400, 300),
        makeInfo("b", 2, 200, 150, 400, 300),
    };
    const priorities = [_]u8{ 1, 2 };
    // 450px wide: fits 1 column of 400px preferred, not 2
    const result = try computeLayout(testing.allocator, 450, 600, &infos, &priorities);
    defer testing.allocator.free(result);
    // Both should be placed vertically (same x, different y)
    if (result.len >= 2) {
        try testing.expectEqual(result[0].rect.x, result[1].rect.x);
        try testing.expect(result[1].rect.y > result[0].rect.y);
    }
}

test "Layout: drops lowest priority when space runs out" {
    const infos = [_]module.ModuleInfo{
        makeInfo("high", 1, 200, 200, 300, 300),
        makeInfo("mid", 2, 200, 200, 300, 300),
        makeInfo("low", 3, 200, 200, 300, 300),
    };
    const priorities = [_]u8{ 1, 2, 3 };
    // Only 400px tall: fits 2 modules at 200px min each, not 3
    // (in 1-column mode at 350px width)
    const result = try computeLayout(testing.allocator, 350, 400, &infos, &priorities);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 2), result.len);
    // Should keep the higher-priority ones
    try testing.expectEqual(@as(usize, 0), result[0].module_index); // "high"
    try testing.expectEqual(@as(usize, 1), result[1].module_index); // "mid"
}
```

**Step 2: Run tests to verify they fail**

Run: `nix develop -c zig build test`
Expected: Tests fail (stub returns empty).

**Step 3: Implement computeLayout**

Algorithm:
1. Sort module indices by effective priority (ascending = highest first)
2. Determine column count: `window_w / min_module_width`, clamped to 1-3
3. Column width = `window_w / num_columns`
4. Walk sorted modules, greedily place into columns. Track current Y per column.
5. Skip modules whose min_width > column_width or min_height > remaining_height
6. Allocate preferred_height where possible, min_height otherwise
7. Return the placed modules

The implementer should write this as a pure function. All the layout logic is arithmetic — no I/O, no DVUI calls.

**Step 4: Run tests to verify they pass**

Run: `nix develop -c zig build test`
Expected: All 6 layout tests pass.

**Step 5: Commit**

```bash
git add src/layout.zig
git commit -m "Add layout engine with priority-based grid placement"
```

---

## Task 8: SystemStats Interface + Mock

**Files:**
- Create: `src/platform/stats.zig`
- Create: `src/platform/mock.zig`

**Step 1: Define the SystemStats vtable interface**

`src/platform/stats.zig`:
```zig
const std = @import("std");

pub const ProcessInfo = struct {
    command: []const u8,
    pid: u32,
    cpu_percent: f64, // per-process CPU% (can exceed 100 on multi-core)
    rss_bytes: u64, // resident set size in bytes
};

pub const CpuSnapshot = struct {
    total_percent: f64, // 0-100, averaged across all cores
    per_core: []const f64, // per-core percentages (optional, may be empty)
    user_percent: f64,
    system_percent: f64,
    idle_percent: f64,
    num_cores: u16,
};

pub const MemSnapshot = struct {
    total_bytes: u64,
    used_bytes: u64,
    free_bytes: u64,
};

pub const PingResult = struct {
    host: []const u8,
    latency_ms: ?f64, // null = timeout/failure
    timestamp_ns: i128,
};

/// Vtable-style interface for system stats collection.
/// Real implementations talk to the OS. Mocks return canned data.
pub const SystemStats = struct {
    ctx: *anyopaque,
    getProcessListFn: *const fn (ctx: *anyopaque) []const ProcessInfo,
    getCpuSnapshotFn: *const fn (ctx: *anyopaque) CpuSnapshot,
    getMemSnapshotFn: *const fn (ctx: *anyopaque) MemSnapshot,
    pingFn: *const fn (ctx: *anyopaque, host: []const u8) PingResult,

    pub fn getProcessList(self: SystemStats) []const ProcessInfo {
        return self.getProcessListFn(self.ctx);
    }

    pub fn getCpuSnapshot(self: SystemStats) CpuSnapshot {
        return self.getCpuSnapshotFn(self.ctx);
    }

    pub fn getMemSnapshot(self: SystemStats) MemSnapshot {
        return self.getMemSnapshotFn(self.ctx);
    }

    pub fn ping(self: SystemStats, host: []const u8) PingResult {
        return self.pingFn(self.ctx, host);
    }
};
```

**Step 2: Create mock implementation**

`src/platform/mock.zig`:
```zig
const std = @import("std");
const stats = @import("stats.zig");

pub const MockStats = struct {
    processes: []const stats.ProcessInfo = &default_processes,
    cpu: stats.CpuSnapshot = default_cpu,
    mem: stats.MemSnapshot = default_mem,
    ping_latency: ?f64 = 25.0,

    const default_processes = [_]stats.ProcessInfo{
        .{ .command = "node", .pid = 1001, .cpu_percent = 45.0, .rss_bytes = 500 * 1024 * 1024 },
        .{ .command = "firefox", .pid = 2001, .cpu_percent = 30.0, .rss_bytes = 1200 * 1024 * 1024 },
        .{ .command = "zig", .pid = 3001, .cpu_percent = 95.0, .rss_bytes = 200 * 1024 * 1024 },
        .{ .command = "bash", .pid = 4001, .cpu_percent = 0.5, .rss_bytes = 10 * 1024 * 1024 },
    };

    const default_cpu = stats.CpuSnapshot{
        .total_percent = 42.5,
        .per_core = &[_]f64{ 80.0, 50.0, 30.0, 10.0 },
        .user_percent = 30.0,
        .system_percent = 12.5,
        .idle_percent = 57.5,
        .num_cores = 4,
    };

    const default_mem = stats.MemSnapshot{
        .total_bytes = 16 * 1024 * 1024 * 1024, // 16 GB
        .used_bytes = 10 * 1024 * 1024 * 1024,
        .free_bytes = 6 * 1024 * 1024 * 1024,
    };

    pub fn interface(self: *MockStats) stats.SystemStats {
        return .{
            .ctx = @ptrCast(self),
            .getProcessListFn = @ptrCast(&getProcessList),
            .getCpuSnapshotFn = @ptrCast(&getCpuSnapshot),
            .getMemSnapshotFn = @ptrCast(&getMemSnapshot),
            .pingFn = @ptrCast(&pingImpl),
        };
    }

    fn getProcessList(self: *MockStats) []const stats.ProcessInfo {
        return self.processes;
    }

    fn getCpuSnapshot(self: *MockStats) stats.CpuSnapshot {
        return self.cpu;
    }

    fn getMemSnapshot(self: *MockStats) stats.MemSnapshot {
        return self.mem;
    }

    fn pingImpl(self: *MockStats, host: []const u8) stats.PingResult {
        return .{
            .host = host,
            .latency_ms = self.ping_latency,
            .timestamp_ns = std.time.nanoTimestamp(),
        };
    }
};

// ===== Tests =====

const testing = std.testing;

test "MockStats: provides canned process data" {
    var mock = MockStats{};
    const s = mock.interface();
    const procs = s.getProcessList();
    try testing.expectEqual(@as(usize, 4), procs.len);
    try testing.expectEqualStrings("node", procs[0].command);
}

test "MockStats: provides canned CPU data" {
    var mock = MockStats{};
    const s = mock.interface();
    const cpu = s.getCpuSnapshot();
    try testing.expectApproxEqAbs(@as(f64, 42.5), cpu.total_percent, 0.01);
}

test "MockStats: provides canned memory data" {
    var mock = MockStats{};
    const s = mock.interface();
    const mem = s.getMemSnapshot();
    try testing.expect(mem.used_bytes < mem.total_bytes);
}

test "MockStats: ping returns configured latency" {
    var mock = MockStats{ .ping_latency = 50.0 };
    const s = mock.interface();
    const result = s.ping("google.com");
    try testing.expectApproxEqAbs(@as(f64, 50.0), result.latency_ms.?, 0.01);
}
```

Note: The `@ptrCast` approach for function pointers may need adjustment in Zig 0.15. If it doesn't compile, use explicit wrapper functions with `@as(*MockStats, @ptrCast(@alignCast(ctx)))` inside each wrapper, similar to `std.mem.Allocator`'s pattern.

**Step 3: Run tests**

Run: `nix develop -c zig build test`
Expected: All mock stats tests pass.

**Step 4: Commit**

```bash
git add src/platform/stats.zig src/platform/mock.zig
git commit -m "Add SystemStats vtable interface and mock implementation"
```

---

## Task 9: Data Processing - Aggregation Functions (TDD)

These are pure functions used by cpu_hogs and mem_hogs modules.

**Files:**
- Create: `src/data.zig`

**Step 1: Write failing tests**

```zig
const std = @import("std");
const stats = @import("platform/stats.zig");

pub const AggregatedProcess = struct {
    command: []const u8,
    process_count: u32,
    total_cpu_percent: f64,
    total_rss_bytes: u64,
};

/// Aggregate processes by command name.
/// Returns sorted by the specified key.
/// Pure function — no I/O.
pub fn aggregateProcesses(
    allocator: std.mem.Allocator,
    processes: []const stats.ProcessInfo,
    sort_by: enum { cpu, memory },
    max_results: usize,
) ![]AggregatedProcess {
    _ = allocator;
    _ = processes;
    _ = sort_by;
    _ = max_results;
    return &[_]AggregatedProcess{}; // stub
}

/// Format bytes into human-readable string (e.g., "1.50 GB").
/// Writes into the provided buffer, returns the written slice.
pub fn formatBytes(bytes: u64, buf: []u8) []const u8 {
    _ = bytes;
    _ = buf;
    return ""; // stub
}

// ===== Tests =====

const testing = std.testing;

test "aggregateProcesses: groups by command" {
    const procs = [_]stats.ProcessInfo{
        .{ .command = "node", .pid = 1, .cpu_percent = 10.0, .rss_bytes = 100 },
        .{ .command = "node", .pid = 2, .cpu_percent = 20.0, .rss_bytes = 200 },
        .{ .command = "bash", .pid = 3, .cpu_percent = 5.0, .rss_bytes = 50 },
    };
    const result = try aggregateProcesses(testing.allocator, &procs, .cpu, 10);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 2), result.len);
    // Sorted by CPU descending: node (30%) then bash (5%)
    try testing.expectEqualStrings("node", result[0].command);
    try testing.expectEqual(@as(u32, 2), result[0].process_count);
    try testing.expectApproxEqAbs(@as(f64, 30.0), result[0].total_cpu_percent, 0.01);
    try testing.expectEqual(@as(u64, 300), result[0].total_rss_bytes);
}

test "aggregateProcesses: sort by memory" {
    const procs = [_]stats.ProcessInfo{
        .{ .command = "firefox", .pid = 1, .cpu_percent = 5.0, .rss_bytes = 1000 },
        .{ .command = "node", .pid = 2, .cpu_percent = 50.0, .rss_bytes = 5000 },
    };
    const result = try aggregateProcesses(testing.allocator, &procs, .memory, 10);
    defer testing.allocator.free(result);

    // node has more RSS
    try testing.expectEqualStrings("node", result[0].command);
}

test "aggregateProcesses: respects max_results" {
    const procs = [_]stats.ProcessInfo{
        .{ .command = "a", .pid = 1, .cpu_percent = 10.0, .rss_bytes = 100 },
        .{ .command = "b", .pid = 2, .cpu_percent = 20.0, .rss_bytes = 200 },
        .{ .command = "c", .pid = 3, .cpu_percent = 30.0, .rss_bytes = 300 },
    };
    const result = try aggregateProcesses(testing.allocator, &procs, .cpu, 2);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 2), result.len);
}

test "formatBytes: human-readable sizes" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0 B", formatBytes(0, &buf));
    try testing.expectEqualStrings("512 B", formatBytes(512, &buf));
    try testing.expectEqualStrings("1.00 KB", formatBytes(1024, &buf));
    try testing.expectEqualStrings("1.50 MB", formatBytes(1536 * 1024, &buf));
    try testing.expectEqualStrings("2.00 GB", formatBytes(2 * 1024 * 1024 * 1024, &buf));
}
```

**Step 2: Run tests to verify they fail**

Run: `nix develop -c zig build test`
Expected: Tests fail (stubs return empty).

**Step 3: Implement aggregateProcesses and formatBytes**

`aggregateProcesses` algorithm:
1. Iterate processes, build a hash map of `command → AggregatedProcess`
2. Accumulate cpu_percent, rss_bytes, and process_count per command
3. Collect into a slice, sort by the requested key (descending)
4. Truncate to max_results

`formatBytes`:
- Divide by 1024 repeatedly, picking the right unit (B, KB, MB, GB, TB)
- Format with `std.fmt.bufPrint`

**Step 4: Run tests to verify they pass**

Run: `nix develop -c zig build test`
Expected: All data processing tests pass.

**Step 5: Commit**

```bash
git add src/data.zig
git commit -m "Add process aggregation and byte formatting with TDD tests"
```

---

## Task 10: Config Parsing (TDD)

**Files:**
- Create: `src/config.zig`

**Step 1: Define the config struct and write failing tests**

```zig
const std = @import("std");
const toml = @import("toml");

pub const ModuleConfig = struct {
    priority: u8 = 0, // 0 means "use default"
    enabled: bool = true,
};

pub const PingModuleConfig = struct {
    priority: u8 = 0,
    enabled: bool = true,
    hosts: []const []const u8 = &default_hosts,
    ping_interval_ms: u32 = 2000,

    const default_hosts = [_][]const u8{ "google.com", "github.com", "cloudflare.com" };
};

pub const ThemeColors = struct {
    background: []const u8 = "#1a1a2e",
    primary: []const u8 = "#ff6600",
    accent: []const u8 = "#9933ff",
    success: []const u8 = "#00ff88",
    warning: []const u8 = "#ffaa00",
    @"error": []const u8 = "#ff3366",
    text: []const u8 = "#e0e0e0",
    text_dim: []const u8 = "#888888",
};

pub const Config = struct {
    update_interval_ms: u32 = 1000,
    process_count: u16 = 15,
    theme: []const u8 = "neon_orange",
    cpu_hogs: ModuleConfig = .{},
    mem_hogs: ModuleConfig = .{},
    cpu_graph: ModuleConfig = .{},
    ping_monitor: PingModuleConfig = .{},
    custom_theme: ThemeColors = .{},
};

/// Parse a config from a TOML string.
/// Returns Config with defaults for any missing values.
pub fn parseConfig(allocator: std.mem.Allocator, toml_source: []const u8) !Config {
    _ = allocator;
    _ = toml_source;
    return .{}; // stub
}

/// Get the platform-appropriate config file path.
pub fn defaultConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    _ = allocator;
    return ""; // stub
}

// ===== Tests =====

const testing = std.testing;

test "Config: defaults when empty" {
    const config = try parseConfig(testing.allocator, "");
    try testing.expectEqual(@as(u32, 1000), config.update_interval_ms);
    try testing.expectEqual(@as(u16, 15), config.process_count);
    try testing.expectEqualStrings("neon_orange", config.theme);
}

test "Config: override values" {
    const config = try parseConfig(testing.allocator,
        \\[general]
        \\update_interval_ms = 500
        \\process_count = 20
        \\theme = "neon_cyan"
    );
    try testing.expectEqual(@as(u32, 500), config.update_interval_ms);
    try testing.expectEqual(@as(u16, 20), config.process_count);
    try testing.expectEqualStrings("neon_cyan", config.theme);
}

test "Config: module priority override" {
    const config = try parseConfig(testing.allocator,
        \\[modules.cpu_hogs]
        \\priority = 3
        \\enabled = false
    );
    try testing.expectEqual(@as(u8, 3), config.cpu_hogs.priority);
    try testing.expectEqual(false, config.cpu_hogs.enabled);
}

test "Config: invalid TOML returns error" {
    const result = parseConfig(testing.allocator, "[invalid\ngarbage!!!");
    try testing.expectError(error.InvalidToml, result);
}
```

Note: The exact `toml` library API (sam701/zig-toml) parses directly into structs. The `parseConfig` implementation will need a TOML-compatible struct layout. The struct field names and nesting need to match the TOML sections. The implementer should consult the zig-toml README for struct mapping conventions and adjust the config struct layout accordingly.

**Step 2: Run tests to verify they fail**

Run: `nix develop -c zig build test`
Expected: Tests fail.

**Step 3: Implement parseConfig using zig-toml**

The zig-toml library maps TOML directly to Zig structs. The implementation should:
1. If source is empty, return default Config
2. Otherwise, parse with `toml.Parser(Config).init(allocator)` and `parser.parseString(source)`
3. Wrap parse errors as `error.InvalidToml`

**Step 4: Run tests to verify they pass**

**Step 5: Commit**

```bash
git add src/config.zig
git commit -m "Add TOML config parsing with defaults and TDD tests"
```

---

## Task 11: Theme System

**Files:**
- Create: `src/theme.zig`

**Step 1: Define theme presets and color parsing**

```zig
const std = @import("std");
const config = @import("config.zig");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

pub const Theme = struct {
    background: Color,
    primary: Color,
    accent: Color,
    success: Color,
    warning: Color,
    err: Color,
    text: Color,
    text_dim: Color,
};

/// Parse a hex color string like "#FF6600" or "#ff6600".
pub fn parseHexColor(hex: []const u8) !Color {
    if (hex.len != 7 or hex[0] != '#') return error.InvalidColor;
    return .{
        .r = try std.fmt.parseInt(u8, hex[1..3], 16),
        .g = try std.fmt.parseInt(u8, hex[3..5], 16),
        .b = try std.fmt.parseInt(u8, hex[5..7], 16),
    };
}

pub const neon_orange = Theme{
    .background = .{ .r = 0x1a, .g = 0x1a, .b = 0x2e },
    .primary = .{ .r = 0xff, .g = 0x66, .b = 0x00 },
    .accent = .{ .r = 0x99, .g = 0x33, .b = 0xff },
    .success = .{ .r = 0x00, .g = 0xff, .b = 0x88 },
    .warning = .{ .r = 0xff, .g = 0xaa, .b = 0x00 },
    .err = .{ .r = 0xff, .g = 0x33, .b = 0x66 },
    .text = .{ .r = 0xe0, .g = 0xe0, .b = 0xe0 },
    .text_dim = .{ .r = 0x88, .g = 0x88, .b = 0x88 },
};

pub const neon_cyan = Theme{
    .background = .{ .r = 0x1a, .g = 0x1a, .b = 0x1a },
    .primary = .{ .r = 0x00, .g = 0xff, .b = 0xff },
    .accent = .{ .r = 0xff, .g = 0x00, .b = 0xff },
    .success = .{ .r = 0x00, .g = 0xff, .b = 0x88 },
    .warning = .{ .r = 0xff, .g = 0xaa, .b = 0x00 },
    .err = .{ .r = 0xff, .g = 0x33, .b = 0x66 },
    .text = .{ .r = 0xe0, .g = 0xe0, .b = 0xe0 },
    .text_dim = .{ .r = 0x88, .g = 0x88, .b = 0x88 },
};

/// Resolve a theme from config.
pub fn resolveTheme(cfg: config.Config) !Theme {
    if (std.mem.eql(u8, cfg.theme, "neon_orange")) return neon_orange;
    if (std.mem.eql(u8, cfg.theme, "neon_cyan")) return neon_cyan;
    if (std.mem.eql(u8, cfg.theme, "custom")) {
        return Theme{
            .background = try parseHexColor(cfg.custom_theme.background),
            .primary = try parseHexColor(cfg.custom_theme.primary),
            .accent = try parseHexColor(cfg.custom_theme.accent),
            .success = try parseHexColor(cfg.custom_theme.success),
            .warning = try parseHexColor(cfg.custom_theme.warning),
            .err = try parseHexColor(cfg.custom_theme.@"error"),
            .text = try parseHexColor(cfg.custom_theme.text),
            .text_dim = try parseHexColor(cfg.custom_theme.text_dim),
        };
    }
    return error.UnknownTheme;
}

// ===== Tests =====

const testing = std.testing;

test "parseHexColor: valid colors" {
    const c = try parseHexColor("#FF6600");
    try testing.expectEqual(@as(u8, 0xFF), c.r);
    try testing.expectEqual(@as(u8, 0x66), c.g);
    try testing.expectEqual(@as(u8, 0x00), c.b);
}

test "parseHexColor: lowercase" {
    const c = try parseHexColor("#00ffff");
    try testing.expectEqual(@as(u8, 0x00), c.r);
    try testing.expectEqual(@as(u8, 0xff), c.g);
    try testing.expectEqual(@as(u8, 0xff), c.b);
}

test "parseHexColor: invalid format" {
    try testing.expectError(error.InvalidColor, parseHexColor("FF6600"));
    try testing.expectError(error.InvalidColor, parseHexColor("#FFF"));
}

test "resolveTheme: built-in presets" {
    const cfg_orange = config.Config{ .theme = "neon_orange" };
    const t = try resolveTheme(cfg_orange);
    try testing.expectEqual(@as(u8, 0xFF), t.primary.r);
}
```

**Step 2: Run tests, verify pass**

**Step 3: Commit**

```bash
git add src/theme.zig
git commit -m "Add theme system with neon_orange and neon_cyan presets"
```

---

## Task 12: CPU Hogs Module Data Logic (TDD)

**Files:**
- Create: `src/modules/cpu_hogs.zig`

This task implements the data processing logic only (not DVUI rendering). The module maintains sorted, aggregated process data that the render function will display.

**Step 1: Write failing tests for the data logic**

Test that given mock process data, the module correctly aggregates, sorts, and computes system percentages.

**Step 2: Implement the data processing**

- `update()` calls `stats.getProcessList()`, runs `data.aggregateProcesses(.cpu)`, stores result
- Compute `% of system = total_cpu / (num_cores * 100) * 100`
- Detect process storms (count > threshold)

**Step 3: Run tests, verify pass**

**Step 4: Commit**

---

## Task 13: Memory Hogs Module Data Logic (TDD)

**Files:**
- Create: `src/modules/mem_hogs.zig`

Same pattern as Task 12 but sorting by RSS and computing memory percentages.

**Step 1-4: Same TDD cycle as Task 12**

---

## Task 14: CPU Graph Module Data Logic (TDD)

**Files:**
- Create: `src/modules/cpu_graph.zig`

**Step 1: Write failing tests**

Test that the module maintains a ring buffer of CPU snapshots, timestamps them, and returns data suitable for plotting.

**Step 2: Implement**

- `update()` calls `stats.getCpuSnapshot()`, pushes to ring buffer with timestamp
- Expose `getPlotData()` returning `([]const f64, []const f64)` for x (time) and y (cpu%) axes

**Step 3: Run tests, verify pass**

**Step 4: Commit**

---

## Task 15: Ping Monitor Module Data Logic (TDD)

**Files:**
- Create: `src/modules/ping_monitor.zig`

**Step 1: Write failing tests**

Test that the module maintains per-host ring buffers, handles timeouts (null latency), and returns plot data per host.

**Step 2: Implement**

- Manages a list of hosts (from config)
- `update()` pings each host, pushes result to per-host ring buffer
- Expose `getPlotData(host_index)` for the UI

**Step 3: Run tests, verify pass**

**Step 4: Commit**

---

## Task 16: Wire Up App with Module Registry

**Files:**
- Create: `src/app.zig`
- Modify: `src/main.zig`

**Step 1: Create app.zig**

App holds:
- Config
- Module registry (flat list of `Module`)
- LayoutEngine reference
- SystemStats interface
- Theme

`App.init()`:
1. Parse config (from file or defaults)
2. Create SystemStats (platform-appropriate)
3. Create all modules, register in list
4. Resolve theme

`App.frame()`:
1. Check config hot-reload
2. Call `module.update()` for each module
3. Compute layout
4. Render each visible module into its rect
5. Render status bar

**Step 2: Update main.zig**

Wire the DVUI App pattern to call `App.frame()` each frame. The `appFrame()` function creates the DVUI widgets based on the layout engine's output.

**Step 3: Build and run**

Run: `nix develop -c zig build run`
Expected: Window opens with module subsections showing mock data (since we haven't built real platform backends yet).

**Step 4: Commit**

---

## Task 17: Module Rendering (DVUI)

**Files:**
- Modify: `src/modules/cpu_hogs.zig` (add render method)
- Modify: `src/modules/mem_hogs.zig` (add render method)
- Modify: `src/modules/cpu_graph.zig` (add render method using PlotWidget)
- Modify: `src/modules/ping_monitor.zig` (add render method using PlotWidget)

For each module, implement the `moduleRender` function that uses DVUI widgets:

- **cpu_hogs / mem_hogs**: Use DVUI's grid/table layout for the process list
- **cpu_graph**: Use `dvui.plot()` with `plot.line()` for the CPU time series
- **ping_monitor**: Use `dvui.plot()` with multiple `plot.line()` calls, one per host

This task is not TDD'd (rendering correctness is visual). Verify by running the app and visually inspecting.

**Step 1: Implement rendering for each module**

Consult DVUI's `src/Examples/plots.zig` for PlotWidget usage patterns.

**Step 2: Build and run, visually verify**

**Step 3: Commit**

---

## Task 18: Status Bar and Menu

**Files:**
- Create: `src/status_bar.zig`
- Create: `src/menu.zig`
- Modify: `src/app.zig` (integrate)

**Step 1: Implement status bar**

A thin bar at the bottom of the window showing:
- Config status ("Config reloaded" fading message, or "Config error: ..." persistent)
- Last refresh timestamp

**Step 2: Implement menu**

A minimal menu bar with:
- "Systat" menu → "About" (shows version dialog), "Quit" (closes app)

**Step 3: Integrate into app.zig frame loop**

**Step 4: Build and run, verify**

**Step 5: Commit**

---

## Task 19: macOS Platform Backend

**Files:**
- Create: `src/platform/darwin.zig`

Implement `SystemStats` for macOS:
- **Process list**: Call `sysctl` (CTL_KERN, KERN_PROC, KERN_PROC_ALL) or use `std.process.Child` to run `ps`
- **CPU snapshot**: Use `host_processor_info()` mach API or parse `/usr/bin/top -l 1`
- **Memory**: Use `host_statistics64()` mach API
- **Ping**: Use `std.process.Child` to run `ping -c 1 -W 2 <host>` and parse output

Start with the simplest approach that works (shelling out to `ps` and `ping`), then optimize later.

**Step 1: Implement DarwinBackend**

**Step 2: Write smoke tests**

Verify returned values are in plausible ranges (CPU 0-100, memory > 0, process list non-empty).

**Step 3: Wire into app.zig** (replace mock with real backend on macOS)

**Step 4: Build and run on Mac**

**Step 5: Commit**

---

## Task 20: Config Hot-Reload with File Watcher

**Files:**
- Create: `src/platform/file_watcher.zig`
- Modify: `src/app.zig` (integrate)

**Step 1: Implement file watcher**

macOS: Use `kqueue` with `EVFILT_VNODE` + `NOTE_WRITE`
Linux: Use `inotify`
Windows: Use `ReadDirectoryChangesW`

Start with macOS (kqueue) since that's the dev platform.

The watcher runs on a background thread, signals the main thread via an atomic flag or callback when the file changes.

**Step 2: Integrate into App**

In `App.frame()`, check if the watcher flagged a change. If so, re-parse config. On success, apply. On failure, show error in status bar.

**Step 3: Test manually**

Edit config.toml while the app is running, verify changes are reflected.

**Step 4: Commit**

---

## Task 21: Example Config File

**Files:**
- Create: `config.example.toml`

**Step 1: Create a fully-documented example config**

Include all options with comments explaining each one, default values noted.

**Step 2: Commit**

---

## Task 22: Documentation

**Files:**
- Create: `PLAN.md`
- Create: `CODE_MINIMAP.md`
- Update: `.gitignore` (add zig-out/, zig-cache/, .zig-cache/)

**Step 1: Create PLAN.md**

List remaining work items, future module ideas, and completed tasks.

**Step 2: Create CODE_MINIMAP.md**

Document every source file and its key functions/types.

**Step 3: Update .gitignore**

```
.DS_Store
zig-out/
zig-cache/
.zig-cache/
result
flake.lock
```

**Step 4: Commit**

---

## Task 23: Linux Platform Backend (Post-MVP)

**Files:**
- Create: `src/platform/linux.zig`

Implement for Linux using `/proc/stat`, `/proc/meminfo`, `/proc/{pid}/stat`, etc.

---

## Task 24: Windows Platform Backend (Post-MVP)

**Files:**
- Create: `src/platform/windows.zig`

Implement using WMI or Windows performance counters.

---

## Dependency Graph

```
Task 1 (flake.nix)
  └── Task 2 (build system)
       ├── Task 3 (scripts)
       └── Task 4 (DVUI hello world)
            └── Task 5 (ring buffer) ──────────────────┐
                 Task 6 (module interface) ─────────────┤
                 Task 7 (layout engine) ────────────────┤
                 Task 8 (stats interface + mock) ───────┤
                 Task 9 (data processing) ──────────────┤
                 Task 10 (config parsing) ──────────────┤
                 Task 11 (theme system) ────────────────┤
                      │                                 │
                      ├── Task 12 (cpu_hogs logic) ─────┤
                      ├── Task 13 (mem_hogs logic) ─────┤
                      ├── Task 14 (cpu_graph logic) ────┤
                      ├── Task 15 (ping_monitor logic) ─┤
                      │                                 │
                      └── Task 16 (app wiring) ◄────────┘
                           └── Task 17 (module rendering)
                                ├── Task 18 (status bar + menu)
                                ├── Task 19 (macOS backend)
                                └── Task 20 (config hot-reload)
                                     └── Task 21 (example config)
                                          └── Task 22 (docs)
```

Tasks 5-11 can be done in parallel (no dependencies between them).
Tasks 12-15 can be done in parallel.
Tasks 17-20 can be partially parallelized.
