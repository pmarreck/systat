const std = @import("std");
const stats = @import("stats.zig");

/// Mock implementation of SystemStats for testing.
/// Stores canned data that is returned verbatim through the vtable.
pub const MockStats = struct {
	processes: []const stats.ProcessInfo = &default_processes,
	cpu: stats.CpuSnapshot = default_cpu,
	mem: stats.MemSnapshot = default_mem,
	summary: stats.SystemSummary = default_summary,
	ping_latency_ms: ?f64 = 25.0,

	// ── Default canned data ──────────────────────────────────────────

	const default_processes: [4]stats.ProcessInfo = .{
		.{ .command = "node", .pid = 1001, .cpu_percent = 45.0, .rss_bytes = 500 * 1024 * 1024 },
		.{ .command = "firefox", .pid = 1002, .cpu_percent = 30.0, .rss_bytes = 1200 * 1024 * 1024 },
		.{ .command = "zig", .pid = 1003, .cpu_percent = 95.0, .rss_bytes = 200 * 1024 * 1024 },
		.{ .command = "bash", .pid = 1004, .cpu_percent = 0.5, .rss_bytes = 10 * 1024 * 1024 },
	};

	const default_per_core: [4]f64 = .{ 80.0, 50.0, 30.0, 10.0 };

	const default_cpu: stats.CpuSnapshot = .{
		.total_percent = 42.5,
		.per_core = &default_per_core,
		.user_percent = 30.0,
		.system_percent = 12.5,
		.idle_percent = 57.5,
		.num_cores = 4,
	};

	const default_mem: stats.MemSnapshot = .{
		.total_bytes = 16 * 1024 * 1024 * 1024, // 16 GB
		.used_bytes = 10 * 1024 * 1024 * 1024, // 10 GB
		.free_bytes = 6 * 1024 * 1024 * 1024, //  6 GB
	};

	const default_summary: stats.SystemSummary = .{
		.load_avg_1 = 3.50,
		.load_avg_5 = 4.20,
		.load_avg_15 = 5.10,
		.processes_total = 350,
		.processes_running = 3,
		.processes_sleeping = 347,
		.threads_total = 2500,
		.wired_bytes = 4 * 1024 * 1024 * 1024, // 4 GB
		.compressor_bytes = 2 * 1024 * 1024 * 1024, // 2 GB
		.swap_ins = 12000,
		.swap_outs = 8000,
		.net_packets_in = 100_000_000,
		.net_bytes_in = 50 * 1024 * 1024 * 1024, // 50 GB
		.net_packets_out = 80_000_000,
		.net_bytes_out = 20 * 1024 * 1024 * 1024, // 20 GB
		.disk_reads = 500_000_000,
		.disk_read_bytes = 2 * 1024 * 1024 * 1024 * 1024, // 2 TB
		.disk_writes = 200_000_000,
		.disk_write_bytes = 500 * 1024 * 1024 * 1024, // 500 GB
	};

	// ── Vtable thunks ────────────────────────────────────────────────

	const gen = struct {
		fn getProcessList(ctx: *anyopaque) []const stats.ProcessInfo {
			const self: *MockStats = @ptrCast(@alignCast(ctx));
			return self.processes;
		}

		fn getCpuSnapshot(ctx: *anyopaque) stats.CpuSnapshot {
			const self: *MockStats = @ptrCast(@alignCast(ctx));
			return self.cpu;
		}

		fn getMemSnapshot(ctx: *anyopaque) stats.MemSnapshot {
			const self: *MockStats = @ptrCast(@alignCast(ctx));
			return self.mem;
		}

		fn getSystemSummary(ctx: *anyopaque) stats.SystemSummary {
			const self: *MockStats = @ptrCast(@alignCast(ctx));
			return self.summary;
		}

		fn ping(ctx: *anyopaque, host: []const u8) stats.PingResult {
			const self: *MockStats = @ptrCast(@alignCast(ctx));
			return .{
				.host = host,
				.latency_ms = self.ping_latency_ms,
				.timestamp_ns = 1_000_000_000, // fixed for determinism
			};
		}
	};

	/// Return a `SystemStats` vtable backed by this mock instance.
	pub fn interface(self: *MockStats) stats.SystemStats {
		return .{
			.ctx = @ptrCast(self),
			.getProcessListFn = &gen.getProcessList,
			.getCpuSnapshotFn = &gen.getCpuSnapshot,
			.getMemSnapshotFn = &gen.getMemSnapshot,
			.getSystemSummaryFn = &gen.getSystemSummary,
			.pingFn = &gen.ping,
		};
	}
};

// ── Tests ────────────────────────────────────────────────────────────

test "getProcessList returns 4 processes, first is node" {
	var mock = MockStats{};
	const iface = mock.interface();
	const procs = iface.getProcessList();

	try std.testing.expectEqual(@as(usize, 4), procs.len);
	try std.testing.expectEqualStrings("node", procs[0].command);
}

test "getCpuSnapshot returns 42.5% total" {
	var mock = MockStats{};
	const iface = mock.interface();
	const cpu = iface.getCpuSnapshot();

	try std.testing.expectEqual(@as(f64, 42.5), cpu.total_percent);
}

test "getMemSnapshot returns used < total" {
	var mock = MockStats{};
	const iface = mock.interface();
	const mem = iface.getMemSnapshot();

	try std.testing.expect(mem.used_bytes < mem.total_bytes);
}

test "getSystemSummary returns mock data" {
	var mock = MockStats{};
	const iface = mock.interface();
	const summary = iface.getSystemSummary();

	try std.testing.expectApproxEqAbs(@as(f64, 3.50), summary.load_avg_1, 0.001);
	try std.testing.expectEqual(@as(u32, 350), summary.processes_total);
	try std.testing.expectEqual(@as(u64, 4 * 1024 * 1024 * 1024), summary.wired_bytes);
}

test "ping returns configured latency" {
	var mock = MockStats{ .ping_latency_ms = 42.0 };
	const iface = mock.interface();
	const result = iface.ping("example.com");

	try std.testing.expectEqual(@as(?f64, 42.0), result.latency_ms);
	try std.testing.expectEqualStrings("example.com", result.host);
}

test "ping with null latency (timeout)" {
	var mock = MockStats{ .ping_latency_ms = null };
	const iface = mock.interface();
	const result = iface.ping("unreachable.test");

	try std.testing.expectEqual(@as(?f64, null), result.latency_ms);
}
