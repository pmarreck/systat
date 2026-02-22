const std = @import("std");
const dvui = @import("dvui");

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 900.0, .h = 700.0 },
            .min_size = .{ .w = 400.0, .h = 300.0 },
            .title = "systat",
        },
    },
    .frameFn = appFrame,
    .initFn = appInit,
    .deinitFn = appDeinit,
};

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

pub fn appInit(win: *dvui.Window) !void {
    _ = win;
    if (comptime @import("builtin").mode == .Debug) {
        std.debug.print("\x1b[33mDEBUG BUILD\x1b[0m\n", .{});
    }
}

pub fn appDeinit() void {}

pub fn appFrame() !dvui.App.Result {
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    dvui.label(@src(), "systat - System Monitor", .{}, .{});

    if (dvui.button(@src(), "Quit", .{}, .{})) {
        return .close;
    }

    return .ok;
}

test "basic frame" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    try dvui.testing.settle(appFrame);
}
