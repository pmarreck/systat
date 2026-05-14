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
	summary: stats.SystemSummary = .{},

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

		// 3. Get memory snapshot and system summary
		const mem_snap = self.stats_iface.getMemSnapshot();
		self.total_mem_bytes = mem_snap.total_bytes;
		self.used_mem_bytes = mem_snap.used_bytes;
		self.summary = self.stats_iface.getSystemSummary();
	}

	// ── Module vtable methods ────────────────────────────────────────

	pub fn moduleInfo(_: *MemHogs) mod.ModuleInfo {
		return .{
			.id = "mem_hogs",
			.display_name = "Memory Hogs",
			.default_priority = 4,
			.min_width = 250,
			.min_height = 200,
			.preferred_width = 400,
			.preferred_height = 350,
		};
	}

	pub fn moduleUpdate(self: *MemHogs) void {
		self.update();
	}

	pub fn moduleRender(self: *MemHogs) void {
		const dvui = @import("dvui");
		const data_mod = @import("../data.zig");

		// Format total/used memory for header
		var total_buf: [32]u8 = undefined;
		var used_buf: [32]u8 = undefined;
		const total_str = data_mod.formatBytes(self.total_mem_bytes, &total_buf);
		const used_str = data_mod.formatBytes(self.used_mem_bytes, &used_buf);

		dvui.label(@src(), "Memory Hogs \u{2014} {s} / {s}", .{ used_str, total_str }, .{
			.font = dvui.themeGet().font_heading,
		});

		if (self.aggregated) |agg| {
			const Static = struct {
				var col_widths: [3]f32 = .{ 0, 0, 0 };
			};
			var grid = dvui.grid(@src(), .{ .col_widths = &Static.col_widths }, .{}, .{ .expand = .both });
			defer grid.deinit();

			dvui.columnLayoutProportional(&.{ -3, -1, -1 }, &Static.col_widths, grid.data().contentRect().w);

			dvui.gridHeading(@src(), grid, 0, "Command", .fixed, .{});
			dvui.gridHeading(@src(), grid, 1, "Memory", .fixed, .{});
			dvui.gridHeading(@src(), grid, 2, "Procs", .fixed, .{});

			for (agg, 0..) |proc, row| {
				{
					var cell = grid.bodyCell(@src(), .{ .col_num = 0, .row_num = row }, .{});
					defer cell.deinit();
					dvui.labelNoFmt(@src(), proc.command, .{}, .{});
				}
				{
					var cell = grid.bodyCell(@src(), .{ .col_num = 1, .row_num = row }, .{});
					defer cell.deinit();
					var buf: [32]u8 = undefined;
					const mem_str = data_mod.formatBytes(proc.total_rss_bytes, &buf);
					dvui.labelNoFmt(@src(), mem_str, .{}, .{});
				}
				{
					var cell = grid.bodyCell(@src(), .{ .col_num = 2, .row_num = row }, .{});
					defer cell.deinit();
					dvui.label(@src(), "{d}", .{proc.process_count}, .{});
				}
			}
		} else {
			dvui.label(@src(), "No data yet", .{}, .{});
		}

		// Memory detail footer
		const s = self.summary;
		var wired_buf: [32]u8 = undefined;
		var comp_buf: [32]u8 = undefined;
		const wired_str = data_mod.formatBytes(s.wired_bytes, &wired_buf);
		const comp_str = data_mod.formatBytes(s.compressor_bytes, &comp_buf);
		dvui.label(@src(), "Wired: {s}  Compressor: {s}  |  Swap in/out: {d}/{d}", .{
			wired_str, comp_str, s.swap_ins, s.swap_outs,
		}, .{ .font = dvui.themeGet().font_mono });
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
	try testing.expectEqual(@as(u8, 4), info.default_priority);
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
	const dvui = @import("dvui");
	var mock = MockStats{};
	const iface = mock.interface();
	var mh = MemHogs.init(testing.allocator, iface, 10);

	const m = mod.Module.from(&mh);
	const info = m.info();
	try testing.expectEqualStrings("mem_hogs", info.id);

	m.update();
	try testing.expect(mh.aggregated != null);

	// render() needs DVUI context — test via frame. Wrap in a box so the
	// expanded child inside moduleRender() has a parent constraint (dvui 0.5
	// is stricter about layout).
	const RenderTest = struct {
		var render_target: ?*MemHogs = null;
		fn frame() !dvui.App.Result {
			if (render_target) |target| {
				var panel = dvui.box(@src(), .{}, .{ .expand = .both });
				defer panel.deinit();
				target.moduleRender();
			}
			return .ok;
		}
	};
	RenderTest.render_target = &mh;
	var t = try dvui.testing.init(.{});
	defer t.deinit();
	_ = try dvui.testing.step(RenderTest.frame);

	m.deinit();
	try testing.expect(mh.aggregated == null);
}
