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

	pub fn init(stats_iface: stats.SystemStats, hostnames: []const []const u8) PingMonitor {
		var self = PingMonitor{
			.stats_iface = stats_iface,
			.hosts = [_]?HostData{null} ** MAX_HOSTS,
			.host_count = @min(hostnames.len, MAX_HOSTS),
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
		for (self.hosts[0..self.host_count]) |*maybe_host| {
			if (maybe_host.*) |*host_data| {
				const result = self.stats_iface.ping(host_data.hostname);
				host_data.history.push(.{
					.latency_ms = result.latency_ms,
					.sample_index = host_data.sample_count,
				});
				host_data.sample_count += 1;
			}
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
		.default_priority = 4,
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

	pub fn moduleRender(_: *PingMonitor) void {
		// no-op for now
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
	try testing.expectEqual(@as(u8, 4), info.default_priority);
	try testing.expectEqual(@as(u16, 300), info.min_width);
	try testing.expectEqual(@as(u16, 200), info.min_height);
	try testing.expectEqual(@as(u16, 500), info.preferred_width);
	try testing.expectEqual(@as(u16, 300), info.preferred_height);
}

test "Module vtable dispatches correctly" {
	var mock = MockStats{};
	const iface = mock.interface();
	const hostnames: [1][]const u8 = .{"vtable.test"};
	var pm = PingMonitor.init(iface, &hostnames);
	const m = pm.module();

	// info() through vtable
	const info = m.info();
	try testing.expectEqualStrings("ping_monitor", info.id);

	// update() through vtable should add a sample
	m.update();
	const hd = pm.getHostData(0).?;
	try testing.expectEqual(@as(usize, 1), hd.history.len());

	// render() and deinit() should not panic
	m.render();
	m.deinit();
}
