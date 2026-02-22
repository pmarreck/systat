const std = @import("std");

/// Metadata describing a module's identity and layout preferences.
pub const ModuleInfo = struct {
	id: []const u8,
	display_name: []const u8,
	default_priority: u8,
	min_width: u16,
	min_height: u16,
	preferred_width: u16,
	preferred_height: u16,
};

/// Vtable-style module interface. Concrete module types implement `moduleInfo`,
/// `moduleUpdate`, `moduleRender`, and `moduleDeinit` methods, then use
/// `Module.from(&concrete)` to obtain a type-erased handle that dispatches
/// through generated function pointers — the same pattern used by
/// `std.mem.Allocator`.
pub const Module = struct {
	ctx: *anyopaque,
	infoFn: *const fn (ctx: *anyopaque) ModuleInfo,
	updateFn: *const fn (ctx: *anyopaque) void,
	renderFn: *const fn (ctx: *anyopaque) void,
	deinitFn: *const fn (ctx: *anyopaque) void,

	/// Return the module's static metadata.
	pub fn info(self: Module) ModuleInfo {
		return self.infoFn(self.ctx);
	}

	/// Poll / refresh the module's data.
	pub fn update(self: Module) void {
		self.updateFn(self.ctx);
	}

	/// Draw the module's UI for the current frame.
	pub fn render(self: Module) void {
		self.renderFn(self.ctx);
	}

	/// Release resources owned by the module.
	pub fn deinit(self: Module) void {
		self.deinitFn(self.ctx);
	}

	/// Construct a `Module` from a pointer to any concrete type that
	/// implements `moduleInfo`, `moduleUpdate`, `moduleRender`, and
	/// `moduleDeinit`.
	pub fn from(ptr: anytype) Module {
		const Ptr = @TypeOf(ptr);
		const impl = struct {
			fn infoFn(ctx: *anyopaque) ModuleInfo {
				const self: Ptr = @ptrCast(@alignCast(ctx));
				return self.moduleInfo();
			}
			fn updateFn(ctx: *anyopaque) void {
				const self: Ptr = @ptrCast(@alignCast(ctx));
				self.moduleUpdate();
			}
			fn renderFn(ctx: *anyopaque) void {
				const self: Ptr = @ptrCast(@alignCast(ctx));
				self.moduleRender();
			}
			fn deinitFn(ctx: *anyopaque) void {
				const self: Ptr = @ptrCast(@alignCast(ctx));
				self.moduleDeinit();
			}
		};

		return .{
			.ctx = @ptrCast(ptr),
			.infoFn = impl.infoFn,
			.updateFn = impl.updateFn,
			.renderFn = impl.renderFn,
			.deinitFn = impl.deinitFn,
		};
	}
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const MockModule = struct {
	update_count: u32 = 0,
	render_count: u32 = 0,
	deinited: bool = false,

	const mock_info: ModuleInfo = .{
		.id = "mock",
		.display_name = "Mock Module",
		.default_priority = 42,
		.min_width = 100,
		.min_height = 80,
		.preferred_width = 300,
		.preferred_height = 200,
	};

	pub fn moduleInfo(self: *MockModule) ModuleInfo {
		_ = self;
		return mock_info;
	}

	pub fn moduleUpdate(self: *MockModule) void {
		self.update_count += 1;
	}

	pub fn moduleRender(self: *MockModule) void {
		self.render_count += 1;
	}

	pub fn moduleDeinit(self: *MockModule) void {
		self.deinited = true;
	}
};

test "Module.from produces a valid Module" {
	var mock = MockModule{};
	const m = Module.from(&mock);

	// ctx should point back to our mock
	try testing.expect(m.ctx == @as(*anyopaque, @ptrCast(&mock)));
}

test "Module.info dispatches to concrete type" {
	var mock = MockModule{};
	const m = Module.from(&mock);
	const i = m.info();

	try testing.expectEqualStrings("mock", i.id);
	try testing.expectEqualStrings("Mock Module", i.display_name);
	try testing.expectEqual(@as(u8, 42), i.default_priority);
	try testing.expectEqual(@as(u16, 100), i.min_width);
	try testing.expectEqual(@as(u16, 80), i.min_height);
	try testing.expectEqual(@as(u16, 300), i.preferred_width);
	try testing.expectEqual(@as(u16, 200), i.preferred_height);
}

test "Module.update increments counter" {
	var mock = MockModule{};
	const m = Module.from(&mock);

	try testing.expectEqual(@as(u32, 0), mock.update_count);
	m.update();
	try testing.expectEqual(@as(u32, 1), mock.update_count);
	m.update();
	m.update();
	try testing.expectEqual(@as(u32, 3), mock.update_count);
}

test "Module.render increments counter" {
	var mock = MockModule{};
	const m = Module.from(&mock);

	try testing.expectEqual(@as(u32, 0), mock.render_count);
	m.render();
	try testing.expectEqual(@as(u32, 1), mock.render_count);
	m.render();
	try testing.expectEqual(@as(u32, 2), mock.render_count);
}

test "Module.deinit sets flag" {
	var mock = MockModule{};
	const m = Module.from(&mock);

	try testing.expect(!mock.deinited);
	m.deinit();
	try testing.expect(mock.deinited);
}

test "Module vtable works with multiple instances independently" {
	var a = MockModule{};
	var b = MockModule{};
	const ma = Module.from(&a);
	const mb = Module.from(&b);

	ma.update();
	ma.update();
	mb.update();

	try testing.expectEqual(@as(u32, 2), a.update_count);
	try testing.expectEqual(@as(u32, 1), b.update_count);

	ma.render();
	mb.render();
	mb.render();
	mb.render();

	try testing.expectEqual(@as(u32, 1), a.render_count);
	try testing.expectEqual(@as(u32, 3), b.render_count);
}
