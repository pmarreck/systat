const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const AppState = @import("app_state.zig").AppState;
const config = @import("config.zig");
const mock = @import("platform/mock.zig");
const darwin = @import("platform/darwin.zig");
const menu = @import("menu.zig");
const StatusBar = @import("status_bar.zig").StatusBar;
const window_state = @import("window_state.zig");
const runtime = @import("runtime.zig");

/// Read a monotonic clock as i128 nanoseconds (0.16 replacement for std.time.nanoTimestamp).
fn monotonicNs(io: std.Io) i128 {
    const ts = std.Io.Timestamp.now(io, .awake);
    return @intCast(ts.toNanoseconds());
}

// File-scope state — initialized in appInit, freed in appDeinit.
// DVUI's frameFn signature takes no state parameter, so we persist here.
var app_state: ?*AppState = null;
var mock_stats: ?*mock.MockStats = null;
var darwin_backend: ?*darwin.DarwinBackend = null;
var status_bar: StatusBar = StatusBar.init();
var gpa: std.heap.DebugAllocator(.{}) = .init;

// Resize detection — skip expensive updates while window is being resized
var last_window_size: [2]f32 = .{ 0, 0 };
var resize_cooldown_ns: i128 = 0; // timestamp when resize gesture "ends" (+ grace period)
var needs_raise: bool = true; // raise window to foreground on first frame
var needs_state_restore: bool = true; // restore saved window state on first frame

const RESIZE_COOLDOWN_MS: i128 = 500; // ms after last resize event before resuming updates

const window_icon = @embedFile("assets/icon.png");

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 1200.0, .h = 900.0 },
            .min_size = .{ .w = 400.0, .h = 300.0 },
            .title = "systat",
            .icon = window_icon,
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
    // Stash io + environ from dvui's Juicy Main hand-off. Everything in the
    // app (file_watcher, darwin backend, ping_monitor, etc.) reaches into
    // `runtime.io()` instead of threading io explicitly — keeps dvui's
    // frameFn signature (which takes no state param) workable.
    if (dvui.App.main_init) |mi| {
        runtime.set(mi.io, mi.environ_map);
    } else {
        runtime.setForTests();
    }

    const allocator = gpa.allocator();

    // Create platform-appropriate stats backend
    const stats_iface = blk: {
        if (comptime builtin.os.tag == .macos) {
            const db = try allocator.create(darwin.DarwinBackend);
            db.* = darwin.DarwinBackend.init(allocator);
            darwin_backend = db;
            break :blk db.interface();
        } else {
            const ms = try allocator.create(mock.MockStats);
            ms.* = .{};
            mock_stats = ms;
            break :blk ms.interface();
        }
    };

    const state = try allocator.create(AppState);
    state.* = try AppState.init(allocator, stats_iface, config.defaultConfig());
    app_state = state;

    // Apply our cyberpunk theme to DVUI
    win.themeSet(state.theme);

    if (comptime @import("builtin").mode == .Debug) {
        std.debug.print("\x1b[33mDEBUG BUILD\x1b[0m\n", .{});
    }
}

pub fn appDeinit() void {
    // Save window state before teardown
    {
        const backend = @import("backend");
        if (@hasDecl(backend, "c")) {
            const sdl_win = backend.c.SDL_GetKeyboardFocus();
            if (sdl_win != null) {
                var w: c_int = 0;
                var h: c_int = 0;
                var x: c_int = 0;
                var y: c_int = 0;
                _ = backend.c.SDL_GetWindowSize(sdl_win, &w, &h);
                _ = backend.c.SDL_GetWindowPosition(sdl_win, &x, &y);
                window_state.save(.{
                    .width = @intCast(w),
                    .height = @intCast(h),
                    .x = @intCast(x),
                    .y = @intCast(y),
                });
            }
        }
    }

    const allocator = gpa.allocator();
    if (app_state) |state| {
        state.deinit();
        allocator.destroy(state);
        app_state = null;
    }
    if (darwin_backend) |db| {
        db.deinit();
        allocator.destroy(db);
        darwin_backend = null;
    }
    if (mock_stats) |ms| {
        allocator.destroy(ms);
        mock_stats = null;
    }
}

pub fn appFrame() !dvui.App.Result {
    // On first frame: raise window to foreground (macOS needs this) and
    // restore saved window state (size + position).
    if (needs_raise) {
        needs_raise = false;
        const backend = @import("backend");
        if (@hasDecl(backend, "c")) {
            const sdl_win = backend.c.SDL_GetKeyboardFocus();
            if (sdl_win != null) {
                _ = backend.c.SDL_RaiseWindow(sdl_win);

                // Restore saved window state
                if (needs_state_restore) {
                    needs_state_restore = false;
                    if (window_state.load()) |ws| {
                        _ = backend.c.SDL_SetWindowSize(sdl_win, ws.width, ws.height);
                        _ = backend.c.SDL_SetWindowPosition(sdl_win, ws.x, ws.y);
                    }
                }
            }
        }
    }

    // Detect resize: compare current pixel size to last frame's.
    // Use a cooldown so we don't immediately block on updates between
    // rapid size-change events during a drag gesture.
    const win_rect = dvui.currentWindow().rect_pixels;
    const now_ns = monotonicNs(runtime.io());
    const size_changed = (last_window_size[0] != 0 and
        (win_rect.w != last_window_size[0] or win_rect.h != last_window_size[1]));
    last_window_size = .{ win_rect.w, win_rect.h };

    if (size_changed) {
        resize_cooldown_ns = now_ns + RESIZE_COOLDOWN_MS * 1_000_000;
    }
    const in_resize_gesture = now_ns < resize_cooldown_ns;

    // Re-raise window after resize gesture ends (macOS can lose focus during drag)
    if (!in_resize_gesture and resize_cooldown_ns != 0 and now_ns >= resize_cooldown_ns) {
        resize_cooldown_ns = 0; // only fire once
        const backend = @import("backend");
        if (@hasDecl(backend, "c")) {
            const sdl_win = backend.c.SDL_GetKeyboardFocus();
            if (sdl_win != null) {
                _ = backend.c.SDL_RaiseWindow(sdl_win);
            }
        }
    }

    // Check config hot-reload and update modules (skip during resize)
    if (app_state) |state| {
        state.checkConfigReload();

        // Propagate config status to status bar
        if (state.last_config_status) |msg| {
            if (state.config_status_is_error) {
                status_bar.setError(msg);
            } else {
                status_bar.setMessage(msg);
            }
            state.last_config_status = null;
        }

        if (!in_resize_gesture) {
            state.updateAll();
        }
    }

    // Main layout: vertical box filling the window
    {
        var vbox = dvui.box(@src(), .{}, .{ .expand = .both });
        defer vbox.deinit();

        // Menu bar at top
        const menu_action = menu.render();
        if (menu_action == .quit) return .close;

        if (app_state) |state| {
            // Row 1: Graph modules (CPU Graph + Web Ping) — high priority
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
                defer row.deinit();

                // CPU Graph panel
                {
                    var panel = dvui.box(@src(), .{}, .{
                        .expand = .both,
                        .border = dvui.Rect.all(1),
                        .padding = dvui.Rect.all(4),
                    });
                    defer panel.deinit();
                    state.cpu_graph.moduleRender();
                }

                // Web Ping panel
                {
                    var panel = dvui.box(@src(), .{}, .{
                        .expand = .both,
                        .border = dvui.Rect.all(1),
                        .padding = dvui.Rect.all(4),
                    });
                    defer panel.deinit();
                    state.ping_monitor.moduleRender();
                }
            }

            // Row 2: Table modules (CPU Hogs + Mem Hogs)
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
                defer row.deinit();

                // CPU Hogs panel
                {
                    var panel = dvui.box(@src(), .{}, .{
                        .expand = .both,
                        .border = dvui.Rect.all(1),
                        .padding = dvui.Rect.all(4),
                    });
                    defer panel.deinit();
                    state.cpu_hogs.moduleRender();
                }

                // Mem Hogs panel
                {
                    var panel = dvui.box(@src(), .{}, .{
                        .expand = .both,
                        .border = dvui.Rect.all(1),
                        .padding = dvui.Rect.all(4),
                    });
                    defer panel.deinit();
                    state.mem_hogs.moduleRender();
                }
            }
        }

        // Status bar at bottom
        status_bar.render();
    }

    return .ok;
}

test "basic frame without state" {
    runtime.setForTests();
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    // app_state is null in tests — frame should still work (just shows header + quit)
    try dvui.testing.settle(appFrame);
}

test "full frame with real DarwinBackend (macOS only)" {
    if (comptime @import("builtin").os.tag != .macos) return;
    runtime.setForTests();

    const theme_mod = @import("theme.zig");
    const CpuHogs = @import("modules/cpu_hogs.zig").CpuHogs;
    const MemHogs = @import("modules/mem_hogs.zig").MemHogs;
    const CpuGraphMod = @import("modules/cpu_graph.zig").CpuGraph;
    const PingMonitor = @import("modules/ping_monitor.zig").PingMonitor;
    const FileWatcher = @import("file_watcher.zig").FileWatcher;

    const alloc = std.testing.allocator;
    const db = try alloc.create(darwin.DarwinBackend);
    db.* = darwin.DarwinBackend.init(alloc);
    defer {
        db.deinit();
        alloc.destroy(db);
    }

    const cfg = config.defaultConfig();
    const iface = db.interface();

    // Field-by-field init to avoid 37KB stack temporaries
    const state = try alloc.create(AppState);
    state.allocator = alloc;
    state.cfg = cfg;
    state.theme = try theme_mod.resolveTheme(cfg);
    state.cpu_hogs = CpuHogs.init(alloc, iface, cfg.process_count);
    state.mem_hogs = MemHogs.init(alloc, iface, cfg.process_count);
    state.cpu_graph = CpuGraphMod.init(iface);
    state.ping_monitor = PingMonitor.init(iface, cfg.ping_monitor.hosts);
    state.config_watcher = FileWatcher.init("config.toml", 2000);
    state.config_arena = null;
    state.last_config_status = null;
    state.config_status_is_error = false;
    defer {
        state.deinit();
        alloc.destroy(state);
    }

    state.cpu_hogs.update();
    try std.testing.expect(state.cpu_hogs.aggregated != null);

    state.mem_hogs.update();
    try std.testing.expect(state.mem_hogs.aggregated != null);

    // Set global state and render a frame (mimics appFrame)
    const saved = app_state;
    app_state = state;
    defer {
        app_state = saved;
    }

    var t = try dvui.testing.init(.{});
    defer t.deinit();
    _ = try dvui.testing.step(appFrame);
}

// Import all modules so their tests are discovered by `zig build test`.
comptime {
    _ = @import("ring_buffer.zig");
    _ = @import("module.zig");
    _ = @import("layout.zig");
    _ = @import("config.zig");
    _ = @import("theme.zig");
    _ = @import("data.zig");
    _ = @import("platform/stats.zig");
    _ = @import("platform/mock.zig");
    _ = @import("platform/darwin.zig");
    _ = @import("modules/cpu_hogs.zig");
    _ = @import("modules/mem_hogs.zig");
    _ = @import("modules/cpu_graph.zig");
    _ = @import("modules/ping_monitor.zig");
    _ = @import("app_state.zig");
    _ = @import("status_bar.zig");
    _ = @import("menu.zig");
    _ = @import("file_watcher.zig");
    _ = @import("window_state.zig");
    _ = @import("runtime.zig");
}
