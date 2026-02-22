//! File watcher — polls file modification time to detect changes.
//! Simple and cross-platform. Can be upgraded to kqueue/inotify later.

const std = @import("std");

pub const FileWatcher = struct {
	path: []const u8,
	last_mtime_ns: i128 = 0,
	last_check_ns: i128 = 0,
	check_interval_ns: i128,
	file_exists: bool = false,

	/// Create a watcher for the given path.
	/// `check_interval_ms` controls how often the file is polled (0 = every call).
	pub fn init(path: []const u8, check_interval_ms: u32) FileWatcher {
		var self = FileWatcher{
			.path = path,
			.check_interval_ns = @as(i128, check_interval_ms) * 1_000_000,
		};
		// Record initial mtime so first check doesn't fire
		self.updateMtime();
		return self;
	}

	/// Check if the file has changed since last check.
	/// Returns true if the file was modified, false otherwise.
	/// Respects the check interval — returns false if called too soon.
	pub fn check(self: *FileWatcher) bool {
		const now = std.time.nanoTimestamp();
		if (now - self.last_check_ns < self.check_interval_ns) return false;
		self.last_check_ns = now;

		const stat = std.fs.cwd().statFile(self.path) catch |err| {
			switch (err) {
				error.FileNotFound => {
					// File doesn't exist (yet or anymore)
					if (self.file_exists) {
						self.file_exists = false;
						return true; // File was deleted
					}
					return false;
				},
				else => return false,
			}
		};

		const mtime_ns = stat.mtime;
		self.file_exists = true;

		if (mtime_ns != self.last_mtime_ns and self.last_mtime_ns != 0) {
			self.last_mtime_ns = mtime_ns;
			return true;
		}

		if (self.last_mtime_ns == 0) {
			self.last_mtime_ns = mtime_ns;
		}

		return false;
	}

	fn updateMtime(self: *FileWatcher) void {
		const stat = std.fs.cwd().statFile(self.path) catch {
			return;
		};
		self.last_mtime_ns = stat.mtime;
		self.file_exists = true;
	}
};

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "FileWatcher init with nonexistent file" {
	const watcher = FileWatcher.init("nonexistent_file_for_test.toml", 0);
	try testing.expect(!watcher.file_exists);
	try testing.expectEqual(@as(i128, 0), watcher.last_mtime_ns);
}

test "FileWatcher check returns false for nonexistent file" {
	var watcher = FileWatcher.init("nonexistent_file_for_test.toml", 0);
	const changed = watcher.check();
	try testing.expect(!changed);
}

test "FileWatcher check_interval_ns computed correctly" {
	const watcher = FileWatcher.init("test.toml", 2000);
	try testing.expectEqual(@as(i128, 2_000_000_000), watcher.check_interval_ns);
}
