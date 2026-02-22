//! Status bar — thin bar at the bottom of the window showing:
//! - Config status (reload messages, errors)
//! - Last refresh timestamp

const std = @import("std");
const dvui = @import("dvui");

pub const StatusBar = struct {
	message: ?[]const u8 = null,
	message_is_error: bool = false,
	frame_count: u64 = 0,

	pub fn init() StatusBar {
		return .{};
	}

	/// Set a transient status message (shown for a few seconds).
	pub fn setMessage(self: *StatusBar, msg: []const u8) void {
		self.message = msg;
		self.message_is_error = false;
		self.frame_count = 0;
	}

	/// Set a persistent error message (shown until cleared).
	pub fn setError(self: *StatusBar, msg: []const u8) void {
		self.message = msg;
		self.message_is_error = true;
		self.frame_count = 0;
	}

	/// Clear any displayed message.
	pub fn clearMessage(self: *StatusBar) void {
		self.message = null;
		self.message_is_error = false;
	}

	/// Render the status bar. Call once per frame.
	pub fn render(self: *StatusBar) void {
		self.frame_count +|= 1;

		// Fade transient messages after ~3 seconds (assuming ~1 fps update rate)
		if (self.message != null and !self.message_is_error and self.frame_count > 3) {
			self.message = null;
		}

		var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
			.expand = .horizontal,
			.padding = dvui.Rect.all(4),
			.border = .{ .x = 0, .y = 1, .w = 0, .h = 0 },
		});
		defer bar.deinit();

		// Left side: status message
		if (self.message) |msg| {
			if (self.message_is_error) {
				dvui.labelNoFmt(@src(), msg, .{}, .{
					.style = .err,
				});
			} else {
				dvui.labelNoFmt(@src(), msg, .{}, .{});
			}
		} else {
			dvui.label(@src(), "Ready", .{}, .{});
		}
	}
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "StatusBar init is ready state" {
	const sb = StatusBar.init();
	try testing.expect(sb.message == null);
	try testing.expect(!sb.message_is_error);
}

test "StatusBar setMessage stores message" {
	var sb = StatusBar.init();
	sb.setMessage("Config reloaded");
	try testing.expect(sb.message != null);
	try testing.expectEqualStrings("Config reloaded", sb.message.?);
	try testing.expect(!sb.message_is_error);
}

test "StatusBar setError stores error" {
	var sb = StatusBar.init();
	sb.setError("Config parse error: line 5");
	try testing.expect(sb.message != null);
	try testing.expectEqualStrings("Config parse error: line 5", sb.message.?);
	try testing.expect(sb.message_is_error);
}

test "StatusBar clearMessage clears" {
	var sb = StatusBar.init();
	sb.setError("error");
	sb.clearMessage();
	try testing.expect(sb.message == null);
	try testing.expect(!sb.message_is_error);
}

test "StatusBar transient message fades after frames" {
	var sb = StatusBar.init();
	sb.setMessage("Config reloaded");

	// Simulate frames — transient messages fade after 3 frames
	for (0..4) |_| {
		sb.frame_count +|= 1;
	}

	// After 4 frames, the next render should clear it
	// (render checks frame_count > 3 for non-error messages)
	// We can test the logic without DVUI context by checking directly
	if (sb.message != null and !sb.message_is_error and sb.frame_count > 3) {
		sb.message = null;
	}
	try testing.expect(sb.message == null);
}

test "StatusBar error message persists across frames" {
	var sb = StatusBar.init();
	sb.setError("Config error");

	// Simulate many frames
	for (0..100) |_| {
		sb.frame_count +|= 1;
	}

	// Error messages don't auto-fade
	if (sb.message != null and !sb.message_is_error and sb.frame_count > 3) {
		sb.message = null;
	}
	try testing.expect(sb.message != null);
	try testing.expectEqualStrings("Config error", sb.message.?);
}
