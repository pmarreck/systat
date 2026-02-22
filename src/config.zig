const std = @import("std");
const testing = std.testing;

pub const ModuleConfig = struct {
	priority: u8 = 0,
	enabled: bool = true,
};

pub const PingModuleConfig = struct {
	priority: u8 = 0,
	enabled: bool = true,
	hosts: []const []const u8 = &default_hosts,
	ping_interval_ms: u32 = 2000,

	const default_hosts = [_][]const u8{ "google.com", "github.com", "cloudflare.com" };
};

/// Default theme color palette as hex strings (non-optional).
pub const ThemeColors = struct {
	background: []const u8 = "#1a1a2e",
	primary: []const u8 = "#ff6600",
	accent: []const u8 = "#9933ff",
	success: []const u8 = "#00ff88",
	warning: []const u8 = "#ffaa00",
	err: []const u8 = "#ff3366",
	text: []const u8 = "#e0e0e0",
	text_dim: []const u8 = "#888888",
};

/// Custom theme color overrides, all as hex strings like "#FF6600".
/// Used when Config.theme == "custom". Null fields fall back to preset defaults.
pub const CustomTheme = struct {
	background: ?[]const u8 = null,
	primary: ?[]const u8 = null,
	accent: ?[]const u8 = null,
	success: ?[]const u8 = null,
	warning: ?[]const u8 = null,
	err: ?[]const u8 = null,
	text: ?[]const u8 = null,
	text_dim: ?[]const u8 = null,
};

pub const Config = struct {
	update_interval_ms: u32 = 1000,
	process_count: u16 = 15,
	theme: []const u8 = "neon_orange",
	cpu_hogs: ModuleConfig = .{},
	mem_hogs: ModuleConfig = .{},
	cpu_graph: ModuleConfig = .{},
	ping_monitor: PingModuleConfig = .{},
	/// Custom theme color overrides (only used when theme == "custom")
	custom_theme: CustomTheme = .{},
};

pub fn defaultConfig() Config {
	return .{};
}

pub fn parseConfig(source: []const u8) !Config {
	if (source.len == 0) return defaultConfig();
	// TOML parsing will be integrated later via sam701/zig-toml.
	// For now, reject non-empty input so callers know parsing isn't wired up yet.
	return error.TomlNotYetIntegrated;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "defaultConfig has correct update_interval_ms" {
	const cfg = defaultConfig();
	try testing.expectEqual(@as(u32, 1000), cfg.update_interval_ms);
}

test "defaultConfig has correct process_count" {
	const cfg = defaultConfig();
	try testing.expectEqual(@as(u16, 15), cfg.process_count);
}

test "defaultConfig has neon_orange theme" {
	const cfg = defaultConfig();
	try testing.expectEqualStrings("neon_orange", cfg.theme);
}

test "parseConfig returns defaults for empty input" {
	const cfg = try parseConfig("");
	try testing.expectEqual(@as(u32, 1000), cfg.update_interval_ms);
	try testing.expectEqual(@as(u16, 15), cfg.process_count);
	try testing.expectEqualStrings("neon_orange", cfg.theme);
}

test "default ping hosts are google, github, cloudflare" {
	const cfg = defaultConfig();
	const hosts = cfg.ping_monitor.hosts;
	try testing.expectEqual(@as(usize, 3), hosts.len);
	try testing.expectEqualStrings("google.com", hosts[0]);
	try testing.expectEqualStrings("github.com", hosts[1]);
	try testing.expectEqualStrings("cloudflare.com", hosts[2]);
}

test "default ping interval is 2000ms" {
	const cfg = defaultConfig();
	try testing.expectEqual(@as(u32, 2000), cfg.ping_monitor.ping_interval_ms);
}

test "default module configs have enabled=true and priority=0" {
	const cfg = defaultConfig();

	// cpu_hogs
	try testing.expect(cfg.cpu_hogs.enabled);
	try testing.expectEqual(@as(u8, 0), cfg.cpu_hogs.priority);

	// mem_hogs
	try testing.expect(cfg.mem_hogs.enabled);
	try testing.expectEqual(@as(u8, 0), cfg.mem_hogs.priority);

	// cpu_graph
	try testing.expect(cfg.cpu_graph.enabled);
	try testing.expectEqual(@as(u8, 0), cfg.cpu_graph.priority);

	// ping_monitor
	try testing.expect(cfg.ping_monitor.enabled);
	try testing.expectEqual(@as(u8, 0), cfg.ping_monitor.priority);
}

test "default custom_theme has all null fields" {
	const cfg = defaultConfig();
	try testing.expect(cfg.custom_theme.primary == null);
	try testing.expect(cfg.custom_theme.background == null);
	try testing.expect(cfg.custom_theme.accent == null);
	try testing.expect(cfg.custom_theme.success == null);
	try testing.expect(cfg.custom_theme.warning == null);
	try testing.expect(cfg.custom_theme.err == null);
	try testing.expect(cfg.custom_theme.text == null);
	try testing.expect(cfg.custom_theme.text_dim == null);
}

test "parseConfig returns error for non-empty input" {
	const result = parseConfig("some_key = 42");
	try testing.expectError(error.TomlNotYetIntegrated, result);
}
