//! Application state: owns config, modules, stats interface, and theme.
//! Central coordination point between all subsystems.

const std = @import("std");
const dvui = @import("dvui");
const config = @import("config.zig");
const theme_mod = @import("theme.zig");
const mod = @import("module.zig");
const layout = @import("layout.zig");
const stats = @import("platform/stats.zig");
const FileWatcher = @import("file_watcher.zig").FileWatcher;
const CpuHogs = @import("modules/cpu_hogs.zig").CpuHogs;
const MemHogs = @import("modules/mem_hogs.zig").MemHogs;
const CpuGraph = @import("modules/cpu_graph.zig").CpuGraph;
const PingMonitor = @import("modules/ping_monitor.zig").PingMonitor;
const runtime = @import("runtime.zig");

pub const MODULE_COUNT = 4;

pub const CONFIG_PATH = "config.toml";

pub const AppState = struct {
	allocator: std.mem.Allocator,
	cfg: config.Config,
	theme: dvui.Theme,

	// Concrete module instances
	cpu_hogs: CpuHogs,
	mem_hogs: MemHogs,
	cpu_graph: CpuGraph,
	ping_monitor: PingMonitor,

	// Config hot-reload
	config_watcher: FileWatcher,
	config_arena: ?std.heap.ArenaAllocator = null, // owns TOML-parsed string data
	last_config_status: ?[]const u8 = null,
	config_status_is_error: bool = false,

	pub fn init(allocator: std.mem.Allocator, stats_iface: stats.SystemStats, cfg: config.Config) !AppState {
		return .{
			.allocator = allocator,
			.cfg = cfg,
			.theme = try theme_mod.resolveTheme(cfg),
			.cpu_hogs = CpuHogs.init(allocator, stats_iface, cfg.process_count),
			.mem_hogs = MemHogs.init(allocator, stats_iface, cfg.process_count),
			.cpu_graph = CpuGraph.init(stats_iface),
			.ping_monitor = PingMonitor.initWithInterval(stats_iface, cfg.ping_monitor.hosts, cfg.ping_monitor.ping_interval_ms),
			.config_watcher = FileWatcher.init(CONFIG_PATH, 2000),
		};
	}

	pub fn deinit(self: *AppState) void {
		self.cpu_hogs.deinit();
		self.mem_hogs.deinit();
		if (self.config_arena) |*a| a.deinit();
		// cpu_graph and ping_monitor use inline ring buffers — nothing to free
	}

	/// Check if config file changed and attempt to reload.
	/// Returns a status message if there's something to report.
	pub fn checkConfigReload(self: *AppState) void {
		if (!self.config_watcher.check()) return;

		// File changed — try to read and parse
		const source = std.Io.Dir.cwd().readFileAlloc(runtime.io(), CONFIG_PATH, self.allocator, .limited(64 * 1024)) catch |err| {
			self.last_config_status = switch (err) {
				error.FileNotFound => "Config file removed",
				else => "Config read error",
			};
			self.config_status_is_error = err != error.FileNotFound;
			return;
		};
		defer self.allocator.free(source);

		var pr = config.parseConfig(self.allocator, source) catch {
			self.last_config_status = "Config parse error";
			self.config_status_is_error = true;
			return;
		};

		// Apply new theme if it changed
		if (!std.mem.eql(u8, pr.config.theme, self.cfg.theme)) {
			if (theme_mod.resolveTheme(pr.config)) |new_theme| {
				self.theme = new_theme;
			} else |_| {
				pr.deinit();
				self.last_config_status = "Invalid theme in config";
				self.config_status_is_error = true;
				return;
			}
		}

		// Free old config arena before replacing
		if (self.config_arena) |*a| a.deinit();
		self.config_arena = pr.arena;
		self.cfg = pr.config;
		self.last_config_status = "Config reloaded";
		self.config_status_is_error = false;
	}

	/// Update all modules (poll stats, aggregate data).
	pub fn updateAll(self: *AppState) void {
		self.cpu_hogs.update();
		self.mem_hogs.update();
		self.cpu_graph.update();
		self.ping_monitor.update();
	}

	/// Get ModuleInfo for each module (for layout computation).
	pub fn getModuleInfos(self: *AppState) [MODULE_COUNT]mod.ModuleInfo {
		return .{
			self.cpu_hogs.moduleInfo(),
			self.mem_hogs.moduleInfo(),
			self.cpu_graph.moduleInfo(),
			self.ping_monitor.moduleInfo(),
		};
	}

	/// Get priority array matching getModuleInfos order.
	pub fn getModulePriorities(_: *AppState) [MODULE_COUNT]u8 {
		return .{ 3, 4, 1, 2 }; // cpu_hogs, mem_hogs, cpu_graph, ping_monitor
	}

	/// Compute layout for the current window size.
	pub fn computeLayout(self: *AppState, window_w: u16, window_h: u16) ![]layout.PlacedModule {
		const infos = self.getModuleInfos();
		const priorities = self.getModulePriorities();
		return layout.computeLayout(self.allocator, window_w, window_h, &infos, &priorities);
	}
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const mock = @import("platform/mock.zig");

test "AppState init and deinit" {
	var m = mock.MockStats{};
	const iface = m.interface();
	var app = try AppState.init(testing.allocator, iface, config.defaultConfig());
	defer app.deinit();

	try testing.expectEqualStrings("neon_orange", app.cfg.theme);
	try testing.expectEqual(@as(u8, 0xFF), app.theme.focus.r); // orange primary
}

test "AppState updateAll populates modules" {
	var m = mock.MockStats{};
	const iface = m.interface();
	var app = try AppState.init(testing.allocator, iface, config.defaultConfig());
	defer app.deinit();

	app.updateAll();

	try testing.expect(app.cpu_hogs.aggregated != null);
	try testing.expect(app.mem_hogs.aggregated != null);
	try testing.expectEqual(@as(usize, 1), app.cpu_graph.dataPointCount());
}

test "AppState getModuleInfos returns 4 modules" {
	var m = mock.MockStats{};
	const iface = m.interface();
	var app = try AppState.init(testing.allocator, iface, config.defaultConfig());
	defer app.deinit();

	const infos = app.getModuleInfos();
	try testing.expectEqual(@as(usize, 4), infos.len);
	try testing.expectEqualStrings("cpu_hogs", infos[0].id);
	try testing.expectEqualStrings("mem_hogs", infos[1].id);
	try testing.expectEqualStrings("cpu_graph", infos[2].id);
	try testing.expectEqualStrings("ping_monitor", infos[3].id);
}

test "AppState computeLayout places modules" {
	var m = mock.MockStats{};
	const iface = m.interface();
	var app = try AppState.init(testing.allocator, iface, config.defaultConfig());
	defer app.deinit();

	const placed = try app.computeLayout(900, 700);
	defer testing.allocator.free(placed);

	try testing.expect(placed.len > 0);
	try testing.expect(placed.len <= MODULE_COUNT);
}

test "AppState double updateAll no leak" {
	var m = mock.MockStats{};
	const iface = m.interface();
	var app = try AppState.init(testing.allocator, iface, config.defaultConfig());
	defer app.deinit();

	app.updateAll();
	app.updateAll();

	try testing.expect(app.cpu_hogs.aggregated != null);
	try testing.expect(app.mem_hogs.aggregated != null);
}

test "AppState init with bad theme returns error" {
	var m = mock.MockStats{};
	const iface = m.interface();
	var cfg = config.defaultConfig();
	cfg.theme = "nonexistent";

	const result = AppState.init(testing.allocator, iface, cfg);
	try testing.expectError(error.UnknownTheme, result);
}
