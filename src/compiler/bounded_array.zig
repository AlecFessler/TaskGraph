const std = @import("std");
const expectEqual = std.testing.expectEqual;

pub fn BoundedArray(comptime T: type, capacity: u32) type {
    return struct {
        elements: [capacity]T = undefined,
        size: u32 = 0,

        pub fn append(self: *@This(), element: T) !void {
            if (self.size == capacity) {
                return error.BoundedArrayIsFull;
            }
            self.elements[self.size] = element;
            self.size += 1;
        }
    };
}

test "array size initialized to zero" {
    const Array = BoundedArray(u32, 8);
    const array = Array{};
    try expectEqual(0, array.size);
}

test "append places element at current size then increments" {
    const Array = BoundedArray(u32, 8);
    var array = Array{};
    const size_before_append = array.size;
    try array.append(1);
    try expectEqual(1, array.elements[size_before_append]);
    try expectEqual(1, array.size);
}

test "append to full array returns error" {
    const array_size = 4;
    const Array = BoundedArray(u32, array_size);
    var array = Array{};
    for (0..array_size) |i| {
        try array.append(@intCast(i));
    }
    try expectEqual(array.append(1), error.BoundedArrayIsFull);
}
