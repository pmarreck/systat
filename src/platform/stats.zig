const std = @import("std");

/// Information about a single running process.
pub const ProcessInfo = struct {
	command: []const u8,
	pid: u32,
	cpu_percent: f64,
	rss_bytes: u64,
};

/// A snapshot of CPU utilization at a point in time.
pub const CpuSnapshot = struct {
	total_percent: f64,
	per_core: []const f64,
	user_percent: f64,
	system_percent: f64,
	idle_percent: f64,
	num_cores: u16,
};

/// A snapshot of memory utilization at a point in time.
pub const MemSnapshot = struct {
	total_bytes: u64,
	used_bytes: u64,
	free_bytes: u64,
};

/// System-wide summary: load averages, process counts, VM/swap stats, network/disk I/O.
pub const SystemSummary = struct {
	// Load averages (1, 5, 15 min)
	load_avg_1: f64 = 0,
	load_avg_5: f64 = 0,
	load_avg_15: f64 = 0,

	// Process counts
	processes_total: u32 = 0,
	processes_running: u32 = 0,
	processes_sleeping: u32 = 0,
	threads_total: u32 = 0,

	// Memory breakdown
	wired_bytes: u64 = 0,
	compressor_bytes: u64 = 0,

	// VM / swap
	swap_ins: u64 = 0,
	swap_outs: u64 = 0,

	// Network I/O (cumulative)
	net_packets_in: u64 = 0,
	net_bytes_in: u64 = 0,
	net_packets_out: u64 = 0,
	net_bytes_out: u64 = 0,

	// Disk I/O (cumulative)
	disk_reads: u64 = 0,
	disk_read_bytes: u64 = 0,
	disk_writes: u64 = 0,
	disk_write_bytes: u64 = 0,
};

/// Result of a single ping to a host.
pub const PingResult = struct {
	host: []const u8,
	/// Latency in milliseconds, or null if the ping timed out / failed.
	latency_ms: ?f64,
	timestamp_ns: i128,
};

/// Vtable interface for obtaining system statistics.
/// Implementations provide the function pointers; callers use the convenience methods.
pub const SystemStats = struct {
	ctx: *anyopaque,
	getProcessListFn: *const fn (ctx: *anyopaque) []const ProcessInfo,
	getCpuSnapshotFn: *const fn (ctx: *anyopaque) CpuSnapshot,
	getMemSnapshotFn: *const fn (ctx: *anyopaque) MemSnapshot,
	getSystemSummaryFn: *const fn (ctx: *anyopaque) SystemSummary,
	pingFn: *const fn (ctx: *anyopaque, host: []const u8) PingResult,

	/// Return the current list of running processes.
	pub fn getProcessList(self: SystemStats) []const ProcessInfo {
		return self.getProcessListFn(self.ctx);
	}

	/// Return a snapshot of CPU utilization.
	pub fn getCpuSnapshot(self: SystemStats) CpuSnapshot {
		return self.getCpuSnapshotFn(self.ctx);
	}

	/// Return a snapshot of memory utilization.
	pub fn getMemSnapshot(self: SystemStats) MemSnapshot {
		return self.getMemSnapshotFn(self.ctx);
	}

	/// Return a system-wide summary (load avg, process counts, VM, I/O).
	pub fn getSystemSummary(self: SystemStats) SystemSummary {
		return self.getSystemSummaryFn(self.ctx);
	}

	/// Ping a host and return the result.
	pub fn ping(self: SystemStats, host: []const u8) PingResult {
		return self.pingFn(self.ctx, host);
	}
};

test "SystemStats struct layout" {
	// Verify the vtable struct has the expected fields.
	const info = @typeInfo(SystemStats);
	const fields = info.@"struct".fields;
	try std.testing.expectEqual(@as(usize, 6), fields.len);
}
