//! macOS (Darwin) platform backend for SystemStats.
//! Collects real system data via shell commands, caching results
//! with a configurable refresh interval.

const std = @import("std");
const stats = @import("stats.zig");
const runtime = @import("../runtime.zig");

/// Read a monotonic clock as i128 nanoseconds.
fn monotonicNs(io: std.Io) i128 {
	const ts = std.Io.Timestamp.now(io, .awake);
	return @intCast(ts.toNanoseconds());
}

pub const DarwinBackend = struct {
	allocator: std.mem.Allocator,
	arena: std.heap.ArenaAllocator,

	// Cached data
	cached_processes: []stats.ProcessInfo = &.{},
	cached_cpu: stats.CpuSnapshot = default_cpu,
	cached_mem: stats.MemSnapshot = .{ .total_bytes = 0, .used_bytes = 0, .free_bytes = 0 },
	cached_summary: stats.SystemSummary = .{},

	// Static system info (fetched once)
	num_cores: u16 = 0,
	total_mem_bytes: u64 = 0,

	// Refresh timing
	last_refresh_ns: i128 = 0,
	refresh_interval_ns: i128 = 1_000_000_000, // 1 second

	const default_per_core: [0]f64 = .{};

	const default_cpu: stats.CpuSnapshot = .{
		.total_percent = 0,
		.per_core = &default_per_core,
		.user_percent = 0,
		.system_percent = 0,
		.idle_percent = 100,
		.num_cores = 0,
	};

	pub fn init(allocator: std.mem.Allocator) DarwinBackend {
		var self = DarwinBackend{
			.allocator = allocator,
			.arena = std.heap.ArenaAllocator.init(allocator),
		};

		// Fetch static system info once
		self.num_cores = self.fetchNumCores();
		self.total_mem_bytes = self.fetchTotalMem();

		return self;
	}

	pub fn deinit(self: *DarwinBackend) void {
		self.arena.deinit();
	}

	pub fn interface(self: *DarwinBackend) stats.SystemStats {
		return .{
			.ctx = @ptrCast(self),
			.getProcessListFn = &gen.getProcessList,
			.getCpuSnapshotFn = &gen.getCpuSnapshot,
			.getMemSnapshotFn = &gen.getMemSnapshot,
			.getSystemSummaryFn = &gen.getSystemSummary,
			.pingFn = &gen.ping,
		};
	}

	// ── Refresh logic ────────────────────────────────────────────────

	fn refreshIfNeeded(self: *DarwinBackend) void {
		const io = runtime.io();
		const now = monotonicNs(io);
		if (now - self.last_refresh_ns < self.refresh_interval_ns) return;

		// Invalidate cached pointers before resetting arena memory.
		self.cached_processes = &.{};
		_ = self.arena.reset(.retain_capacity);

		self.refreshProcesses();
		self.refreshCpuAndMem();

		// Set timestamp AFTER commands complete, not before.
		// If ps+top take >1s, using the pre-command timestamp would cause
		// the next vtable call (e.g. getCpuSnapshot) to re-trigger refresh,
		// resetting the arena and invalidating data just returned by getProcessList.
		self.last_refresh_ns = monotonicNs(io);
	}

	// ── Process list via ps ──────────────────────────────────────────

	fn refreshProcesses(self: *DarwinBackend) void {
		const arena_alloc = self.arena.allocator();

		const result = std.process.run(arena_alloc, runtime.io(), .{
			.argv = &.{ "/bin/ps", "-eo", "pid,pcpu,rss,comm" },
			.stdout_limit = .limited(1024 * 1024),
			.stderr_limit = .limited(1024 * 1024),
		}) catch return;

		// Parse output into ProcessInfo array
		var list: std.ArrayList(stats.ProcessInfo) = .empty;
		var lines = std.mem.splitScalar(u8, result.stdout, '\n');

		// Skip header line
		_ = lines.next();

		while (lines.next()) |line| {
			if (line.len == 0) continue;
			if (parsePsLine(arena_alloc, line)) |proc| {
				list.append(arena_alloc, proc) catch continue;
			}
		}

		self.cached_processes = list.toOwnedSlice(arena_alloc) catch &.{};
	}

	fn parsePsLine(arena_alloc: std.mem.Allocator, line: []const u8) ?stats.ProcessInfo {
		var rest = std.mem.trim(u8, line, " ");

		// Parse PID
		const pid_end = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
		const pid = std.fmt.parseInt(u32, rest[0..pid_end], 10) catch return null;
		rest = std.mem.trimStart(u8, rest[pid_end..], " ");

		// Parse CPU%
		const cpu_end = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
		const cpu_percent = std.fmt.parseFloat(f64, rest[0..cpu_end]) catch return null;
		rest = std.mem.trimStart(u8, rest[cpu_end..], " ");

		// Parse RSS (in KB on macOS)
		const rss_end = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
		const rss_kb = std.fmt.parseInt(u64, rest[0..rss_end], 10) catch return null;
		rest = std.mem.trimStart(u8, rest[rss_end..], " ");

		// Remainder is command path — extract basename
		const command_path = rest;
		const basename = extractBasename(command_path);
		const command = arena_alloc.dupe(u8, basename) catch return null;

		return .{
			.command = command,
			.pid = pid,
			.cpu_percent = cpu_percent,
			.rss_bytes = rss_kb * 1024,
		};
	}

	fn extractBasename(path: []const u8) []const u8 {
		// Find last '/' to get basename
		if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| {
			const base = path[pos + 1 ..];
			if (base.len > 0) return base;
		}
		return path;
	}

	// ── CPU + Memory via top ─────────────────────────────────────────

	fn refreshCpuAndMem(self: *DarwinBackend) void {
		const arena_alloc = self.arena.allocator();

		const result = std.process.run(arena_alloc, runtime.io(), .{
			.argv = &.{ "/usr/bin/top", "-l", "1", "-n", "0", "-s", "0" },
			.stdout_limit = .limited(16 * 1024),
			.stderr_limit = .limited(16 * 1024),
		}) catch return;

		var summary = self.cached_summary;
		var lines = std.mem.splitScalar(u8, result.stdout, '\n');
		while (lines.next()) |line| {
			if (std.mem.startsWith(u8, line, "CPU usage:")) {
				self.parseCpuLine(line);
			} else if (std.mem.startsWith(u8, line, "PhysMem:")) {
				self.parseMemLine(line);
				parsePhysMemDetail(line, &summary);
			} else if (std.mem.startsWith(u8, line, "Processes:")) {
				parseProcessesLine(line, &summary);
			} else if (std.mem.startsWith(u8, line, "Load Avg:")) {
				parseLoadAvgLine(line, &summary);
			} else if (std.mem.startsWith(u8, line, "VM:")) {
				parseVmLine(line, &summary);
			} else if (std.mem.startsWith(u8, line, "Networks:")) {
				parseNetworksLine(line, &summary);
			} else if (std.mem.startsWith(u8, line, "Disks:")) {
				parseDisksLine(line, &summary);
			}
		}
		self.cached_summary = summary;
	}

	fn parseCpuLine(self: *DarwinBackend, line: []const u8) void {
		// Format: "CPU usage: 5.55% user, 3.33% sys, 91.12% idle"
		const user = parsePercentBefore(line, "% user") orelse return;
		const sys = parsePercentBefore(line, "% sys") orelse return;
		const idle = parsePercentBefore(line, "% idle") orelse return;

		self.cached_cpu = .{
			.total_percent = user + sys,
			.per_core = &default_per_core,
			.user_percent = user,
			.system_percent = sys,
			.idle_percent = idle,
			.num_cores = self.num_cores,
		};
	}

	fn parseMemLine(self: *DarwinBackend, line: []const u8) void {
		// Format: "PhysMem: 28G used (2G wired), 4G unused."
		// or: "PhysMem: 25600M used (2048M wired), 6400M unused."
		const used = parseMemValue(line, " used") orelse return;
		const unused = parseMemValue(line, " unused") orelse return;

		self.cached_mem = .{
			.total_bytes = self.total_mem_bytes,
			.used_bytes = used,
			.free_bytes = unused,
		};
	}

	/// Parse a float value immediately before a suffix like "% user".
	fn parsePercentBefore(line: []const u8, suffix: []const u8) ?f64 {
		const pos = std.mem.indexOf(u8, line, suffix) orelse return null;
		// Walk backward from pos to find start of number
		var start: usize = pos;
		while (start > 0) {
			const c = line[start - 1];
			if (c == '.' or (c >= '0' and c <= '9')) {
				start -= 1;
			} else break;
		}
		if (start == pos) return null;
		return std.fmt.parseFloat(f64, line[start..pos]) catch null;
	}

	/// Parse a memory value like "28G" or "25600M" before a suffix like " used".
	fn parseMemValue(line: []const u8, suffix: []const u8) ?u64 {
		const pos = std.mem.indexOf(u8, line, suffix) orelse return null;
		// Walk backward to find the number+unit
		const end = pos;
		if (end == 0) return null;

		// The character immediately before suffix should be the unit (G, M, K)
		const unit_char = line[end - 1];
		var multiplier: u64 = 1;
		var num_end = end;
		if (unit_char == 'G') {
			multiplier = 1024 * 1024 * 1024;
			num_end = end - 1;
		} else if (unit_char == 'M') {
			multiplier = 1024 * 1024;
			num_end = end - 1;
		} else if (unit_char == 'K') {
			multiplier = 1024;
			num_end = end - 1;
		} else if (unit_char >= '0' and unit_char <= '9') {
			// Plain bytes, no unit
			num_end = end;
		} else return null;

		// Walk backward to find start of number
		var start: usize = num_end;
		while (start > 0) {
			const c = line[start - 1];
			if ((c >= '0' and c <= '9') or c == '.') {
				start -= 1;
			} else break;
		}
		if (start == num_end) return null;

		// Parse as float to handle "1.5G" etc, then multiply
		const val = std.fmt.parseFloat(f64, line[start..num_end]) catch return null;
		return @intFromFloat(val * @as(f64, @floatFromInt(multiplier)));
	}

	// ── System summary parsers ──────────────────────────────────────

	/// Parse "Processes: 1162 total, 2 running, 1160 sleeping, 6370 threads"
	fn parseProcessesLine(line: []const u8, summary: *stats.SystemSummary) void {
		if (parseIntBefore(line, " total")) |v| summary.processes_total = @intCast(v);
		if (parseIntBefore(line, " running")) |v| summary.processes_running = @intCast(v);
		if (parseIntBefore(line, " sleeping")) |v| summary.processes_sleeping = @intCast(v);
		if (parseIntBefore(line, " threads")) |v| summary.threads_total = @intCast(v);
	}

	/// Parse "Load Avg: 4.95, 5.18, 6.07"
	fn parseLoadAvgLine(line: []const u8, summary: *stats.SystemSummary) void {
		const prefix = "Load Avg: ";
		if (!std.mem.startsWith(u8, line, prefix)) return;
		const rest = line[prefix.len..];
		var iter = std.mem.splitSequence(u8, rest, ", ");
		if (iter.next()) |s| summary.load_avg_1 = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t")) catch 0;
		if (iter.next()) |s| summary.load_avg_5 = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t")) catch 0;
		if (iter.next()) |s| {
			// May have trailing whitespace or period
			const trimmed = std.mem.trim(u8, s, " \t.");
			summary.load_avg_15 = std.fmt.parseFloat(f64, trimmed) catch 0;
		}
	}

	/// Parse wired and compressor from "PhysMem: 74G used (8341M wired, 14G compressor), 52G unused."
	fn parsePhysMemDetail(line: []const u8, summary: *stats.SystemSummary) void {
		if (parseMemValue(line, " wired")) |v| summary.wired_bytes = v;
		if (parseMemValue(line, " compressor")) |v| summary.compressor_bytes = v;
	}

	/// Parse "VM: 520T vsize, ... 1817666(0) swapins, 6887756(0) swapouts."
	fn parseVmLine(line: []const u8, summary: *stats.SystemSummary) void {
		if (parseSwapValue(line, " swapins")) |v| summary.swap_ins = v;
		if (parseSwapValue(line, " swapouts")) |v| summary.swap_outs = v;
	}

	/// Parse "Networks: packets: 764293132/743G in, 539360737/308G out."
	fn parseNetworksLine(line: []const u8, summary: *stats.SystemSummary) void {
		// Find "packets: " marker
		const marker = "packets: ";
		const start = std.mem.indexOf(u8, line, marker) orelse return;
		const rest = line[start + marker.len ..];

		// Parse "764293132/743G in"
		if (std.mem.indexOf(u8, rest, " in")) |in_pos| {
			const in_part = rest[0..in_pos];
			if (std.mem.indexOfScalar(u8, in_part, '/')) |slash| {
				summary.net_packets_in = std.fmt.parseInt(u64, in_part[0..slash], 10) catch 0;
				summary.net_bytes_in = parseMemValueFromStr(in_part[slash + 1 ..]) orelse 0;
			}
		}

		// Parse "539360737/308G out"
		if (std.mem.indexOf(u8, rest, " out")) |out_pos| {
			// Find the start of the out segment (after ", ")
			var out_start: usize = 0;
			if (std.mem.indexOf(u8, rest, ", ")) |comma| {
				out_start = comma + 2;
			}
			const out_part = rest[out_start..out_pos];
			if (std.mem.indexOfScalar(u8, out_part, '/')) |slash| {
				summary.net_packets_out = std.fmt.parseInt(u64, out_part[0..slash], 10) catch 0;
				summary.net_bytes_out = parseMemValueFromStr(out_part[slash + 1 ..]) orelse 0;
			}
		}
	}

	/// Parse "Disks: 1065589758/20T read, 332337264/7236G written."
	fn parseDisksLine(line: []const u8, summary: *stats.SystemSummary) void {
		const marker = "Disks: ";
		if (!std.mem.startsWith(u8, line, marker)) return;
		const rest = line[marker.len..];

		// Parse "1065589758/20T read"
		if (std.mem.indexOf(u8, rest, " read")) |read_pos| {
			const read_part = rest[0..read_pos];
			if (std.mem.indexOfScalar(u8, read_part, '/')) |slash| {
				summary.disk_reads = std.fmt.parseInt(u64, read_part[0..slash], 10) catch 0;
				summary.disk_read_bytes = parseMemValueFromStr(read_part[slash + 1 ..]) orelse 0;
			}
		}

		// Parse "332337264/7236G written"
		if (std.mem.indexOf(u8, rest, " written")) |write_pos| {
			var write_start: usize = 0;
			if (std.mem.indexOf(u8, rest, ", ")) |comma| {
				write_start = comma + 2;
			}
			const write_part = rest[write_start..write_pos];
			if (std.mem.indexOfScalar(u8, write_part, '/')) |slash| {
				summary.disk_writes = std.fmt.parseInt(u64, write_part[0..slash], 10) catch 0;
				summary.disk_write_bytes = parseMemValueFromStr(write_part[slash + 1 ..]) orelse 0;
			}
		}
	}

	/// Parse an integer immediately before a suffix like " total".
	fn parseIntBefore(line: []const u8, suffix: []const u8) ?u64 {
		const pos = std.mem.indexOf(u8, line, suffix) orelse return null;
		var start: usize = pos;
		while (start > 0) {
			const c = line[start - 1];
			if (c >= '0' and c <= '9') {
				start -= 1;
			} else break;
		}
		if (start == pos) return null;
		return std.fmt.parseInt(u64, line[start..pos], 10) catch null;
	}

	/// Parse a swap value like "1817666(0)" before a suffix. Takes the number before the parens.
	fn parseSwapValue(line: []const u8, suffix: []const u8) ?u64 {
		const pos = std.mem.indexOf(u8, line, suffix) orelse return null;
		// Walk backward past "(0)" or similar
		var end = pos;
		if (end > 0 and line[end - 1] == ')') {
			end -= 1;
			while (end > 0 and line[end - 1] != '(') : (end -= 1) {}
			if (end > 0) end -= 1; // skip '('
		}
		var start = end;
		while (start > 0) {
			const c = line[start - 1];
			if (c >= '0' and c <= '9') {
				start -= 1;
			} else break;
		}
		if (start == end) return null;
		return std.fmt.parseInt(u64, line[start..end], 10) catch null;
	}

	/// Parse a standalone memory value string like "743G", "308G", "20T".
	fn parseMemValueFromStr(s: []const u8) ?u64 {
		if (s.len == 0) return null;
		const last = s[s.len - 1];
		var multiplier: u64 = 1;
		var num_end = s.len;
		if (last == 'T') {
			multiplier = 1024 * 1024 * 1024 * 1024;
			num_end = s.len - 1;
		} else if (last == 'G') {
			multiplier = 1024 * 1024 * 1024;
			num_end = s.len - 1;
		} else if (last == 'M') {
			multiplier = 1024 * 1024;
			num_end = s.len - 1;
		} else if (last == 'K') {
			multiplier = 1024;
			num_end = s.len - 1;
		} else if (last < '0' or last > '9') {
			return null;
		}
		if (num_end == 0) return null;
		const val = std.fmt.parseFloat(f64, s[0..num_end]) catch return null;
		return @intFromFloat(val * @as(f64, @floatFromInt(multiplier)));
	}

	// ── Static system info ───────────────────────────────────────────

	fn fetchNumCores(self: *DarwinBackend) u16 {
		const result = std.process.run(self.allocator, runtime.io(), .{
			.argv = &.{ "/usr/sbin/sysctl", "-n", "hw.logicalcpu" },
			.stdout_limit = .limited(64),
			.stderr_limit = .limited(64),
		}) catch return 1;
		defer self.allocator.free(result.stdout);
		defer self.allocator.free(result.stderr);
		const trimmed = std.mem.trim(u8, result.stdout, " \n\r");
		return std.fmt.parseInt(u16, trimmed, 10) catch 1;
	}

	fn fetchTotalMem(self: *DarwinBackend) u64 {
		const result = std.process.run(self.allocator, runtime.io(), .{
			.argv = &.{ "/usr/sbin/sysctl", "-n", "hw.memsize" },
			.stdout_limit = .limited(64),
			.stderr_limit = .limited(64),
		}) catch return 0;
		defer self.allocator.free(result.stdout);
		defer self.allocator.free(result.stderr);
		const trimmed = std.mem.trim(u8, result.stdout, " \n\r");
		return std.fmt.parseInt(u64, trimmed, 10) catch 0;
	}

	// ── HTTP Ping (curl-based, like webping) ────────────────────────

	fn doPing(self: *DarwinBackend, host: []const u8) stats.PingResult {
		const arena_alloc = self.arena.allocator();

		// Build URL: add https:// if no protocol
		const url: [:0]const u8 = blk: {
			if (std.mem.startsWith(u8, host, "http://") or std.mem.startsWith(u8, host, "https://")) {
				break :blk arena_alloc.dupeZ(u8, host) catch return failedPing(host);
			} else {
				const prefix = "https://";
				const buf = arena_alloc.alloc(u8, prefix.len + host.len + 1) catch return failedPing(host);
				@memcpy(buf[0..prefix.len], prefix);
				@memcpy(buf[prefix.len..][0..host.len], host);
				buf[prefix.len + host.len] = 0;
				break :blk buf[0 .. prefix.len + host.len :0];
			}
		};

		// Measure wall-clock time around curl
		const start_ns = monotonicNs(runtime.io());

		const result = std.process.run(arena_alloc, runtime.io(), .{
			.argv = &.{
				"/usr/bin/curl",
				"-L", "-s", "-o", "/dev/null",
				"--http2", "--compressed",
				"--connect-timeout", "5",
				"--max-time", "10",
				"-w", "%{time_total}",
				"-H", "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
				"-H", "Accept-Language: en-US,en;q=0.9",
				"-H", "Cache-Control: no-cache",
				"-H", "Sec-Fetch-Dest: document",
				"-H", "Sec-Fetch-Mode: navigate",
				"-H", "Sec-Fetch-Site: none",
				"-H", "Sec-Fetch-User: ?1",
				"-H", "Upgrade-Insecure-Requests: 1",
				"-H", "Connection: keep-alive",
				"-A", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
				url,
			},
			.stdout_limit = .limited(4096),
			.stderr_limit = .limited(4096),
		}) catch return failedPing(host);

		_ = start_ns;

		// curl -w "%{time_total}" outputs seconds as a float, e.g. "0.123456"
		const latency = parseCurlTime(result.stdout);
		return .{
			.host = host,
			.latency_ms = latency,
			.timestamp_ns = monotonicNs(runtime.io()),
		};
	}

	fn failedPing(host: []const u8) stats.PingResult {
		return .{
			.host = host,
			.latency_ms = null,
			.timestamp_ns = monotonicNs(runtime.io()),
		};
	}

	/// Parse curl -w "%{time_total}" output (seconds as float) into milliseconds.
	fn parseCurlTime(output: []const u8) ?f64 {
		const trimmed = std.mem.trim(u8, output, " \n\r\t");
		if (trimmed.len == 0) return null;
		const seconds = std.fmt.parseFloat(f64, trimmed) catch return null;
		if (seconds <= 0) return null;
		return seconds * 1000.0; // convert to ms
	}

	/// Parse ICMP ping output for "time=X.XXX ms" (kept for reference/fallback)
	fn parsePingOutput(output: []const u8) ?f64 {
		const marker = "time=";
		const pos = std.mem.indexOf(u8, output, marker) orelse return null;
		const start = pos + marker.len;

		// Find end of number (space or 'm')
		var end = start;
		while (end < output.len) : (end += 1) {
			const c = output[end];
			if (c != '.' and (c < '0' or c > '9')) break;
		}
		if (end == start) return null;

		return std.fmt.parseFloat(f64, output[start..end]) catch null;
	}

	// ── Vtable thunks ────────────────────────────────────────────────

	const gen = struct {
		fn getProcessList(ctx: *anyopaque) []const stats.ProcessInfo {
			const self: *DarwinBackend = @ptrCast(@alignCast(ctx));
			self.refreshIfNeeded();
			return self.cached_processes;
		}

		fn getCpuSnapshot(ctx: *anyopaque) stats.CpuSnapshot {
			const self: *DarwinBackend = @ptrCast(@alignCast(ctx));
			self.refreshIfNeeded();
			return self.cached_cpu;
		}

		fn getMemSnapshot(ctx: *anyopaque) stats.MemSnapshot {
			const self: *DarwinBackend = @ptrCast(@alignCast(ctx));
			self.refreshIfNeeded();
			return self.cached_mem;
		}

		fn getSystemSummary(ctx: *anyopaque) stats.SystemSummary {
			const self: *DarwinBackend = @ptrCast(@alignCast(ctx));
			self.refreshIfNeeded();
			return self.cached_summary;
		}

		fn ping(ctx: *anyopaque, host: []const u8) stats.PingResult {
			const self: *DarwinBackend = @ptrCast(@alignCast(ctx));
			return self.doPing(host);
		}
	};
};

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;
const builtin = @import("builtin");

test "extractBasename" {
	try testing.expectEqualStrings("firefox", DarwinBackend.extractBasename("/Applications/Firefox.app/Contents/MacOS/firefox"));
	try testing.expectEqualStrings("launchd", DarwinBackend.extractBasename("/sbin/launchd"));
	try testing.expectEqualStrings("bash", DarwinBackend.extractBasename("bash"));
	try testing.expectEqualStrings("zsh", DarwinBackend.extractBasename("/bin/zsh"));
}

test "parsePercentBefore" {
	const line = "CPU usage: 5.55% user, 3.33% sys, 91.12% idle";
	const user = DarwinBackend.parsePercentBefore(line, "% user");
	try testing.expect(user != null);
	try testing.expectApproxEqAbs(@as(f64, 5.55), user.?, 0.001);

	const sys = DarwinBackend.parsePercentBefore(line, "% sys");
	try testing.expect(sys != null);
	try testing.expectApproxEqAbs(@as(f64, 3.33), sys.?, 0.001);

	const idle = DarwinBackend.parsePercentBefore(line, "% idle");
	try testing.expect(idle != null);
	try testing.expectApproxEqAbs(@as(f64, 91.12), idle.?, 0.001);
}

test "parseMemValue" {
	const line = "PhysMem: 28G used (2G wired), 4G unused.";
	const used = DarwinBackend.parseMemValue(line, " used");
	try testing.expect(used != null);
	try testing.expectEqual(@as(u64, 28 * 1024 * 1024 * 1024), used.?);

	const unused = DarwinBackend.parseMemValue(line, " unused");
	try testing.expect(unused != null);
	try testing.expectEqual(@as(u64, 4 * 1024 * 1024 * 1024), unused.?);
}

test "parseMemValue with M units" {
	const line = "PhysMem: 25600M used (2048M wired), 6400M unused.";
	const used = DarwinBackend.parseMemValue(line, " used");
	try testing.expect(used != null);
	try testing.expectEqual(@as(u64, 25600 * 1024 * 1024), used.?);
}

test "parseCurlTime converts seconds to ms" {
	const ms = DarwinBackend.parseCurlTime("0.123456\n");
	try testing.expect(ms != null);
	try testing.expectApproxEqAbs(@as(f64, 123.456), ms.?, 0.01);
}

test "parseCurlTime handles clean output" {
	const ms = DarwinBackend.parseCurlTime("1.500000");
	try testing.expect(ms != null);
	try testing.expectApproxEqAbs(@as(f64, 1500.0), ms.?, 0.01);
}

test "parseCurlTime returns null for empty" {
	try testing.expect(DarwinBackend.parseCurlTime("") == null);
	try testing.expect(DarwinBackend.parseCurlTime("  \n") == null);
}

test "parsePingOutput" {
	const output = "64 bytes from 216.58.214.206: icmp_seq=0 ttl=119 time=12.345 ms\n";
	const latency = DarwinBackend.parsePingOutput(output);
	try testing.expect(latency != null);
	try testing.expectApproxEqAbs(@as(f64, 12.345), latency.?, 0.001);
}

test "parsePingOutput timeout" {
	const output = "Request timeout for icmp_seq 0\n";
	const latency = DarwinBackend.parsePingOutput(output);
	try testing.expect(latency == null);
}

test "parseProcessesLine" {
	var summary = stats.SystemSummary{};
	DarwinBackend.parseProcessesLine("Processes: 1162 total, 2 running, 1160 sleeping, 6370 threads ", &summary);
	try testing.expectEqual(@as(u32, 1162), summary.processes_total);
	try testing.expectEqual(@as(u32, 2), summary.processes_running);
	try testing.expectEqual(@as(u32, 1160), summary.processes_sleeping);
	try testing.expectEqual(@as(u32, 6370), summary.threads_total);
}

test "parseLoadAvgLine" {
	var summary = stats.SystemSummary{};
	DarwinBackend.parseLoadAvgLine("Load Avg: 4.95, 5.18, 6.07 ", &summary);
	try testing.expectApproxEqAbs(@as(f64, 4.95), summary.load_avg_1, 0.001);
	try testing.expectApproxEqAbs(@as(f64, 5.18), summary.load_avg_5, 0.001);
	try testing.expectApproxEqAbs(@as(f64, 6.07), summary.load_avg_15, 0.001);
}

test "parsePhysMemDetail wired and compressor" {
	var summary = stats.SystemSummary{};
	DarwinBackend.parsePhysMemDetail("PhysMem: 74G used (8341M wired, 14G compressor), 52G unused.", &summary);
	try testing.expectEqual(@as(u64, 8341 * 1024 * 1024), summary.wired_bytes);
	try testing.expectEqual(@as(u64, 14 * 1024 * 1024 * 1024), summary.compressor_bytes);
}

test "parseVmLine swap values" {
	var summary = stats.SystemSummary{};
	DarwinBackend.parseVmLine("VM: 520T vsize, 5361M framework vsize, 1817666(0) swapins, 6887756(0) swapouts.", &summary);
	try testing.expectEqual(@as(u64, 1817666), summary.swap_ins);
	try testing.expectEqual(@as(u64, 6887756), summary.swap_outs);
}

test "parseNetworksLine" {
	var summary = stats.SystemSummary{};
	DarwinBackend.parseNetworksLine("Networks: packets: 764293132/743G in, 539360737/308G out.", &summary);
	try testing.expectEqual(@as(u64, 764293132), summary.net_packets_in);
	try testing.expectEqual(@as(u64, 743 * 1024 * 1024 * 1024), summary.net_bytes_in);
	try testing.expectEqual(@as(u64, 539360737), summary.net_packets_out);
	try testing.expectEqual(@as(u64, 308 * 1024 * 1024 * 1024), summary.net_bytes_out);
}

test "parseDisksLine" {
	var summary = stats.SystemSummary{};
	DarwinBackend.parseDisksLine("Disks: 1065589758/20T read, 332337264/7236G written.", &summary);
	try testing.expectEqual(@as(u64, 1065589758), summary.disk_reads);
	try testing.expectEqual(@as(u64, 20 * 1024 * 1024 * 1024 * 1024), summary.disk_read_bytes);
	try testing.expectEqual(@as(u64, 332337264), summary.disk_writes);
	try testing.expectEqual(@as(u64, 7236 * 1024 * 1024 * 1024), summary.disk_write_bytes);
}

test "parseMemValueFromStr" {
	try testing.expectEqual(@as(?u64, 743 * 1024 * 1024 * 1024), DarwinBackend.parseMemValueFromStr("743G"));
	try testing.expectEqual(@as(?u64, 20 * 1024 * 1024 * 1024 * 1024), DarwinBackend.parseMemValueFromStr("20T"));
	try testing.expectEqual(@as(?u64, 500 * 1024 * 1024), DarwinBackend.parseMemValueFromStr("500M"));
	try testing.expectEqual(@as(?u64, null), DarwinBackend.parseMemValueFromStr(""));
}

test "parsePsLine basic" {
	const line = "  1234  12.3 567890 /usr/bin/node";
	if (DarwinBackend.parsePsLine(testing.allocator, line)) |proc| {
		defer testing.allocator.free(@constCast(proc.command));
		try testing.expectEqual(@as(u32, 1234), proc.pid);
		try testing.expectApproxEqAbs(@as(f64, 12.3), proc.cpu_percent, 0.001);
		try testing.expectEqual(@as(u64, 567890 * 1024), proc.rss_bytes);
		try testing.expectEqualStrings("node", proc.command);
	} else {
		return error.TestUnexpectedResult;
	}
}

// Integration tests: only run on macOS

test "DarwinBackend process data through aggregateProcesses" {
	if (comptime builtin.os.tag != .macos) return;
	runtime.setForTests();

	const data = @import("../data.zig");

	var backend = DarwinBackend.init(testing.allocator);
	defer backend.deinit();

	const iface = backend.interface();
	const procs = iface.getProcessList();
	try testing.expect(procs.len > 0);

	const result = try data.aggregateProcesses(testing.allocator, procs, .cpu, 15);
	defer testing.allocator.free(result);

	try testing.expect(result.len > 0);
	try testing.expect(result.len <= 15);

	for (result) |proc| {
		try testing.expect(proc.command.len > 0);
		try testing.expect(proc.process_count > 0);
	}
}

test "DarwinBackend through CpuHogs update" {
	if (comptime builtin.os.tag != .macos) return;
	runtime.setForTests();

	const CpuHogs = @import("../modules/cpu_hogs.zig").CpuHogs;

	const db = try testing.allocator.create(DarwinBackend);
	db.* = DarwinBackend.init(testing.allocator);
	defer {
		db.deinit();
		testing.allocator.destroy(db);
	}

	var hogs = CpuHogs.init(testing.allocator, db.interface(), 15);
	defer hogs.deinit();

	hogs.update();
	try testing.expect(hogs.aggregated != null);
}

test "DarwinBackend smoke test" {
	if (comptime builtin.os.tag != .macos) return;
	runtime.setForTests();

	var backend = DarwinBackend.init(testing.allocator);
	defer backend.deinit();

	try testing.expect(backend.num_cores > 0);
	try testing.expect(backend.total_mem_bytes > 0);

	const iface = backend.interface();

	// Process list should be non-empty on a running system
	const procs = iface.getProcessList();
	try testing.expect(procs.len > 0);

	// CPU should have plausible values
	const cpu = iface.getCpuSnapshot();
	try testing.expect(cpu.total_percent >= 0);
	try testing.expect(cpu.total_percent <= 100);
	try testing.expect(cpu.num_cores > 0);

	// Memory should be non-zero
	const mem = iface.getMemSnapshot();
	try testing.expect(mem.total_bytes > 0);
	try testing.expect(mem.used_bytes > 0);
}
