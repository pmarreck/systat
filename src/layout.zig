const std = @import("std");
const module = @import("module.zig");

pub const Rect = struct {
	x: u16,
	y: u16,
	w: u16,
	h: u16,
};

pub const PlacedModule = struct {
	module_index: usize,
	rect: Rect,
};

/// Compute layout for modules in a window using priority-based greedy column placement.
///
/// Algorithm:
/// 1. Sort module indices by priority (ascending = highest priority first)
/// 2. Determine column count: window_w / min(preferred_widths), clamped to 1-3
/// 3. Column width = window_w / num_columns
/// 4. Walk sorted modules, greedily place into columns. Track current Y per column.
/// 5. Skip modules whose min_width > column_width or min_height > remaining height
/// 6. Allocate preferred_height where possible, min_height otherwise
/// 7. Caller owns returned slice (allocated with provided allocator)
pub fn computeLayout(
	allocator: std.mem.Allocator,
	window_w: u16,
	window_h: u16,
	infos: []const module.ModuleInfo,
	priorities: []const u8,
) ![]PlacedModule {
	std.debug.assert(infos.len == priorities.len);

	if (infos.len == 0) {
		return try allocator.alloc(PlacedModule, 0);
	}

	// Step 1: Create sorted indices by priority (ascending = highest priority first)
	var sorted_indices = std.ArrayListUnmanaged(usize){};
	defer sorted_indices.deinit(allocator);
	try sorted_indices.ensureTotalCapacity(allocator, infos.len);
	for (0..infos.len) |i| {
		sorted_indices.appendAssumeCapacity(i);
	}

	const SortCtx = struct {
		prios: []const u8,

		pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
			return ctx.prios[a] < ctx.prios[b];
		}
	};
	std.mem.sort(usize, sorted_indices.items, SortCtx{ .prios = priorities }, SortCtx.lessThan);

	// Step 2: Determine column count from min preferred width
	var min_pref_w: u16 = std.math.maxInt(u16);
	for (infos) |info| {
		if (info.preferred_width < min_pref_w) {
			min_pref_w = info.preferred_width;
		}
	}
	// Avoid division by zero
	if (min_pref_w == 0) min_pref_w = 1;

	var num_columns: u16 = window_w / min_pref_w;
	if (num_columns < 1) num_columns = 1;
	if (num_columns > 3) num_columns = 3;

	// Step 3: Column width
	const col_width: u16 = window_w / num_columns;

	// Step 4: Track current Y per column
	var col_y: [3]u16 = .{ 0, 0, 0 };

	// Step 5-6: Walk sorted modules, greedily place
	var placed = std.ArrayListUnmanaged(PlacedModule){};
	defer placed.deinit(allocator);
	try placed.ensureTotalCapacity(allocator, infos.len);

	for (sorted_indices.items) |idx| {
		const info = infos[idx];

		// Skip if module is too wide for any column
		if (info.min_width > col_width) continue;

		// Find the column with the least Y (most space remaining)
		var best_col: u16 = 0;
		var best_y: u16 = col_y[0];
		for (1..num_columns) |c| {
			if (col_y[c] < best_y) {
				best_y = col_y[c];
				best_col = @intCast(c);
			}
		}

		const remaining_h = if (window_h > col_y[best_col])
			window_h - col_y[best_col]
		else
			0;

		// Skip if not enough vertical space for even min_height
		if (info.min_height > remaining_h) continue;

		// Allocate preferred_height if possible, min_height otherwise
		const allocated_h: u16 = if (info.preferred_height <= remaining_h)
			info.preferred_height
		else
			info.min_height;

		placed.appendAssumeCapacity(.{
			.module_index = idx,
			.rect = .{
				.x = best_col * col_width,
				.y = col_y[best_col],
				.w = col_width,
				.h = allocated_h,
			},
		});

		col_y[best_col] += allocated_h;
	}

	// Step 7: Transfer ownership to caller
	const result = try allocator.alloc(PlacedModule, placed.items.len);
	@memcpy(result, placed.items);
	return result;
}

// ===== Test helpers =====

fn makeInfo(id: []const u8, priority: u8, min_w: u16, min_h: u16, pref_w: u16, pref_h: u16) module.ModuleInfo {
	return .{
		.id = id,
		.display_name = id,
		.default_priority = priority,
		.min_width = min_w,
		.min_height = min_h,
		.preferred_width = pref_w,
		.preferred_height = pref_h,
	};
}

// ===== Tests =====

test "empty module list returns empty slice" {
	const result = try computeLayout(std.testing.allocator, 800, 600, &.{}, &.{});
	defer std.testing.allocator.free(result);
	try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "single module fits in window" {
	const infos = [_]module.ModuleInfo{
		makeInfo("cpu", 1, 200, 100, 400, 200),
	};
	const priorities = [_]u8{1};
	const result = try computeLayout(std.testing.allocator, 800, 600, &infos, &priorities);
	defer std.testing.allocator.free(result);
	try std.testing.expectEqual(@as(usize, 1), result.len);
	try std.testing.expectEqual(@as(usize, 0), result[0].module_index);
	// Should have reasonable dimensions
	try std.testing.expect(result[0].rect.w >= 200);
	try std.testing.expect(result[0].rect.h >= 100);
}

test "module too wide is hidden" {
	const infos = [_]module.ModuleInfo{
		makeInfo("wide", 1, 500, 100, 600, 200),
	};
	const priorities = [_]u8{1};
	const result = try computeLayout(std.testing.allocator, 400, 600, &infos, &priorities);
	defer std.testing.allocator.free(result);
	try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "modules sorted by priority" {
	const infos = [_]module.ModuleInfo{
		makeInfo("low", 5, 100, 100, 200, 200),
		makeInfo("high", 1, 100, 100, 200, 200),
		makeInfo("mid", 3, 100, 100, 200, 200),
	};
	const priorities = [_]u8{ 5, 1, 3 };
	const result = try computeLayout(std.testing.allocator, 800, 600, &infos, &priorities);
	defer std.testing.allocator.free(result);
	try std.testing.expectEqual(@as(usize, 3), result.len);
	// First placed module should be index 1 (priority 1)
	try std.testing.expectEqual(@as(usize, 1), result[0].module_index);
}

test "1 column for narrow window" {
	const infos = [_]module.ModuleInfo{
		makeInfo("a", 1, 200, 100, 400, 150),
		makeInfo("b", 2, 200, 100, 400, 150),
	};
	const priorities = [_]u8{ 1, 2 };
	const result = try computeLayout(std.testing.allocator, 450, 600, &infos, &priorities);
	defer std.testing.allocator.free(result);
	try std.testing.expectEqual(@as(usize, 2), result.len);
	// Both should be in column 0 (x=0), stacked vertically
	try std.testing.expectEqual(@as(u16, 0), result[0].rect.x);
	try std.testing.expectEqual(@as(u16, 0), result[1].rect.x);
	// Second module should be below the first
	try std.testing.expect(result[1].rect.y > result[0].rect.y);
}

test "drops lowest priority when space runs out" {
	const infos = [_]module.ModuleInfo{
		makeInfo("a", 1, 100, 200, 200, 200),
		makeInfo("b", 2, 100, 200, 200, 200),
		makeInfo("c", 3, 100, 200, 200, 200),
	};
	const priorities = [_]u8{ 1, 2, 3 };
	// 400px tall window can only fit 2 modules at 200px each
	const result = try computeLayout(std.testing.allocator, 200, 400, &infos, &priorities);
	defer std.testing.allocator.free(result);
	try std.testing.expectEqual(@as(usize, 2), result.len);
	// The two placed modules should be priority 1 and 2 (indices 0 and 1)
	try std.testing.expectEqual(@as(usize, 0), result[0].module_index);
	try std.testing.expectEqual(@as(usize, 1), result[1].module_index);
}
