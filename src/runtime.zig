//! Runtime singleton for Zig 0.16's std.Io interface.
//!
//! dvui owns main() so we can't accept `std.process.Init` directly. Instead we
//! pull values out of `dvui.App.main_init` at app boot (see app.zig:appInit)
//! and stash them here so the rest of the program can keep using "static"
//! call sites without threading `io` through every signature.
//!
//! Tests don't run through dvui.App.main, so they install their own io via
//! `setForTests`. We use a lazily-initialized `std.Io.Threaded` because
//! `global_single_threaded` is NOT usable for process spawning, only for
//! mutex/futex primitives (per the bzip2z firsthand note in the migration
//! guide).

const std = @import("std");

var g_io: ?std.Io = null;
var g_env: ?*const std.process.Environ.Map = null;

// Test-only threaded runtime. Allocated with the page allocator so tests can
// just call `setForTests()` without worrying about ownership/teardown.
var test_threaded: ?std.Io.Threaded = null;
var test_env_storage: std.process.Environ.Map = .{
    .array_hash_map = .empty,
    .allocator = std.heap.page_allocator,
};

/// Set by app.zig:appInit from dvui.App.main_init.
pub fn set(io_value: std.Io, env_map: *const std.process.Environ.Map) void {
    g_io = io_value;
    g_env = env_map;
}

/// Returns the live io. Asserts that setup happened — production code paths
/// always run through `appInit`, and tests should call `setForTests` first.
pub fn io() std.Io {
    return g_io orelse @panic("runtime.io() called before runtime.set()/setForTests()");
}

pub fn env() *const std.process.Environ.Map {
    return g_env orelse @panic("runtime.env() called before runtime.set()/setForTests()");
}

/// In test contexts, install a real (threaded) Io implementation so tests
/// that spawn subprocesses or do real fs I/O work. The threaded instance
/// is leaked at process exit — fine for tests.
pub fn setForTests() void {
    if (test_threaded == null) {
        test_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    }
    g_io = test_threaded.?.io();
    g_env = &test_env_storage;
}

/// Like setForTests but also stamps a specific env map.
pub fn setForTestsWithEnv(env_map: *const std.process.Environ.Map) void {
    setForTests();
    g_env = env_map;
}
