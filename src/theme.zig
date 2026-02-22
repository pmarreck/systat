//! Theme resolution: maps config presets and custom hex colors to dvui.Theme.
//! All rendering uses dvui.Theme directly — no separate color type needed.

const std = @import("std");
const dvui = @import("dvui");
const config = @import("config.zig");

const Color = dvui.Color;
const Theme = dvui.Theme;
const Font = dvui.Font;

// ── Theme Presets ──────────────────────────────────────────────────────

/// Neon orange theme — cyberpunk with orange primary and purple accent.
pub const neon_orange: Theme = blk: {
	@setEvalBranchQuota(50000);
	break :blk makeCyberpunk(
		"Neon Orange",
		.fromHex("#0D0D0D"), // fill (background)
		.fromHex("#FF6600"), // focus (primary/orange)
		.fromHex("#9933FF"), // highlight (accent/purple)
		.fromHex("#00FF66"), // app1 (success/green)
		.fromHex("#FFCC00"), // app2 (warning/yellow)
		.fromHex("#FF3333"), // err (red)
		.fromHex("#E0E0E0"), // text
		.fromHex("#808080"), // border (dim)
	);
};

/// Neon cyan theme — cyberpunk with cyan primary and magenta accent.
pub const neon_cyan: Theme = blk: {
	@setEvalBranchQuota(50000);
	break :blk makeCyberpunk(
		"Neon Cyan",
		.fromHex("#0D0D0D"), // fill
		.fromHex("#00FFFF"), // focus (cyan)
		.fromHex("#FF00FF"), // highlight (magenta)
		.fromHex("#00FF66"), // app1 (success)
		.fromHex("#FFCC00"), // app2 (warning)
		.fromHex("#FF3333"), // err
		.fromHex("#E0E0E0"), // text
		.fromHex("#808080"), // border
	);
};

fn makeCyberpunk(
	comptime name: []const u8,
	fill: Color,
	focus: Color,
	highlight_color: Color,
	success: Color,
	warning: Color,
	err_color: Color,
	text: Color,
	border: Color,
) Theme {
	@setEvalBranchQuota(10000);
	return .{
		.name = name,
		.dark = true,
		.focus = focus,
		.fill = fill,
		.text = text,
		.border = border,

		.font_body = .find(.{ .family = "Vera Sans" }),
		.font_heading = .find(.{ .family = "Vera Sans", .weight = .bold }),
		.font_title = .find(.{ .family = "Vera Sans", .size = Font.DefaultSize + 2 }),
		.font_mono = .find(.{ .family = "Vera Sans Mono" }),

		.control = .{
			.fill = focus,
			.text = fill,
			.text_press = fill,
		},
		.window = .{
			.fill = fill,
			.border = border,
		},
		.highlight = .{
			.fill = highlight_color,
			.text = text,
		},
		.err = .{
			.fill = err_color,
			.text = text,
		},
		.app1 = .{
			.fill = success,
			.text = fill,
		},
		.app2 = .{
			.fill = warning,
			.text = fill,
		},
		.app3 = .{
			.fill = highlight_color,
			.text = text,
		},
	};
}

/// Look up a named preset theme.
fn getPreset(name: []const u8) ?Theme {
	if (std.mem.eql(u8, name, "neon_orange")) return neon_orange;
	if (std.mem.eql(u8, name, "neon_cyan")) return neon_cyan;
	return null;
}

/// Resolve a theme from config. Named presets are returned directly;
/// "custom" builds a theme from hex colors in cfg.custom_theme (falling
/// back to neon_orange defaults for any unset field).
pub fn resolveTheme(cfg: config.Config) !Theme {
	if (std.mem.eql(u8, cfg.theme, "custom")) {
		return resolveCustomTheme(cfg.custom_theme);
	}
	if (getPreset(cfg.theme)) |preset| {
		return preset;
	}
	return error.UnknownTheme;
}

/// Build a dvui.Theme from CustomTheme hex strings, falling back to
/// neon_orange for any null field.
fn resolveCustomTheme(ct: config.CustomTheme) !Theme {
	// Parse each field, falling back to neon_orange's corresponding color
	const fill = if (ct.background) |hex| Color.fromHex(hex) else neon_orange.fill;
	const focus = if (ct.primary) |hex| Color.fromHex(hex) else neon_orange.focus;
	const highlight_color = if (ct.accent) |hex| Color.fromHex(hex) else neon_orange.highlight.fill orelse neon_orange.focus;
	const success = if (ct.success) |hex| Color.fromHex(hex) else if (neon_orange.app1.fill) |c| c else neon_orange.focus;
	const warning = if (ct.warning) |hex| Color.fromHex(hex) else if (neon_orange.app2.fill) |c| c else neon_orange.focus;
	const err_color = if (ct.err) |hex| Color.fromHex(hex) else if (neon_orange.err.fill) |c| c else .red;
	const text = if (ct.text) |hex| Color.fromHex(hex) else neon_orange.text;
	const border = if (ct.text_dim) |hex| Color.fromHex(hex) else neon_orange.border;

	return makeCyberpunk("Custom", fill, focus, highlight_color, success, warning, err_color, text, border);
}

// ── Tests ──────────────────────────────────────────────────────────────

test "neon_orange preset has correct focus color (orange)" {
	try std.testing.expectEqual(@as(u8, 0xFF), neon_orange.focus.r);
	try std.testing.expectEqual(@as(u8, 0x66), neon_orange.focus.g);
	try std.testing.expectEqual(@as(u8, 0x00), neon_orange.focus.b);
}

test "neon_cyan preset has correct focus color (cyan)" {
	try std.testing.expectEqual(@as(u8, 0x00), neon_cyan.focus.r);
	try std.testing.expectEqual(@as(u8, 0xFF), neon_cyan.focus.g);
	try std.testing.expectEqual(@as(u8, 0xFF), neon_cyan.focus.b);
}

test "neon_orange is a dark theme" {
	try std.testing.expect(neon_orange.dark);
}

test "resolveTheme neon_orange preset" {
	const cfg = config.Config{ .theme = "neon_orange" };
	const theme = try resolveTheme(cfg);
	try std.testing.expectEqual(@as(u8, 0xFF), theme.focus.r);
	try std.testing.expectEqual(@as(u8, 0x66), theme.focus.g);
	try std.testing.expectEqual(@as(u8, 0x00), theme.focus.b);
}

test "resolveTheme neon_cyan preset" {
	const cfg = config.Config{ .theme = "neon_cyan" };
	const theme = try resolveTheme(cfg);
	try std.testing.expectEqual(@as(u8, 0x00), theme.focus.r);
	try std.testing.expectEqual(@as(u8, 0xFF), theme.focus.g);
	try std.testing.expectEqual(@as(u8, 0xFF), theme.focus.b);
}

test "resolveTheme unknown preset" {
	const cfg = config.Config{ .theme = "nonexistent" };
	const result = resolveTheme(cfg);
	try std.testing.expectError(error.UnknownTheme, result);
}

test "resolveTheme custom with primary override" {
	const cfg = config.Config{
		.theme = "custom",
		.custom_theme = .{
			.primary = "#00CCFF",
		},
	};
	const theme = try resolveTheme(cfg);
	// Custom focus/primary
	try std.testing.expectEqual(@as(u8, 0x00), theme.focus.r);
	try std.testing.expectEqual(@as(u8, 0xCC), theme.focus.g);
	try std.testing.expectEqual(@as(u8, 0xFF), theme.focus.b);
	// Fallback fill from neon_orange
	try std.testing.expectEqual(@as(u8, 0x0D), theme.fill.r);
}

test "resolveTheme custom with all fields" {
	const cfg = config.Config{
		.theme = "custom",
		.custom_theme = .{
			.background = "#111111",
			.primary = "#22AAFF",
			.accent = "#FF00AA",
			.success = "#00FF00",
			.warning = "#FFFF00",
			.err = "#FF0000",
			.text = "#FFFFFF",
			.text_dim = "#999999",
		},
	};
	const theme = try resolveTheme(cfg);
	try std.testing.expectEqual(@as(u8, 0x22), theme.focus.r);
	try std.testing.expectEqual(@as(u8, 0xAA), theme.focus.g);
	try std.testing.expectEqual(@as(u8, 0xFF), theme.focus.b);
	try std.testing.expectEqual(@as(u8, 0xFF), theme.text.r);
}

test "neon_orange has highlight (accent) set to purple" {
	const hl = neon_orange.highlight.fill orelse unreachable;
	try std.testing.expectEqual(@as(u8, 0x99), hl.r);
	try std.testing.expectEqual(@as(u8, 0x33), hl.g);
	try std.testing.expectEqual(@as(u8, 0xFF), hl.b);
}

test "neon_cyan has highlight (accent) set to magenta" {
	const hl = neon_cyan.highlight.fill orelse unreachable;
	try std.testing.expectEqual(@as(u8, 0xFF), hl.r);
	try std.testing.expectEqual(@as(u8, 0x00), hl.g);
	try std.testing.expectEqual(@as(u8, 0xFF), hl.b);
}
