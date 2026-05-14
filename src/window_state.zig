//! Window state persistence: save/restore window size and position across sessions.
//! State is stored as a simple text file in the user's config directory.

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime.zig");

pub const WindowState = struct {
	width: i32,
	height: i32,
	x: i32,
	y: i32,
};

const state_filename = "window_state";

/// Get the path to the window state file.
/// Returns null if the config directory can't be determined.
fn getStatePath(buf: *[std.Io.Dir.max_path_bytes]u8) ?[]const u8 {
	return getStatePathImpl(buf);
}

fn getStatePathImpl(buf: anytype) ?[]const u8 {
	if (comptime builtin.os.tag == .windows) {
		// Windows support is a stub for now — window state persistence
		// will be implemented when a Windows platform backend exists.
		return null;
	}
	const env = runtime.env();
	// POSIX: try XDG_CONFIG_HOME, then ~/.config
	if (env.get("XDG_CONFIG_HOME")) |xdg| {
		return std.fmt.bufPrint(buf, "{s}/systat/{s}", .{ xdg, state_filename }) catch null;
	}
	if (env.get("HOME")) |home| {
		return std.fmt.bufPrint(buf, "{s}/.config/systat/{s}", .{ home, state_filename }) catch null;
	}
	return null;
}

/// Ensure the parent directory exists for the state file.
fn ensureDir(path: []const u8) void {
	const sep: u8 = if (comptime builtin.os.tag == .windows) '\\' else '/';
	if (std.mem.lastIndexOfScalar(u8, path, sep)) |pos| {
		const dir_path = path[0..pos];
		std.Io.Dir.cwd().createDirPath(runtime.io(), dir_path) catch {};
	}
}

/// Load saved window state. Returns null if no saved state exists.
pub fn load() ?WindowState {
	const io = runtime.io();
	var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
	const path = getStatePath(&path_buf) orelse return null;

	const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
	defer file.close(io);

	var line_buf: [256]u8 = undefined;
	const bytes_read = blk: {
		var reader_buf: [256]u8 = undefined;
		var reader = file.reader(io, &reader_buf);
		const n = reader.interface.readSliceShort(&line_buf) catch return null;
		break :blk n;
	};
	const content = line_buf[0..bytes_read];

	return parse(content);
}

/// Save window state to disk.
pub fn save(state: WindowState) void {
	const io = runtime.io();
	var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
	const path = getStatePath(&path_buf) orelse return;

	ensureDir(path);

	var write_buf: [128]u8 = undefined;
	const data = std.fmt.bufPrint(&write_buf, "{d} {d} {d} {d}", .{
		state.width, state.height, state.x, state.y,
	}) catch return;

	const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
	defer file.close(io);
	file.writeStreamingAll(io, data) catch {};
}

/// Parse "width height x y" from a string.
fn parse(content: []const u8) ?WindowState {
	const trimmed = std.mem.trim(u8, content, " \n\r\t");
	var iter = std.mem.splitScalar(u8, trimmed, ' ');

	const w_str = iter.next() orelse return null;
	const h_str = iter.next() orelse return null;
	const x_str = iter.next() orelse return null;
	const y_str = iter.next() orelse return null;

	return .{
		.width = std.fmt.parseInt(i32, w_str, 10) catch return null,
		.height = std.fmt.parseInt(i32, h_str, 10) catch return null,
		.x = std.fmt.parseInt(i32, x_str, 10) catch return null,
		.y = std.fmt.parseInt(i32, y_str, 10) catch return null,
	};
}

// ── Tests ──────────────────────────────────────────────────────────────

test "parse valid state" {
	const state = parse("900 700 100 200");
	try std.testing.expect(state != null);
	const s = state.?;
	try std.testing.expectEqual(@as(i32, 900), s.width);
	try std.testing.expectEqual(@as(i32, 700), s.height);
	try std.testing.expectEqual(@as(i32, 100), s.x);
	try std.testing.expectEqual(@as(i32, 200), s.y);
}

test "parse with whitespace" {
	const state = parse("  800 600 50 75  \n");
	try std.testing.expect(state != null);
	try std.testing.expectEqual(@as(i32, 800), state.?.width);
}

test "parse invalid returns null" {
	try std.testing.expect(parse("") == null);
	try std.testing.expect(parse("900") == null);
	try std.testing.expect(parse("900 700") == null);
	try std.testing.expect(parse("abc def ghi jkl") == null);
}

test "round-trip format/parse" {
	const original = WindowState{ .width = 1024, .height = 768, .x = 50, .y = 100 };
	var buf: [128]u8 = undefined;
	const data = std.fmt.bufPrint(&buf, "{d} {d} {d} {d}", .{
		original.width, original.height, original.x, original.y,
	}) catch unreachable;

	const parsed = parse(data);
	try std.testing.expect(parsed != null);
	const s = parsed.?;
	try std.testing.expectEqual(original.width, s.width);
	try std.testing.expectEqual(original.height, s.height);
	try std.testing.expectEqual(original.x, s.x);
	try std.testing.expectEqual(original.y, s.y);
}
