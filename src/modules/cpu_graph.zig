const std = @import("std");
const stats = @import("../platform/stats.zig");
const mod = @import("../module.zig");
const RingBuffer = @import("../ring_buffer.zig").RingBuffer;

/// Number of samples retained — 5 minutes at 1 sample/second.
pub const HISTORY_SIZE = 300;

/// A single CPU usage sample stored in the ring buffer.
pub const CpuSample = struct {
	total_percent: f64,
	timestamp_ms: i64,
};

/// Data-processing backend for the CPU usage graph module.
/// Maintains a rolling window of CPU percentage samples suitable for
/// plotting a time-series line chart.
pub const CpuGraph = struct {
	stats_iface: stats.SystemStats,
	history: RingBuffer(CpuSample, HISTORY_SIZE),
	sample_count: u64,
	last_update_ns: i128 = 0,
	update_interval_ns: i128 = 1_000_000_000, // 1 second

	pub fn init(stats_iface: stats.SystemStats) CpuGraph {
		return .{
			.stats_iface = stats_iface,
			.history = RingBuffer(CpuSample, HISTORY_SIZE).init(),
			.sample_count = 0,
		};
	}

	/// Poll the stats interface and append a new sample (rate-limited to 1/sec).
	pub fn update(self: *CpuGraph) void {
		const now = std.time.nanoTimestamp();
		if (self.last_update_ns != 0 and now - self.last_update_ns < self.update_interval_ns) return;
		self.last_update_ns = now;

		const snap = self.stats_iface.getCpuSnapshot();
		self.history.push(.{
			.total_percent = snap.total_percent,
			.timestamp_ms = @intCast(self.sample_count),
		});
		self.sample_count += 1;
	}

	/// Number of data points currently stored (up to HISTORY_SIZE).
	pub fn dataPointCount(self: *const CpuGraph) usize {
		return self.history.len();
	}

	/// Get the data point at logical index (0 = oldest).
	pub fn getDataPoint(self: *const CpuGraph, index: usize) CpuSample {
		return self.history.get(index);
	}

	/// The most recent CPU percentage, or null when no samples exist.
	pub fn currentPercent(self: *const CpuGraph) ?f64 {
		if (self.history.len() == 0) return null;
		return self.history.get(self.history.len() - 1).total_percent;
	}

	/// Discard all samples and reset the counter.
	pub fn clear(self: *CpuGraph) void {
		self.history.clear();
		self.sample_count = 0;
	}

	// ── Module vtable methods ────────────────────────────────────────

	pub fn moduleInfo(_: *CpuGraph) mod.ModuleInfo {
		return .{
			.id = "cpu_graph",
			.display_name = "CPU Usage",
			.default_priority = 1,
			.min_width = 300,
			.min_height = 200,
			.preferred_width = 500,
			.preferred_height = 300,
		};
	}

	pub fn moduleUpdate(self: *CpuGraph) void {
		self.update();
	}

	pub fn moduleRender(self: *CpuGraph) void {
		const dvui = @import("dvui");

		const current = self.currentPercent() orelse 0;
		dvui.label(@src(), "CPU Usage \u{2014} {d:.1}%", .{current}, .{
			.font = dvui.themeGet().font_heading,
		});

		if (self.dataPointCount() == 0) {
			dvui.label(@src(), "No data yet", .{}, .{});
			return;
		}

		const Static = struct {
			var y_axis: dvui.PlotWidget.Axis = .{
				.name = "CPU %",
				.min = 0,
				.max = 100,
			};
			var x_axis: dvui.PlotWidget.Axis = .{
				.name = "Seconds Ago",
			};
		};

		// Fixed sliding window: always show last HISTORY_SIZE seconds
		Static.x_axis.min = -@as(f32, @floatFromInt(HISTORY_SIZE));
		Static.x_axis.max = 0;

		var plot = dvui.plot(@src(), .{
			.x_axis = &Static.x_axis,
			.y_axis = &Static.y_axis,
		}, .{ .expand = .both, .min_size_content = .{ .h = 100 } });
		defer plot.deinit();

		var line = plot.line();
		defer line.deinit();

		// Plot as "seconds ago": newest sample = 0, older = negative
		const now: i64 = if (self.sample_count > 0) @intCast(self.sample_count - 1) else 0;
		for (0..self.dataPointCount()) |i| {
			const sample = self.getDataPoint(i);
			const seconds_ago: f64 = @floatFromInt(sample.timestamp_ms - now);
			line.point(seconds_ago, sample.total_percent);
		}
		line.stroke(1.5, dvui.themeGet().focus);
	}

	pub fn moduleDeinit(_: *CpuGraph) void {
		// Ring buffer is inline; nothing to free.
	}

	/// Return a type-erased `Module` handle for this instance.
	pub fn module(self: *CpuGraph) mod.Module {
		return mod.Module.from(self);
	}
};

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;
const MockStats = @import("../platform/mock.zig").MockStats;

test "init creates empty history" {
	var mock = MockStats{};
	const graph = CpuGraph.init(mock.interface());
	try testing.expectEqual(@as(usize, 0), graph.dataPointCount());
	try testing.expectEqual(@as(?f64, null), graph.currentPercent());
}

test "update adds data points" {
	var mock = MockStats{};
	var graph = CpuGraph.init(mock.interface());
	graph.update_interval_ns = 0; // disable rate limiting for tests

	graph.update();
	graph.update();
	graph.update();

	try testing.expectEqual(@as(usize, 3), graph.dataPointCount());
}

test "data points have correct values" {
	var mock = MockStats{};
	var graph = CpuGraph.init(mock.interface());
	graph.update_interval_ns = 0;

	graph.update();

	const sample = graph.getDataPoint(0);
	try testing.expectEqual(@as(f64, 42.5), sample.total_percent);
}

test "currentPercent returns latest" {
	var mock = MockStats{};
	var graph = CpuGraph.init(mock.interface());
	graph.update_interval_ns = 0;

	// Update three times with the default mock (42.5%)
	graph.update();
	graph.update();
	graph.update();

	try testing.expectEqual(@as(?f64, 42.5), graph.currentPercent());

	// Change the mock's CPU value and update again
	const new_per_core = [_]f64{ 90.0, 85.0, 80.0, 75.0 };
	mock.cpu = .{
		.total_percent = 82.5,
		.per_core = &new_per_core,
		.user_percent = 60.0,
		.system_percent = 22.5,
		.idle_percent = 17.5,
		.num_cores = 4,
	};
	graph.update();

	try testing.expectEqual(@as(?f64, 82.5), graph.currentPercent());
}

test "ring buffer wraps at HISTORY_SIZE" {
	var mock = MockStats{};
	var graph = CpuGraph.init(mock.interface());
	graph.update_interval_ns = 0;

	const overflow = HISTORY_SIZE + 10;
	for (0..overflow) |_| {
		graph.update();
	}

	// Count must never exceed capacity
	try testing.expectEqual(@as(usize, HISTORY_SIZE), graph.dataPointCount());

	// sample_count tracks total updates regardless of wrapping
	try testing.expectEqual(@as(u64, overflow), graph.sample_count);

	// Oldest retained sample should have timestamp_ms == 10
	// (the first 10 samples were evicted)
	const oldest = graph.getDataPoint(0);
	try testing.expectEqual(@as(i64, 10), oldest.timestamp_ms);
}

test "clear resets everything" {
	var mock = MockStats{};
	var graph = CpuGraph.init(mock.interface());
	graph.update_interval_ns = 0;

	graph.update();
	graph.update();
	graph.update();
	try testing.expectEqual(@as(usize, 3), graph.dataPointCount());

	graph.clear();
	try testing.expectEqual(@as(usize, 0), graph.dataPointCount());
	try testing.expectEqual(@as(?f64, null), graph.currentPercent());
	try testing.expectEqual(@as(u64, 0), graph.sample_count);
}

test "moduleInfo returns correct id and priority" {
	var mock = MockStats{};
	var graph = CpuGraph.init(mock.interface());
	const info = graph.moduleInfo();

	try testing.expectEqualStrings("cpu_graph", info.id);
	try testing.expectEqualStrings("CPU Usage", info.display_name);
	try testing.expectEqual(@as(u8, 1), info.default_priority);
	try testing.expectEqual(@as(u16, 300), info.min_width);
	try testing.expectEqual(@as(u16, 200), info.min_height);
	try testing.expectEqual(@as(u16, 500), info.preferred_width);
	try testing.expectEqual(@as(u16, 300), info.preferred_height);
}

test "timestamps increment monotonically" {
	var mock = MockStats{};
	var graph = CpuGraph.init(mock.interface());
	graph.update_interval_ns = 0;

	graph.update();
	graph.update();
	graph.update();
	graph.update();
	graph.update();

	for (0..graph.dataPointCount()) |i| {
		const sample = graph.getDataPoint(i);
		try testing.expectEqual(@as(i64, @intCast(i)), sample.timestamp_ms);
	}
}

test "Module vtable dispatches correctly" {
	const dvui = @import("dvui");
	var mock = MockStats{};
	var graph = CpuGraph.init(mock.interface());
	graph.update_interval_ns = 0;
	const m = graph.module();

	// info() dispatches through the vtable
	const info = m.info();
	try testing.expectEqualStrings("cpu_graph", info.id);

	// update() dispatches through the vtable and adds a data point
	try testing.expectEqual(@as(usize, 0), graph.dataPointCount());
	m.update();
	try testing.expectEqual(@as(usize, 1), graph.dataPointCount());

	// render() needs DVUI context — test via frame
	const RenderTest = struct {
		var render_target: ?*CpuGraph = null;
		fn frame() !dvui.App.Result {
			if (render_target) |target| target.moduleRender();
			return .ok;
		}
	};
	RenderTest.render_target = &graph;
	var t = try dvui.testing.init(.{});
	defer t.deinit();
	_ = try dvui.testing.step(RenderTest.frame);

	// deinit() should not panic
	m.deinit();
}
