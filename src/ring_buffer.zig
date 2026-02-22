const std = @import("std");
const testing = std.testing;

/// A generic ring buffer with comptime-known capacity.
/// Uses a backing array on the struct — no allocator needed.
/// `get(0)` returns the oldest item; `get(len()-1)` returns the newest.
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
	comptime {
		if (capacity == 0) @compileError("RingBuffer capacity must be > 0");
	}
	return struct {
		const Self = @This();

		buffer: [capacity]T = undefined,
		head: usize = 0, // next write position
		count: usize = 0, // current fill level

		/// Returns a zero-initialized instance.
		pub fn init() Self {
			return .{};
		}

		/// Add an item. Overwrites the oldest when full.
		pub fn push(self: *Self, item: T) void {
			self.buffer[self.head] = item;
			self.head = (self.head + 1) % capacity;
			if (self.count < capacity) {
				self.count += 1;
			}
		}

		/// Current number of items stored.
		pub fn len(self: *const Self) usize {
			return self.count;
		}

		/// Reset to empty.
		pub fn clear(self: *Self) void {
			self.count = 0;
			self.head = 0;
		}

		/// Get item at logical index (0 = oldest, len()-1 = newest).
		/// Panics if index >= len().
		pub fn get(self: *const Self, index: usize) T {
			if (index >= self.count) {
				@panic("RingBuffer.get: index out of bounds");
			}
			// The oldest item sits at (head - count) mod capacity.
			// So logical index i maps to buffer[(head - count + i) mod capacity].
			const start = (self.head + capacity - self.count) % capacity;
			return self.buffer[(start + index) % capacity];
		}

		/// Copy items in chronological order (oldest first) to a caller-provided buffer.
		/// Returns a slice of out_buf with the copied items.
		pub fn toSlice(self: *const Self, out_buf: []T) []const T {
			const n = @min(self.count, out_buf.len);
			const start = (self.head + capacity - self.count) % capacity;
			for (0..n) |i| {
				out_buf[i] = self.buffer[(start + i) % capacity];
			}
			return out_buf[0..n];
		}
	};
}

// ==================== TESTS ====================

test "push and read back" {
	var rb = RingBuffer(i32, 5).init();
	rb.push(10);
	rb.push(20);
	rb.push(30);

	try testing.expectEqual(@as(usize, 3), rb.len());
	try testing.expectEqual(@as(i32, 10), rb.get(0));
	try testing.expectEqual(@as(i32, 20), rb.get(1));
	try testing.expectEqual(@as(i32, 30), rb.get(2));
}

test "overflow wraps around" {
	var rb = RingBuffer(i32, 3).init();
	rb.push(1);
	rb.push(2);
	rb.push(3);
	rb.push(4); // overwrites 1

	try testing.expectEqual(@as(usize, 3), rb.len());
	// oldest is now 2, then 3, then 4
	try testing.expectEqual(@as(i32, 2), rb.get(0));
	try testing.expectEqual(@as(i32, 3), rb.get(1));
	try testing.expectEqual(@as(i32, 4), rb.get(2));
}

test "empty buffer" {
	var rb = RingBuffer(f64, 10).init();
	try testing.expectEqual(@as(usize, 0), rb.len());
}

test "len tracks correctly" {
	var rb = RingBuffer(u8, 3).init();
	try testing.expectEqual(@as(usize, 0), rb.len());

	rb.push(1);
	try testing.expectEqual(@as(usize, 1), rb.len());

	rb.push(2);
	try testing.expectEqual(@as(usize, 2), rb.len());

	rb.push(3);
	try testing.expectEqual(@as(usize, 3), rb.len());

	// overflow — len stays capped at capacity
	rb.push(4);
	try testing.expectEqual(@as(usize, 3), rb.len());

	rb.push(5);
	try testing.expectEqual(@as(usize, 3), rb.len());
}

test "clear resets state" {
	var rb = RingBuffer(i32, 4).init();
	rb.push(100);
	rb.push(200);
	rb.push(300);
	try testing.expectEqual(@as(usize, 3), rb.len());

	rb.clear();
	try testing.expectEqual(@as(usize, 0), rb.len());

	// After clear, pushing starts fresh
	rb.push(999);
	try testing.expectEqual(@as(usize, 1), rb.len());
	try testing.expectEqual(@as(i32, 999), rb.get(0));
}

test "toSlice copies correctly" {
	// Non-overflow case
	{
		var rb = RingBuffer(i32, 5).init();
		rb.push(10);
		rb.push(20);
		rb.push(30);

		var out: [5]i32 = undefined;
		const slice = rb.toSlice(&out);
		try testing.expectEqual(@as(usize, 3), slice.len);
		try testing.expectEqual(@as(i32, 10), slice[0]);
		try testing.expectEqual(@as(i32, 20), slice[1]);
		try testing.expectEqual(@as(i32, 30), slice[2]);
	}

	// Overflow case — oldest items discarded, chronological order preserved
	{
		var rb = RingBuffer(i32, 3).init();
		rb.push(1);
		rb.push(2);
		rb.push(3);
		rb.push(4);
		rb.push(5);
		// buffer now holds [3, 4, 5] logically

		var out: [3]i32 = undefined;
		const slice = rb.toSlice(&out);
		try testing.expectEqual(@as(usize, 3), slice.len);
		try testing.expectEqual(@as(i32, 3), slice[0]);
		try testing.expectEqual(@as(i32, 4), slice[1]);
		try testing.expectEqual(@as(i32, 5), slice[2]);
	}

	// toSlice with a smaller output buffer than count
	{
		var rb = RingBuffer(i32, 5).init();
		rb.push(10);
		rb.push(20);
		rb.push(30);
		rb.push(40);

		var out: [2]i32 = undefined;
		const slice = rb.toSlice(&out);
		// Should only copy first 2 (oldest)
		try testing.expectEqual(@as(usize, 2), slice.len);
		try testing.expectEqual(@as(i32, 10), slice[0]);
		try testing.expectEqual(@as(i32, 20), slice[1]);
	}
}
