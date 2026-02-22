const std = @import("std");
const toml = @import("toml");
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

/// Parsed config result. Owns the arena that backs any TOML-allocated strings.
/// Caller must call deinit() when done, or pass ownership to AppState.
pub const ParseResult = struct {
	config: Config,
	/// Arena backing TOML-parsed string data. Null for default configs.
	arena: ?std.heap.ArenaAllocator = null,

	pub fn deinit(self: *ParseResult) void {
		if (self.arena) |*a| a.deinit();
		self.arena = null;
	}
};

pub fn defaultConfig() Config {
	return .{};
}

/// Parse a TOML config string. Returns a ParseResult that owns string data.
/// For empty input, returns defaults (no arena allocation).
pub fn parseConfig(allocator: std.mem.Allocator, source: []const u8) !ParseResult {
	if (source.len == 0) return .{ .config = defaultConfig() };

	var parser = toml.Parser(Config).init(allocator);
	defer parser.deinit();

	const result = parser.parseString(source) catch |err| {
		// Map TOML errors to a single config parse error
		return switch (err) {
			error.UnexpectedToken, error.InvalidCharacter => error.ConfigParseError,
			else => err,
		};
	};

	// Transfer arena ownership — the Config's string fields point into it
	return .{
		.config = result.value,
		.arena = result.arena,
	};
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
	const pr = try parseConfig(testing.allocator, "");
	try testing.expectEqual(@as(u32, 1000), pr.config.update_interval_ms);
	try testing.expectEqual(@as(u16, 15), pr.config.process_count);
	try testing.expectEqualStrings("neon_orange", pr.config.theme);
	try testing.expect(pr.arena == null);
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

test "parseConfig parses basic TOML" {
	const source =
		\\update_interval_ms = 500
		\\process_count = 10
		\\theme = "neon_cyan"
	;
	var pr = try parseConfig(testing.allocator, source);
	defer pr.deinit();

	try testing.expectEqual(@as(u32, 500), pr.config.update_interval_ms);
	try testing.expectEqual(@as(u16, 10), pr.config.process_count);
	try testing.expectEqualStrings("neon_cyan", pr.config.theme);
	try testing.expect(pr.arena != null);
}

test "parseConfig preserves defaults for omitted fields" {
	const source =
		\\theme = "neon_cyan"
	;
	var pr = try parseConfig(testing.allocator, source);
	defer pr.deinit();

	try testing.expectEqualStrings("neon_cyan", pr.config.theme);
	// Omitted fields use defaults
	try testing.expectEqual(@as(u32, 1000), pr.config.update_interval_ms);
	try testing.expectEqual(@as(u16, 15), pr.config.process_count);
	try testing.expect(pr.config.cpu_hogs.enabled);
}

test "parseConfig parses module tables" {
	const source =
		\\[cpu_hogs]
		\\enabled = false
		\\priority = 5
		\\
		\\[mem_hogs]
		\\priority = 3
	;
	var pr = try parseConfig(testing.allocator, source);
	defer pr.deinit();

	try testing.expect(!pr.config.cpu_hogs.enabled);
	try testing.expectEqual(@as(u8, 5), pr.config.cpu_hogs.priority);
	try testing.expectEqual(@as(u8, 3), pr.config.mem_hogs.priority);
	try testing.expect(pr.config.mem_hogs.enabled); // default
}

test "parseConfig parses ping_monitor hosts" {
	const source =
		\\[ping_monitor]
		\\hosts = ["1.1.1.1", "8.8.8.8"]
		\\ping_interval_ms = 5000
	;
	var pr = try parseConfig(testing.allocator, source);
	defer pr.deinit();

	try testing.expectEqual(@as(usize, 2), pr.config.ping_monitor.hosts.len);
	try testing.expectEqualStrings("1.1.1.1", pr.config.ping_monitor.hosts[0]);
	try testing.expectEqualStrings("8.8.8.8", pr.config.ping_monitor.hosts[1]);
	try testing.expectEqual(@as(u32, 5000), pr.config.ping_monitor.ping_interval_ms);
}

test "parseConfig parses custom_theme" {
	const source =
		\\theme = "custom"
		\\
		\\[custom_theme]
		\\primary = "#00FFAA"
		\\background = "#111111"
	;
	var pr = try parseConfig(testing.allocator, source);
	defer pr.deinit();

	try testing.expectEqualStrings("custom", pr.config.theme);
	try testing.expectEqualStrings("#00FFAA", pr.config.custom_theme.primary.?);
	try testing.expectEqualStrings("#111111", pr.config.custom_theme.background.?);
	try testing.expect(pr.config.custom_theme.accent == null); // not specified
}

test "parseConfig full config round-trip" {
	const source =
		\\update_interval_ms = 1000
		\\process_count = 15
		\\theme = "neon_orange"
		\\
		\\[cpu_hogs]
		\\enabled = true
		\\priority = 0
		\\
		\\[mem_hogs]
		\\enabled = true
		\\priority = 0
		\\
		\\[cpu_graph]
		\\enabled = true
		\\priority = 0
		\\
		\\[ping_monitor]
		\\enabled = true
		\\priority = 0
		\\hosts = ["google.com", "github.com", "cloudflare.com"]
		\\ping_interval_ms = 2000
	;
	var pr = try parseConfig(testing.allocator, source);
	defer pr.deinit();

	try testing.expectEqual(@as(u32, 1000), pr.config.update_interval_ms);
	try testing.expectEqual(@as(u16, 15), pr.config.process_count);
	try testing.expectEqualStrings("neon_orange", pr.config.theme);
	try testing.expect(pr.config.cpu_hogs.enabled);
	try testing.expectEqual(@as(usize, 3), pr.config.ping_monitor.hosts.len);
}

test "parseConfig deinit frees arena" {
	const source =
		\\theme = "neon_cyan"
	;
	var pr = try parseConfig(testing.allocator, source);
	try testing.expect(pr.arena != null);
	pr.deinit();
	try testing.expect(pr.arena == null);
	// testing.allocator will detect leaks if arena wasn't freed
}
