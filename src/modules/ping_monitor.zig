const std = @import("std");
const stats = @import("../platform/stats.zig");
const RingBuffer = @import("../ring_buffer.zig").RingBuffer;
const mod = @import("../module.zig");
const ModuleInfo = mod.ModuleInfo;
const Module = mod.Module;

pub const HISTORY_SIZE = 150; // 5 minutes at 1 ping per 2 seconds
pub const MAX_HOSTS = 8;

pub const LatencySample = struct {
	latency_ms: ?f64, // null = timeout
	sample_index: u64,
};

pub const HostData = struct {
	hostname: []const u8,
	history: RingBuffer(LatencySample, HISTORY_SIZE),
	sample_count: u64,
};

pub const PingMonitor = struct {
	stats_iface: stats.SystemStats,
	hosts: [MAX_HOSTS]?HostData,
	host_count: usize,
	ping_interval_ns: i128,
	last_ping_ns: i128 = 0,
	next_host_idx: usize = 0, // round-robin index for one-host-per-tick

	pub fn init(stats_iface: stats.SystemStats, hostnames: []const []const u8) PingMonitor {
		return initWithInterval(stats_iface, hostnames, 2000);
	}

	pub fn initWithInterval(stats_iface: stats.SystemStats, hostnames: []const []const u8, interval_ms: u32) PingMonitor {
		const count = @min(hostnames.len, MAX_HOSTS);
		// Per-host tick rate: total interval / host count, so each host
		// gets pinged once per configured interval without blocking on
		// all hosts at once.
		const tick_ns: i128 = if (count > 0)
			@divTrunc(@as(i128, interval_ms) * 1_000_000, @as(i128, @intCast(count)))
		else
			@as(i128, interval_ms) * 1_000_000;

		var self = PingMonitor{
			.stats_iface = stats_iface,
			.hosts = [_]?HostData{null} ** MAX_HOSTS,
			.host_count = count,
			.ping_interval_ns = tick_ns,
		};
		for (hostnames[0..self.host_count], 0..) |hostname, i| {
			self.hosts[i] = .{
				.hostname = hostname,
				.history = RingBuffer(LatencySample, HISTORY_SIZE).init(),
				.sample_count = 0,
			};
		}
		return self;
	}

	pub fn update(self: *PingMonitor) void {
		if (self.host_count == 0) return;

		// Rate-limit: one host per tick (round-robin)
		const now = std.time.nanoTimestamp();
		if (self.last_ping_ns != 0 and now - self.last_ping_ns < self.ping_interval_ns) return;
		self.last_ping_ns = now;

		// Ping just the next host in rotation
		const idx = self.next_host_idx;
		self.next_host_idx = (idx + 1) % self.host_count;

		if (self.hosts[idx]) |*host_data| {
			const result = self.stats_iface.ping(host_data.hostname);
			host_data.history.push(.{
				.latency_ms = result.latency_ms,
				.sample_index = host_data.sample_count,
			});
			host_data.sample_count += 1;
		}
	}

	pub fn getHostData(self: *const PingMonitor, index: usize) ?HostData {
		if (index >= self.host_count) return null;
		return self.hosts[index];
	}

	// -- Module vtable methods --

	const ping_module_info: ModuleInfo = .{
		.id = "ping_monitor",
		.display_name = "Ping Monitor",
		.default_priority = 2,
		.min_width = 300,
		.min_height = 200,
		.preferred_width = 500,
		.preferred_height = 300,
	};

	pub fn moduleInfo(_: *PingMonitor) ModuleInfo {
		return ping_module_info;
	}

	pub fn moduleUpdate(self: *PingMonitor) void {
		self.update();
	}

	pub fn moduleRender(self: *PingMonitor) void {
		const dvui = @import("dvui");

		dvui.label(@src(), "Web Ping \u{2014} {d} hosts", .{self.host_count}, .{
			.font = dvui.themeGet().font_heading,
		});

		if (self.host_count == 0) {
			dvui.label(@src(), "No hosts configured", .{}, .{});
			return;
		}

		const Static = struct {
			var y_axis: dvui.PlotWidget.Axis = .{
				.name = "ms",
				.min = 0,
				.max = 200,
			};
			var x_axis: dvui.PlotWidget.Axis = .{
				.name = "Seconds Ago",
			};
		};

		// Auto-scale Y axis: scan all data for peak, minimum 200ms
		var max_latency: f64 = 200.0;
		for (0..self.host_count) |hi| {
			if (self.hosts[hi]) |host_data| {
				for (0..host_data.history.len()) |i| {
					if (host_data.history.get(i).latency_ms) |ms| {
						if (ms > max_latency) max_latency = ms;
					}
				}
			}
		}
		Static.y_axis.max = @floatCast(max_latency * 1.1); // 10% headroom

		// Fixed sliding window: total seconds = HISTORY_SIZE * per-host interval
		// ping_interval_ns is per-tick (divided by host_count), so multiply back
		const per_host_ns: f64 = @floatFromInt(self.ping_interval_ns * @as(i128, @intCast(if (self.host_count > 0) self.host_count else 1)));
		const interval_sec: f32 = @floatCast(per_host_ns / 1_000_000_000.0);
		const window_sec: f32 = @as(f32, @floatFromInt(HISTORY_SIZE)) * interval_sec;
		Static.x_axis.min = -window_sec;
		Static.x_axis.max = 0;

		var plot = dvui.plot(@src(), .{
			.x_axis = &Static.x_axis,
			.y_axis = &Static.y_axis,
		}, .{ .expand = .both, .min_size_content = .{ .h = 100 } });
		defer plot.deinit();

		// Per-host line colors cycle through theme accents
		const line_colors = [_]dvui.Color{
			dvui.themeGet().focus,
			if (dvui.themeGet().highlight.fill) |c| c else dvui.Color.cyan,
			if (dvui.themeGet().app1.fill) |c| c else dvui.Color.lime,
			if (dvui.themeGet().app2.fill) |c| c else dvui.Color.yellow,
			dvui.Color.fuchsia,
			dvui.Color.aqua,
			dvui.Color.red,
			dvui.Color.silver,
		};

		for (0..self.host_count) |host_idx| {
			if (self.hosts[host_idx]) |host_data| {
				if (host_data.history.len() == 0) continue;

				var line = plot.line();
				defer line.deinit();

				// Plot as "seconds ago": newest sample = 0, older = negative
				const now_idx: i64 = if (host_data.sample_count > 0) @intCast(host_data.sample_count - 1) else 0;
				for (0..host_data.history.len()) |i| {
					const sample = host_data.history.get(i);
					if (sample.latency_ms) |latency| {
						const samples_ago: f64 = @floatFromInt(@as(i64, @intCast(sample.sample_index)) - now_idx);
						const seconds_ago: f64 = samples_ago * @as(f64, @floatCast(interval_sec));
						line.point(seconds_ago, latency);
					}
				}
				line.stroke(1.5, line_colors[host_idx % line_colors.len]);
			}
		}

		// Legend: colored dots with hostnames
		{
			var legend_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
				.padding = dvui.Rect.all(2),
			});
			defer legend_row.deinit();

			for (0..self.host_count) |host_idx| {
				if (self.hosts[host_idx]) |host_data| {
					const color = line_colors[host_idx % line_colors.len];
					// Latest latency for this host
					const latest_ms: ?f64 = if (host_data.history.len() > 0)
						host_data.history.get(host_data.history.len() - 1).latency_ms
					else
						null;

					if (latest_ms) |ms| {
						dvui.label(@src(), "\u{25CF} {s}: {d:.0}ms", .{ host_data.hostname, ms }, .{
							.font = dvui.themeGet().font_mono,
							.color_text = color,
							.id_extra = @intCast(host_idx),
						});
					} else {
						dvui.label(@src(), "\u{25CF} {s}: --", .{host_data.hostname}, .{
							.font = dvui.themeGet().font_mono,
							.color_text = color,
							.id_extra = @intCast(host_idx),
						});
					}
				}
			}
		}
	}

	pub fn moduleDeinit(_: *PingMonitor) void {
		// nothing to free -- ring buffers are inline
	}

	/// Convenience: obtain a type-erased Module handle.
	pub fn module(self: *PingMonitor) Module {
		return Module.from(self);
	}
};

// ========================= Tests =========================

const testing = std.testing;
const MockStats = @import("../platform/mock.zig").MockStats;

test "init with hosts" {
	var mock = MockStats{};
	const iface = mock.interface();
	const hostnames: [2][]const u8 = .{ "google.com", "github.com" };
	const pm = PingMonitor.init(iface, &hostnames);

	try testing.expectEqual(@as(usize, 2), pm.host_count);
	try testing.expect(pm.hosts[0] != null);
	try testing.expect(pm.hosts[1] != null);
	try testing.expect(pm.hosts[2] == null);
	try testing.expectEqualStrings("google.com", pm.hosts[0].?.hostname);
	try testing.expectEqualStrings("github.com", pm.hosts[1].?.hostname);
}

test "init caps at MAX_HOSTS" {
	var mock = MockStats{};
	const iface = mock.interface();
	const hostnames: [10][]const u8 = .{
		"h0", "h1", "h2", "h3", "h4", "h5", "h6", "h7", "h8", "h9",
	};
	const pm = PingMonitor.init(iface, &hostnames);

	try testing.expectEqual(@as(usize, MAX_HOSTS), pm.host_count);
}

test "update pings all hosts" {
	var mock = MockStats{};
	const iface = mock.interface();
	const hostnames: [2][]const u8 = .{ "google.com", "github.com" };
	var pm = PingMonitor.init(iface, &hostnames);
	pm.ping_interval_ns = 0; // disable rate limiting for tests

	// Round-robin: one host per update() call, so need 2 calls for 2 hosts
	pm.update();
	pm.update();

	// Each host should now have exactly 1 data point
	const h0 = pm.getHostData(0).?;
	const h1 = pm.getHostData(1).?;
	try testing.expectEqual(@as(usize, 1), h0.history.len());
	try testing.expectEqual(@as(usize, 1), h1.history.len());
}

test "latency recorded correctly" {
	var mock = MockStats{}; // default ping_latency_ms = 25.0
	const iface = mock.interface();
	const hostnames: [1][]const u8 = .{"example.com"};
	var pm = PingMonitor.init(iface, &hostnames);

	pm.update();

	const hd = pm.getHostData(0).?;
	const sample = hd.history.get(0);
	try testing.expectEqual(@as(?f64, 25.0), sample.latency_ms);
	try testing.expectEqual(@as(u64, 0), sample.sample_index);
}

test "timeout recorded as null" {
	var mock = MockStats{ .ping_latency_ms = null };
	const iface = mock.interface();
	const hostnames: [1][]const u8 = .{"unreachable.test"};
	var pm = PingMonitor.init(iface, &hostnames);

	pm.update();

	const hd = pm.getHostData(0).?;
	const sample = hd.history.get(0);
	try testing.expectEqual(@as(?f64, null), sample.latency_ms);
}

test "per-host history independent" {
	var mock = MockStats{};
	const iface = mock.interface();
	const hostnames: [2][]const u8 = .{ "a.com", "b.com" };
	var pm = PingMonitor.init(iface, &hostnames);
	pm.ping_interval_ns = 0; // disable rate limiting for tests

	// Round-robin: 2 hosts, so 6 update() calls = 3 pings per host
	pm.update();
	pm.update();
	pm.update();
	pm.update();
	pm.update();
	pm.update();

	const h0 = pm.getHostData(0).?;
	const h1 = pm.getHostData(1).?;
	try testing.expectEqual(@as(usize, 3), h0.history.len());
	try testing.expectEqual(@as(usize, 3), h1.history.len());
	try testing.expectEqual(@as(u64, 3), h0.sample_count);
	try testing.expectEqual(@as(u64, 3), h1.sample_count);

	// Verify sample indices are independent and sequential
	try testing.expectEqual(@as(u64, 0), h0.history.get(0).sample_index);
	try testing.expectEqual(@as(u64, 1), h0.history.get(1).sample_index);
	try testing.expectEqual(@as(u64, 2), h0.history.get(2).sample_index);
}

test "getHostData valid index" {
	var mock = MockStats{};
	const iface = mock.interface();
	const hostnames: [2][]const u8 = .{ "a.com", "b.com" };
	const pm = PingMonitor.init(iface, &hostnames);

	const hd = pm.getHostData(0);
	try testing.expect(hd != null);
	try testing.expectEqualStrings("a.com", hd.?.hostname);
}

test "getHostData invalid index" {
	var mock = MockStats{};
	const iface = mock.interface();
	const hostnames: [2][]const u8 = .{ "a.com", "b.com" };
	const pm = PingMonitor.init(iface, &hostnames);

	try testing.expect(pm.getHostData(2) == null);
	try testing.expect(pm.getHostData(100) == null);
}

test "moduleInfo returns correct id" {
	var mock = MockStats{};
	const iface = mock.interface();
	const hostnames: [1][]const u8 = .{"test.com"};
	var pm = PingMonitor.init(iface, &hostnames);

	const info = pm.moduleInfo();
	try testing.expectEqualStrings("ping_monitor", info.id);
	try testing.expectEqualStrings("Ping Monitor", info.display_name);
	try testing.expectEqual(@as(u8, 2), info.default_priority);
	try testing.expectEqual(@as(u16, 300), info.min_width);
	try testing.expectEqual(@as(u16, 200), info.min_height);
	try testing.expectEqual(@as(u16, 500), info.preferred_width);
	try testing.expectEqual(@as(u16, 300), info.preferred_height);
}

test "Module vtable dispatches correctly" {
	const dvui = @import("dvui");
	var mock = MockStats{};
	const iface = mock.interface();
	const hostnames: [1][]const u8 = .{"vtable.test"};
	var pm = PingMonitor.init(iface, &hostnames);
	pm.ping_interval_ns = 0; // disable rate limiting for tests
	const m = pm.module();

	// info() through vtable
	const info = m.info();
	try testing.expectEqualStrings("ping_monitor", info.id);

	// update() through vtable should add a sample
	m.update();
	const hd = pm.getHostData(0).?;
	try testing.expectEqual(@as(usize, 1), hd.history.len());

	// render() needs DVUI context — test via frame
	const RenderTest = struct {
		var render_target: ?*PingMonitor = null;
		fn frame() !dvui.App.Result {
			if (render_target) |target| target.moduleRender();
			return .ok;
		}
	};
	RenderTest.render_target = &pm;
	var t = try dvui.testing.init(.{});
	defer t.deinit();
	_ = try dvui.testing.step(RenderTest.frame);

	// deinit() should not panic
	m.deinit();
}
