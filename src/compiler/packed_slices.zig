const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

pub fn PackedSlices(
    comptime T: type,
    comptime values_capacity: u32,
    comptime offsets_capacity: u32,
) type {
    std.debug.assert(offsets_capacity >= 1);
    return struct {
        values: [values_capacity]T = undefined,
        values_size: u32 = 0,
        offsets: [offsets_capacity]u32 = .{0} ++ ([_]u32{undefined} ** (offsets_capacity - 1)),
        offsets_size: u32 = 1,

        pub fn append(self: *@This(), element: T) !void {
            if (self.values_size == values_capacity) {
                return error.PackedSlicesValuesIsFull;
            }
            self.values[self.values_size] = element;
            self.values_size += 1;
        }

        pub fn endSlice(self: *@This()) !void {
            if (self.offsets_size == offsets_capacity) {
                return error.PackedSlicesOffsetsIsFull;
            }
            self.offsets[self.offsets_size] = self.values_size;
            self.offsets_size += 1;
        }

        pub fn subslice(self: *@This(), index: u32) ![]T {
            if (index >= self.offsets_size - 1) {
                return error.IndexOutOfBounds;
            }
            const start = self.offsets[index];
            const end = self.offsets[index + 1];
            return self.values[start..end];
        }
    };
}

test "PackedSlices initializes capacities, sizes, and the starting offset" {
    const array_capacity = 8;
    const TestPackedSlices = PackedSlices(u32, array_capacity, array_capacity);
    const test_packed_slices: TestPackedSlices = .{};
    const expected_values_size: u32 = 0;
    const expected_offsets_size: u32 = 1;

    // initial state
    try expectEqual( // values.len should be array_capacity
        array_capacity,
        test_packed_slices.values.len,
    );
    try expectEqual( // offsets.len should be array_capacity
        array_capacity,
        test_packed_slices.offsets.len,
    );
    try expectEqual( // values_size should be initialized to zero
        expected_values_size,
        test_packed_slices.values_size,
    );
    try expectEqual( // offsets_size should be initialized to one
        expected_offsets_size,
        test_packed_slices.offsets_size,
    );
    try expectEqual( // offsets first element should be 0
        0,
        test_packed_slices.offsets[0],
    );
}

test "subslice rejects access before any slice is ended" {
    const array_capacity = 8;
    const TestPackedSlices = PackedSlices(u32, array_capacity, array_capacity);
    var test_packed_slices: TestPackedSlices = .{};

    try expectError( // subslice(0) before any endSlice() call returns the expected out of bounds error
        error.IndexOutOfBounds,
        test_packed_slices.subslice(0),
    );
}

test "append stores elements and increments values_size" {
    const array_capacity = 8;
    const TestPackedSlices = PackedSlices(u32, array_capacity, array_capacity);
    var test_packed_slices: TestPackedSlices = .{};
    var expected_values_size: u32 = 0;

    // successive appends increment values_size and store the expected value in the correct index
    for (1..4) |i| {
        try test_packed_slices.append(@intCast(i));
        expected_values_size += 1;
        try expectEqual( // values_size should've grown by one
            expected_values_size,
            test_packed_slices.values_size,
        );
        try expectEqual( // values array should contain the expected element at the expected index
            i,
            test_packed_slices.values[expected_values_size - 1],
        );
    }
}

test "endSlice records the boundary without changing values_size" {
    const array_capacity = 8;
    const TestPackedSlices = PackedSlices(u32, array_capacity, array_capacity);
    var test_packed_slices: TestPackedSlices = .{};
    const expected_values_size: u32 = 3;
    var expected_offsets_size: u32 = 1;

    for (1..4) |i| {
        try test_packed_slices.append(@intCast(i));
    }

    // endSlice appends values_size into offsets and increments offsets_size
    try expectEqual( // offsets_size should be unchanged
        expected_offsets_size,
        test_packed_slices.offsets_size,
    );
    try test_packed_slices.endSlice();
    expected_offsets_size += 1;
    try expectEqual( // offsets_size should have grown by one
        expected_offsets_size,
        test_packed_slices.offsets_size,
    );
    try expectEqual( // values_size should remain unchanged
        expected_values_size,
        test_packed_slices.values_size,
    );
    try expectEqual( // offsets array should contain the current values size at the expected index
        expected_values_size,
        test_packed_slices.offsets[expected_offsets_size - 1],
    );
}

test "subslice returns the expected first slice" {
    const array_capacity = 8;
    const TestPackedSlices = PackedSlices(u32, array_capacity, array_capacity);
    var test_packed_slices: TestPackedSlices = .{};

    for (1..4) |i| {
        try test_packed_slices.append(@intCast(i));
    }
    try test_packed_slices.endSlice();

    // subslice within bounds returns the expected subslice of values
    const subslice = try test_packed_slices.subslice(0);
    try expectEqual( // first non-empty subslice has the expected len
        3,
        subslice.len,
    );
    for (subslice, 1..) |elem, expected| {
        try expectEqual(
            expected,
            elem,
        );
    }
}

test "subslice rejects an index beyond completed slices" {
    const array_capacity = 8;
    const TestPackedSlices = PackedSlices(u32, array_capacity, array_capacity);
    var test_packed_slices: TestPackedSlices = .{};

    for (1..4) |i| {
        try test_packed_slices.append(@intCast(i));
    }
    try test_packed_slices.endSlice();

    try expectError( // index out of bounds returns expected error
        error.IndexOutOfBounds,
        test_packed_slices.subslice(1),
    );
}

test "append rejects a full values array without changing its size" {
    const array_capacity = 8;
    const TestPackedSlices = PackedSlices(u32, array_capacity, array_capacity);
    var test_packed_slices: TestPackedSlices = .{};

    for (1..4) |i| {
        try test_packed_slices.append(@intCast(i));
    }
    try test_packed_slices.endSlice();

    // append out of bounds returns error
    for (0..5) |i| {
        try test_packed_slices.append(@intCast(i));
    }
    const values_size_before_failed_append = test_packed_slices.values_size;
    try expectError(
        error.PackedSlicesValuesIsFull,
        test_packed_slices.append(0),
    );
    try expectEqual( // values size should remain unchanged after a failed append
        values_size_before_failed_append,
        test_packed_slices.values_size,
    );
}

test "endSlice rejects a full offsets array without changing its size" {
    const array_capacity = 8;
    const TestPackedSlices = PackedSlices(u32, array_capacity, array_capacity);
    var test_packed_slices: TestPackedSlices = .{};

    for (1..4) |i| {
        try test_packed_slices.append(@intCast(i));
    }
    try test_packed_slices.endSlice();

    // endSlice out of bounds returns error
    for (0..6) |_| {
        try test_packed_slices.endSlice();
    }
    const offsets_size_before_failed_endslice = test_packed_slices.offsets_size;
    try expectError(
        error.PackedSlicesOffsetsIsFull,
        test_packed_slices.endSlice(),
    );
    try expectEqual( // offsets size should remain unchanged by a failed endSlice
        offsets_size_before_failed_endslice,
        test_packed_slices.offsets_size,
    );
}

test "subslice returns the expected subsequent slice" {
    const array_capacity = 8;
    const TestPackedSlices = PackedSlices(u32, array_capacity, array_capacity);
    var test_packed_slices: TestPackedSlices = .{};

    for (1..4) |i| {
        try test_packed_slices.append(@intCast(i));
    }
    try test_packed_slices.endSlice();
    for (0..5) |i| {
        try test_packed_slices.append(@intCast(i));
    }
    for (0..6) |_| {
        try test_packed_slices.endSlice();
    }

    // multiple appends and end slices result in expected state and can take expected subslices
    const second_subslice = try test_packed_slices.subslice(1);
    try expectEqual( // second non-empty subslice has the expected len
        5,
        second_subslice.len,
    );
    for (second_subslice, 0..) |elem, expected| {
        try expectEqual(
            expected,
            elem,
        );
    }
}

test "subslice returns an empty slice for repeated boundaries" {
    const array_capacity = 8;
    const TestPackedSlices = PackedSlices(u32, array_capacity, array_capacity);
    var test_packed_slices: TestPackedSlices = .{};

    for (1..4) |i| {
        try test_packed_slices.append(@intCast(i));
    }
    try test_packed_slices.endSlice();
    for (0..5) |i| {
        try test_packed_slices.append(@intCast(i));
    }
    for (0..6) |_| {
        try test_packed_slices.endSlice();
    }

    // subslices that should be empty have len == 0
    const empty_subslice = try test_packed_slices.subslice(2);
    try expectEqual(
        0,
        empty_subslice.len,
    );
}
