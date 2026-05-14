//! Data processing module: aggregation functions and formatting utilities.
//! Pure functions with no I/O — suitable for unit testing without mocks.

const std = @import("std");
const stats = @import("platform/stats.zig");

pub const AggregatedProcess = struct {
	command: []const u8,
	process_count: u32,
	total_cpu_percent: f64,
	total_rss_bytes: u64,
};

pub const SortBy = enum { cpu, memory };

/// Aggregate a slice of ProcessInfo by command name.
///
/// Groups processes with the same command, summing their CPU and RSS,
/// sorts by the requested key (descending), and truncates to max_results.
/// Caller owns the returned slice and must free it with the same allocator.
pub fn aggregateProcesses(
	allocator: std.mem.Allocator,
	processes: []const stats.ProcessInfo,
	sort_by: SortBy,
	max_results: usize,
) ![]AggregatedProcess {
	// Accumulator: command name -> index into our list
	var map = std.StringHashMap(usize).init(allocator);
	defer map.deinit();

	// Collect aggregated entries into a dynamic list (unmanaged in Zig 0.15+)
	var list: std.ArrayList(AggregatedProcess) = .empty;
	defer list.deinit(allocator);

	for (processes) |proc| {
		if (map.get(proc.command)) |idx| {
			// Existing entry — accumulate
			list.items[idx].process_count += 1;
			list.items[idx].total_cpu_percent += proc.cpu_percent;
			list.items[idx].total_rss_bytes += proc.rss_bytes;
		} else {
			// New command — create entry and record its index
			const idx = list.items.len;
			try list.append(allocator, .{
				.command = proc.command,
				.process_count = 1,
				.total_cpu_percent = proc.cpu_percent,
				.total_rss_bytes = proc.rss_bytes,
			});
			try map.put(proc.command, idx);
		}
	}

	// Sort descending by the requested key
	const items = list.items;
	switch (sort_by) {
		.cpu => std.mem.sort(AggregatedProcess, items, {}, struct {
			fn lessThan(_: void, a: AggregatedProcess, b: AggregatedProcess) bool {
				return a.total_cpu_percent > b.total_cpu_percent;
			}
		}.lessThan),
		.memory => std.mem.sort(AggregatedProcess, items, {}, struct {
			fn lessThan(_: void, a: AggregatedProcess, b: AggregatedProcess) bool {
				return a.total_rss_bytes > b.total_rss_bytes;
			}
		}.lessThan),
	}

	// Truncate to max_results
	const count = @min(items.len, max_results);

	// Allocate result slice owned by caller
	const result = try allocator.alloc(AggregatedProcess, count);
	@memcpy(result, items[0..count]);

	return result;
}

/// Format a byte count into a human-readable string like "1.50 MB".
///
/// Writes into the provided buffer and returns the written slice.
/// Supports B, KB, MB, GB, TB.
pub fn formatBytes(bytes: u64, buf: []u8) []const u8 {
	const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
	var value: f64 = @floatFromInt(bytes);
	var unit_idx: usize = 0;

	while (value >= 1024.0 and unit_idx < units.len - 1) {
		value /= 1024.0;
		unit_idx += 1;
	}

	if (unit_idx == 0) {
		// Bytes: no decimal places
		return std.fmt.bufPrint(buf, "{d} {s}", .{ bytes, units[0] }) catch "?";
	} else {
		return std.fmt.bufPrint(buf, "{d:.2} {s}", .{ value, units[unit_idx] }) catch "?";
	}
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "aggregateProcesses groups by command" {
	const allocator = std.testing.allocator;

	const processes = [_]stats.ProcessInfo{
		.{ .pid = 1, .command = "node", .cpu_percent = 10.0, .rss_bytes = 1000 },
		.{ .pid = 2, .command = "node", .cpu_percent = 20.0, .rss_bytes = 2000 },
		.{ .pid = 3, .command = "bash", .cpu_percent = 5.0, .rss_bytes = 500 },
	};

	const result = try aggregateProcesses(allocator, &processes, .cpu, 10);
	defer allocator.free(result);

	// Should produce 2 aggregated entries: "node" and "bash"
	try std.testing.expectEqual(@as(usize, 2), result.len);

	// Sorted by CPU descending, so node (30%) comes first
	try std.testing.expectEqualStrings("node", result[0].command);
	try std.testing.expectEqual(@as(u32, 2), result[0].process_count);
	try std.testing.expectApproxEqAbs(@as(f64, 30.0), result[0].total_cpu_percent, 0.001);
	try std.testing.expectEqual(@as(u64, 3000), result[0].total_rss_bytes);

	try std.testing.expectEqualStrings("bash", result[1].command);
	try std.testing.expectEqual(@as(u32, 1), result[1].process_count);
	try std.testing.expectApproxEqAbs(@as(f64, 5.0), result[1].total_cpu_percent, 0.001);
	try std.testing.expectEqual(@as(u64, 500), result[1].total_rss_bytes);
}

test "aggregateProcesses sorts by memory" {
	const allocator = std.testing.allocator;

	const processes = [_]stats.ProcessInfo{
		.{ .pid = 1, .command = "firefox", .cpu_percent = 50.0, .rss_bytes = 1000 },
		.{ .pid = 2, .command = "node", .cpu_percent = 5.0, .rss_bytes = 5000 },
	};

	const result = try aggregateProcesses(allocator, &processes, .memory, 10);
	defer allocator.free(result);

	try std.testing.expectEqual(@as(usize, 2), result.len);
	// Sorted by memory descending: node (5000) before firefox (1000)
	try std.testing.expectEqualStrings("node", result[0].command);
	try std.testing.expectEqualStrings("firefox", result[1].command);
}

test "aggregateProcesses respects max_results" {
	const allocator = std.testing.allocator;

	const processes = [_]stats.ProcessInfo{
		.{ .pid = 1, .command = "alpha", .cpu_percent = 10.0, .rss_bytes = 100 },
		.{ .pid = 2, .command = "beta", .cpu_percent = 20.0, .rss_bytes = 200 },
		.{ .pid = 3, .command = "gamma", .cpu_percent = 30.0, .rss_bytes = 300 },
	};

	const result = try aggregateProcesses(allocator, &processes, .cpu, 2);
	defer allocator.free(result);

	// 3 unique commands, max_results=2 -> only 2 returned
	try std.testing.expectEqual(@as(usize, 2), result.len);
	// Top 2 by CPU: gamma (30%), beta (20%)
	try std.testing.expectEqualStrings("gamma", result[0].command);
	try std.testing.expectEqualStrings("beta", result[1].command);
}

test "formatBytes human-readable sizes" {
	var buf: [32]u8 = undefined;

	try std.testing.expectEqualStrings("0 B", formatBytes(0, &buf));
	try std.testing.expectEqualStrings("512 B", formatBytes(512, &buf));
	try std.testing.expectEqualStrings("1.00 KB", formatBytes(1024, &buf));
	try std.testing.expectEqualStrings("1.50 MB", formatBytes(1536 * 1024, &buf));
	try std.testing.expectEqualStrings("2.00 GB", formatBytes(2 * 1024 * 1024 * 1024, &buf));
}

test "aggregateProcesses empty input" {
	const allocator = std.testing.allocator;
	const processes = [_]stats.ProcessInfo{};

	const result = try aggregateProcesses(allocator, &processes, .cpu, 10);
	defer allocator.free(result);

	try std.testing.expectEqual(@as(usize, 0), result.len);
}
