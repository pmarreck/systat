//! CPU Hogs module — data processing logic.
//! Fetches process list via SystemStats vtable, aggregates by CPU usage,
//! and caches the result for rendering.

const std = @import("std");
const stats = @import("../platform/stats.zig");
const mock = @import("../platform/mock.zig");
const data = @import("../data.zig");
const module = @import("../module.zig");

pub const CpuHogs = struct {
	allocator: std.mem.Allocator,
	stats_iface: stats.SystemStats,
	max_processes: u16,

	// Cached data from last update
	aggregated: ?[]data.AggregatedProcess = null,
	system_cpu_percent: f64 = 0,
	num_cores: u16 = 0,
	summary: stats.SystemSummary = .{},

	pub fn init(allocator: std.mem.Allocator, stats_iface: stats.SystemStats, max_processes: u16) CpuHogs {
		return .{
			.allocator = allocator,
			.stats_iface = stats_iface,
			.max_processes = max_processes,
		};
	}

	pub fn deinit(self: *CpuHogs) void {
		if (self.aggregated) |agg| {
			self.allocator.free(agg);
			self.aggregated = null;
		}
	}

	pub fn update(self: *CpuHogs) void {
		// Free previous cached data if any
		if (self.aggregated) |agg| {
			self.allocator.free(agg);
			self.aggregated = null;
		}

		// Fetch process list and CPU snapshot
		const processes = self.stats_iface.getProcessList();
		const cpu_snap = self.stats_iface.getCpuSnapshot();

		self.system_cpu_percent = cpu_snap.total_percent;
		self.num_cores = cpu_snap.num_cores;
		self.summary = self.stats_iface.getSystemSummary();

		// Aggregate processes by CPU
		self.aggregated = data.aggregateProcesses(
			self.allocator,
			processes,
			.cpu,
			self.max_processes,
		) catch null;
	}

	// -- Module interface methods ------------------------------------------

	pub fn moduleInfo(_: *CpuHogs) module.ModuleInfo {
		return .{
			.id = "cpu_hogs",
			.display_name = "CPU Hogs",
			.default_priority = 3,
			.min_width = 250,
			.min_height = 200,
			.preferred_width = 400,
			.preferred_height = 350,
		};
	}

	pub fn moduleUpdate(self: *CpuHogs) void {
		self.update();
	}

	pub fn moduleRender(self: *CpuHogs) void {
		const dvui = @import("dvui");

		dvui.label(@src(), "CPU Hogs \u{2014} {d:.1}% total ({d} cores)", .{
			self.system_cpu_percent, self.num_cores,
		}, .{ .font = dvui.themeGet().font_heading });

		if (self.aggregated) |agg| {
			const Static = struct {
				var col_widths: [3]f32 = .{ 0, 0, 0 };
			};
			var grid = dvui.grid(@src(), .{ .col_widths = &Static.col_widths }, .{}, .{ .expand = .both });
			defer grid.deinit();

			dvui.columnLayoutProportional(&.{ -3, -1, -1 }, &Static.col_widths, grid.data().contentRect().w);

			dvui.gridHeading(@src(), grid, 0, "Command", .fixed, .{});
			dvui.gridHeading(@src(), grid, 1, "CPU %", .fixed, .{});
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
					dvui.label(@src(), "{d:.1}%", .{proc.total_cpu_percent}, .{});
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

		// System summary footer
		const s = self.summary;
		dvui.label(@src(), "Load: {d:.2} {d:.2} {d:.2}  |  {d} procs ({d} run, {d} sleep, {d} thr)", .{
			s.load_avg_1, s.load_avg_5, s.load_avg_15,
			s.processes_total, s.processes_running, s.processes_sleeping, s.threads_total,
		}, .{ .font = dvui.themeGet().font_mono });
	}

	pub fn moduleDeinit(self: *CpuHogs) void {
		self.deinit();
	}
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "init creates valid struct" {
	var m = mock.MockStats{};
	const iface = m.interface();
	const hogs = CpuHogs.init(testing.allocator, iface, 10);

	try testing.expectEqual(@as(u16, 10), hogs.max_processes);
	try testing.expect(hogs.aggregated == null);
	try testing.expectEqual(@as(f64, 0), hogs.system_cpu_percent);
	try testing.expectEqual(@as(u16, 0), hogs.num_cores);
}

test "update populates aggregated data" {
	var m = mock.MockStats{};
	const iface = m.interface();
	var hogs = CpuHogs.init(testing.allocator, iface, 10);
	defer hogs.deinit();

	hogs.update();

	try testing.expect(hogs.aggregated != null);
	try testing.expect(hogs.aggregated.?.len > 0);
}

test "aggregated sorted by CPU descending" {
	var m = mock.MockStats{};
	const iface = m.interface();
	var hogs = CpuHogs.init(testing.allocator, iface, 10);
	defer hogs.deinit();

	hogs.update();

	const agg = hogs.aggregated.?;
	// Mock data: zig=95%, node=45%, firefox=30%, bash=0.5%
	// All have unique commands so no grouping — sorted by CPU descending
	try testing.expectEqualStrings("zig", agg[0].command);
	try testing.expectApproxEqAbs(@as(f64, 95.0), agg[0].total_cpu_percent, 0.001);
}

test "system CPU percent captured" {
	var m = mock.MockStats{};
	const iface = m.interface();
	var hogs = CpuHogs.init(testing.allocator, iface, 10);
	defer hogs.deinit();

	hogs.update();

	try testing.expectEqual(@as(f64, 42.5), hogs.system_cpu_percent);
}

test "num_cores captured" {
	var m = mock.MockStats{};
	const iface = m.interface();
	var hogs = CpuHogs.init(testing.allocator, iface, 10);
	defer hogs.deinit();

	hogs.update();

	try testing.expectEqual(@as(u16, 4), hogs.num_cores);
}

test "moduleInfo returns correct id" {
	var m = mock.MockStats{};
	const iface = m.interface();
	var hogs = CpuHogs.init(testing.allocator, iface, 10);

	const info = hogs.moduleInfo();
	try testing.expectEqualStrings("cpu_hogs", info.id);
	try testing.expectEqualStrings("CPU Hogs", info.display_name);
	try testing.expectEqual(@as(u8, 3), info.default_priority);
	try testing.expectEqual(@as(u16, 250), info.min_width);
	try testing.expectEqual(@as(u16, 200), info.min_height);
	try testing.expectEqual(@as(u16, 400), info.preferred_width);
	try testing.expectEqual(@as(u16, 350), info.preferred_height);
}

test "double update frees old data (no memory leak)" {
	var m = mock.MockStats{};
	const iface = m.interface();
	var hogs = CpuHogs.init(testing.allocator, iface, 10);
	defer hogs.deinit();

	// First update
	hogs.update();
	try testing.expect(hogs.aggregated != null);

	// Second update — should free old data, allocate new
	hogs.update();
	try testing.expect(hogs.aggregated != null);

	// testing.allocator will detect leaks if the first allocation wasn't freed
}

test "deinit frees cached data (no memory leak)" {
	var m = mock.MockStats{};
	const iface = m.interface();
	var hogs = CpuHogs.init(testing.allocator, iface, 10);

	hogs.update();
	try testing.expect(hogs.aggregated != null);

	hogs.deinit();
	try testing.expect(hogs.aggregated == null);

	// testing.allocator will detect leaks if deinit didn't free the allocation
}

test "Module vtable integration" {
	const dvui = @import("dvui");
	var m = mock.MockStats{};
	const iface = m.interface();
	var hogs = CpuHogs.init(testing.allocator, iface, 10);

	// Get a type-erased Module handle
	const mod = module.Module.from(&hogs);

	// info() dispatches correctly
	const info = mod.info();
	try testing.expectEqualStrings("cpu_hogs", info.id);

	// update() dispatches correctly
	mod.update();
	try testing.expect(hogs.aggregated != null);

	// render() needs DVUI context — test via frame
	const RenderTest = struct {
		var render_target: ?*CpuHogs = null;
		fn frame() !dvui.App.Result {
			if (render_target) |target| target.moduleRender();
			return .ok;
		}
	};
	RenderTest.render_target = &hogs;
	var t = try dvui.testing.init(.{});
	defer t.deinit();
	_ = try dvui.testing.step(RenderTest.frame);

	// deinit() dispatches correctly
	mod.deinit();
	try testing.expect(hogs.aggregated == null);
}
