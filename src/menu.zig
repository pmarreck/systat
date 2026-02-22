//! Menu bar — minimal menu at the top of the window.
//! Systat → About, Quit

const std = @import("std");
const dvui = @import("dvui");

pub const MenuAction = enum {
	none,
	quit,
};

/// Render the menu bar. Returns the action triggered (if any).
pub fn render() MenuAction {
	var m = dvui.menu(@src(), .horizontal, .{ .expand = .horizontal });
	defer m.deinit();

	if (dvui.menuItemLabel(@src(), "Systat", .{ .submenu = true }, .{})) |r| {
		var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
		defer fw.deinit();

		if (dvui.menuItemLabel(@src(), "About", .{}, .{ .expand = .horizontal }) != null) {
			dvui.dialog(@src(), .{}, .{
				.title = "About systat",
				.message = "systat — System Monitor\n\nPure Zig + DVUI\nhttps://github.com/pmarreck/systat",
			});
			fw.close();
		}

		_ = dvui.separator(@src(), .{ .expand = .horizontal });

		if (dvui.menuItemLabel(@src(), "Quit", .{}, .{ .expand = .horizontal }) != null) {
			fw.close();
			return .quit;
		}
	}

	return .none;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "MenuAction enum has expected variants" {
	const a: MenuAction = .none;
	const b: MenuAction = .quit;
	try testing.expect(a != b);
}
