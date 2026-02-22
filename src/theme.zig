const std = @import("std");
const config = @import("config.zig");

/// RGBA color with 8 bits per channel.
pub const Color = struct {
	r: u8,
	g: u8,
	b: u8,
	a: u8 = 255,

	/// Compare two colors for equality.
	pub fn eql(self: Color, other: Color) bool {
		return self.r == other.r and self.g == other.g and self.b == other.b and self.a == other.a;
	}
};

/// A complete color theme for the application UI.
pub const Theme = struct {
	background: Color,
	primary: Color,
	accent: Color,
	success: Color,
	warning: Color,
	err: Color,
	text: Color,
	text_dim: Color,
};

/// Parse a hex color string like "#FF6600" into a Color.
/// Accepts both uppercase and lowercase hex digits.
/// Returns error.InvalidColor if the format is wrong (not 7 chars, missing #).
/// Returns error.InvalidCharacter if hex digits are invalid.
pub fn parseHexColor(hex: []const u8) !Color {
	if (hex.len != 7) return error.InvalidColor;
	if (hex[0] != '#') return error.InvalidColor;

	const r = std.fmt.parseUnsigned(u8, hex[1..3], 16) catch return error.InvalidCharacter;
	const g = std.fmt.parseUnsigned(u8, hex[3..5], 16) catch return error.InvalidCharacter;
	const b = std.fmt.parseUnsigned(u8, hex[5..7], 16) catch return error.InvalidCharacter;

	return Color{ .r = r, .g = g, .b = b };
}

// ── Theme Presets ──────────────────────────────────────────────────────

/// Neon orange theme — cyberpunk with orange primary and purple accent.
pub const neon_orange = Theme{
	.background = Color{ .r = 0x0D, .g = 0x0D, .b = 0x0D },
	.primary = Color{ .r = 0xFF, .g = 0x66, .b = 0x00 },
	.accent = Color{ .r = 0x99, .g = 0x33, .b = 0xFF },
	.success = Color{ .r = 0x00, .g = 0xFF, .b = 0x66 },
	.warning = Color{ .r = 0xFF, .g = 0xCC, .b = 0x00 },
	.err = Color{ .r = 0xFF, .g = 0x33, .b = 0x33 },
	.text = Color{ .r = 0xE0, .g = 0xE0, .b = 0xE0 },
	.text_dim = Color{ .r = 0x80, .g = 0x80, .b = 0x80 },
};

/// Neon cyan theme — cyberpunk with cyan primary and magenta accent.
pub const neon_cyan = Theme{
	.background = Color{ .r = 0x0D, .g = 0x0D, .b = 0x0D },
	.primary = Color{ .r = 0x00, .g = 0xFF, .b = 0xFF },
	.accent = Color{ .r = 0xFF, .g = 0x00, .b = 0xFF },
	.success = Color{ .r = 0x00, .g = 0xFF, .b = 0x66 },
	.warning = Color{ .r = 0xFF, .g = 0xCC, .b = 0x00 },
	.err = Color{ .r = 0xFF, .g = 0x33, .b = 0x33 },
	.text = Color{ .r = 0xE0, .g = 0xE0, .b = 0xE0 },
	.text_dim = Color{ .r = 0x80, .g = 0x80, .b = 0x80 },
};

/// Look up a named preset theme.
fn getPreset(name: []const u8) ?Theme {
	if (std.mem.eql(u8, name, "neon_orange")) return neon_orange;
	if (std.mem.eql(u8, name, "neon_cyan")) return neon_cyan;
	return null;
}

/// Resolve a theme from config. Named presets are returned directly;
/// "custom" parses hex colors from cfg.custom_theme fields (falling
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

/// Build a theme from CustomTheme, parsing each provided hex string
/// and falling back to neon_orange for any null field.
fn resolveCustomTheme(ct: config.CustomTheme) !Theme {
	return Theme{
		.background = if (ct.background) |hex| try parseHexColor(hex) else neon_orange.background,
		.primary = if (ct.primary) |hex| try parseHexColor(hex) else neon_orange.primary,
		.accent = if (ct.accent) |hex| try parseHexColor(hex) else neon_orange.accent,
		.success = if (ct.success) |hex| try parseHexColor(hex) else neon_orange.success,
		.warning = if (ct.warning) |hex| try parseHexColor(hex) else neon_orange.warning,
		.err = if (ct.err) |hex| try parseHexColor(hex) else neon_orange.err,
		.text = if (ct.text) |hex| try parseHexColor(hex) else neon_orange.text,
		.text_dim = if (ct.text_dim) |hex| try parseHexColor(hex) else neon_orange.text_dim,
	};
}

// ── Tests ──────────────────────────────────────────────────────────────

test "parseHexColor valid uppercase" {
	const c = try parseHexColor("#FF6600");
	try std.testing.expectEqual(@as(u8, 0xFF), c.r);
	try std.testing.expectEqual(@as(u8, 0x66), c.g);
	try std.testing.expectEqual(@as(u8, 0x00), c.b);
	try std.testing.expectEqual(@as(u8, 255), c.a);
}

test "parseHexColor valid lowercase" {
	const c = try parseHexColor("#00ffff");
	try std.testing.expectEqual(@as(u8, 0), c.r);
	try std.testing.expectEqual(@as(u8, 0xFF), c.g);
	try std.testing.expectEqual(@as(u8, 0xFF), c.b);
}

test "parseHexColor invalid format - missing hash" {
	const result = parseHexColor("FF6600");
	try std.testing.expectError(error.InvalidColor, result);
}

test "parseHexColor invalid format - too short" {
	const result = parseHexColor("#FFF");
	try std.testing.expectError(error.InvalidColor, result);
}

test "parseHexColor invalid format - too long" {
	const result = parseHexColor("#FF660000");
	try std.testing.expectError(error.InvalidColor, result);
}

test "parseHexColor invalid hex digits" {
	const result = parseHexColor("#GGHHII");
	try std.testing.expectError(error.InvalidCharacter, result);
}

test "resolveTheme neon_orange preset" {
	const cfg = config.Config{ .theme = "neon_orange" };
	const theme = try resolveTheme(cfg);
	try std.testing.expectEqual(@as(u8, 0xFF), theme.primary.r);
	try std.testing.expectEqual(@as(u8, 0x66), theme.primary.g);
	try std.testing.expectEqual(@as(u8, 0x00), theme.primary.b);
}

test "resolveTheme neon_cyan preset" {
	const cfg = config.Config{ .theme = "neon_cyan" };
	const theme = try resolveTheme(cfg);
	try std.testing.expectEqual(@as(u8, 0x00), theme.primary.r);
	try std.testing.expectEqual(@as(u8, 0xFF), theme.primary.g);
	try std.testing.expectEqual(@as(u8, 0xFF), theme.primary.b);
}

test "resolveTheme unknown preset" {
	const cfg = config.Config{ .theme = "nonexistent" };
	const result = resolveTheme(cfg);
	try std.testing.expectError(error.UnknownTheme, result);
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
	try std.testing.expectEqual(@as(u8, 0x22), theme.primary.r);
	try std.testing.expectEqual(@as(u8, 0xAA), theme.primary.g);
	try std.testing.expectEqual(@as(u8, 0xFF), theme.primary.b);
	try std.testing.expectEqual(@as(u8, 0xFF), theme.text.r);
}

test "resolveTheme custom with partial fields falls back to neon_orange" {
	const cfg = config.Config{
		.theme = "custom",
		.custom_theme = .{
			.primary = "#00CCFF",
		},
	};
	const theme = try resolveTheme(cfg);
	// Custom primary
	try std.testing.expectEqual(@as(u8, 0x00), theme.primary.r);
	try std.testing.expectEqual(@as(u8, 0xCC), theme.primary.g);
	try std.testing.expectEqual(@as(u8, 0xFF), theme.primary.b);
	// Fallback background from neon_orange
	try std.testing.expect(theme.background.eql(neon_orange.background));
}

test "resolveTheme custom with invalid hex returns error" {
	const cfg = config.Config{
		.theme = "custom",
		.custom_theme = .{
			.primary = "not-a-color",
		},
	};
	const result = resolveTheme(cfg);
	try std.testing.expectError(error.InvalidColor, result);
}

test "neon_orange preset has expected accent" {
	try std.testing.expectEqual(@as(u8, 0x99), neon_orange.accent.r);
	try std.testing.expectEqual(@as(u8, 0x33), neon_orange.accent.g);
	try std.testing.expectEqual(@as(u8, 0xFF), neon_orange.accent.b);
}

test "neon_cyan preset has expected accent (magenta)" {
	try std.testing.expectEqual(@as(u8, 0xFF), neon_cyan.accent.r);
	try std.testing.expectEqual(@as(u8, 0x00), neon_cyan.accent.g);
	try std.testing.expectEqual(@as(u8, 0xFF), neon_cyan.accent.b);
}

test "Color.eql" {
	const a = Color{ .r = 1, .g = 2, .b = 3, .a = 4 };
	const b = Color{ .r = 1, .g = 2, .b = 3, .a = 4 };
	const c = Color{ .r = 1, .g = 2, .b = 3, .a = 5 };
	try std.testing.expect(a.eql(b));
	try std.testing.expect(!a.eql(c));
}
