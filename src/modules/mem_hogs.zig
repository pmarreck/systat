//! Memory Hogs module — data processing logic.
//!
//! Aggregates running processes by command name sorted by memory (RSS)
//! descending, and caches total/used memory snapshots.  Implements the
//! `Module` vtable so it can be registered in the module registry.

const std = @import("std");
const stats = @import("../platform/stats.zig");
const data = @import("../data.zig");
const mod = @import("../module.zig");

pub const MemHogs = struct {
	allocator: std.mem.Allocator,
	stats_iface: stats.SystemStats,
	max_processes: u16,

	// Cached data from last update
	aggregated: ?[]data.AggregatedProcess = null,
	total_mem_bytes: u64 = 0,
	used_mem_bytes: u64 = 0,

	pub fn init(
		allocator: std.mem.Allocator,
		stats_iface: stats.SystemStats,
		max_processes: u16,
	) MemHogs {
		return .{
			.allocator = allocator,
			.stats_iface = stats_iface,
			.max_processes = max_processes,
		};
	}

	pub fn deinit(self: *MemHogs) void {
		if (self.aggregated) |agg| self.allocator.free(agg);
		self.aggregated = null;
	}

	/// Refresh cached data: process list (aggregated by memory) and
	/// memory snapshot.
	pub fn update(self: *MemHogs) void {
		// 1. Free previous cached aggregated data
		if (self.aggregated) |agg| {
			self.allocator.free(agg);
			self.aggregated = null;
		}

		// 2. Get process list and aggregate by memory
		const processes = self.stats_iface.getProcessList();
		self.aggregated = data.aggregateProcesses(
			self.allocator,
			processes,
			.memory,
			self.max_processes,
		) catch null;

		// 3. Get memory snapshot
		const mem_snap = self.stats_iface.getMemSnapshot();
		self.total_mem_bytes = mem_snap.total_bytes;
		self.used_mem_bytes = mem_snap.used_bytes;
	}

	// ── Module vtable methods ────────────────────────────────────────

	pub fn moduleInfo(_: *MemHogs) mod.ModuleInfo {
		return .{
			.id = "mem_hogs",
			.display_name = "Memory Hogs",
			.default_priority = 2,
			.min_width = 250,
			.min_height = 200,
			.preferred_width = 400,
			.preferred_height = 350,
		};
	}

	pub fn moduleUpdate(self: *MemHogs) void {
		self.update();
	}

	pub fn moduleRender(_: *MemHogs) void {
		// No-op for now — rendering will be added later.
	}

	pub fn moduleDeinit(self: *MemHogs) void {
		self.deinit();
	}
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const MockStats = @import("../platform/mock.zig").MockStats;

test "init creates valid struct with expected defaults" {
	var mock = MockStats{};
	const iface = mock.interface();
	const mh = MemHogs.init(testing.allocator, iface, 10);

	try testing.expectEqual(@as(u16, 10), mh.max_processes);
	try testing.expect(mh.aggregated == null);
	try testing.expectEqual(@as(u64, 0), mh.total_mem_bytes);
	try testing.expectEqual(@as(u64, 0), mh.used_mem_bytes);
}

test "update populates aggregated data" {
	var mock = MockStats{};
	const iface = mock.interface();
	var mh = MemHogs.init(testing.allocator, iface, 10);
	defer mh.deinit();

	// Before update: null
	try testing.expect(mh.aggregated == null);

	mh.update();

	// After update: non-null with entries
	try testing.expect(mh.aggregated != null);
	try testing.expect(mh.aggregated.?.len > 0);
}

test "aggregated sorted by memory — firefox first" {
	var mock = MockStats{};
	const iface = mock.interface();
	var mh = MemHogs.init(testing.allocator, iface, 10);
	defer mh.deinit();

	mh.update();

	const agg = mh.aggregated.?;
	// firefox has 1.2GB RSS, the highest in mock data
	try testing.expectEqualStrings("firefox", agg[0].command);
	// node has 500MB, second highest
	try testing.expectEqualStrings("node", agg[1].command);
}

test "total memory captured — 16GB" {
	var mock = MockStats{};
	const iface = mock.interface();
	var mh = MemHogs.init(testing.allocator, iface, 10);
	defer mh.deinit();

	mh.update();

	const expected_total: u64 = 16 * 1024 * 1024 * 1024;
	try testing.expectEqual(expected_total, mh.total_mem_bytes);
}

test "used memory captured — 10GB" {
	var mock = MockStats{};
	const iface = mock.interface();
	var mh = MemHogs.init(testing.allocator, iface, 10);
	defer mh.deinit();

	mh.update();

	const expected_used: u64 = 10 * 1024 * 1024 * 1024;
	try testing.expectEqual(expected_used, mh.used_mem_bytes);
}

test "moduleInfo returns correct id and priority" {
	var mock = MockStats{};
	const iface = mock.interface();
	var mh = MemHogs.init(testing.allocator, iface, 10);

	const info = mh.moduleInfo();
	try testing.expectEqualStrings("mem_hogs", info.id);
	try testing.expectEqualStrings("Memory Hogs", info.display_name);
	try testing.expectEqual(@as(u8, 2), info.default_priority);
	try testing.expectEqual(@as(u16, 250), info.min_width);
	try testing.expectEqual(@as(u16, 200), info.min_height);
	try testing.expectEqual(@as(u16, 400), info.preferred_width);
	try testing.expectEqual(@as(u16, 350), info.preferred_height);
}

test "double update frees old data without leaking" {
	var mock = MockStats{};
	const iface = mock.interface();
	var mh = MemHogs.init(testing.allocator, iface, 10);
	defer mh.deinit();

	mh.update();
	try testing.expect(mh.aggregated != null);

	// Second update should free the first allocation, no leak
	mh.update();
	try testing.expect(mh.aggregated != null);
}

test "deinit frees cached data without leaking" {
	var mock = MockStats{};
	const iface = mock.interface();
	var mh = MemHogs.init(testing.allocator, iface, 10);

	mh.update();
	try testing.expect(mh.aggregated != null);

	// deinit should free; if it leaks, testing.allocator will catch it
	mh.deinit();
	try testing.expect(mh.aggregated == null);
}

test "Module vtable integration" {
	var mock = MockStats{};
	const iface = mock.interface();
	var mh = MemHogs.init(testing.allocator, iface, 10);

	const m = mod.Module.from(&mh);
	const info = m.info();
	try testing.expectEqualStrings("mem_hogs", info.id);

	m.update();
	try testing.expect(mh.aggregated != null);

	m.render(); // no-op, should not crash

	m.deinit();
	try testing.expect(mh.aggregated == null);
}
