const std = @import("std");
const expectEqual = std.testing.expectEqual;

pub const TaskFn = *const fn (*anyopaque) anyerror!void;

pub const ExecutionMode = enum(u1) {
    Synchronous,
    Suspendable,
};

pub const Task = struct {
    task_fn: TaskFn,
    exec_mode: ExecutionMode,
    data: *anyopaque,
    epoch_slot: u8,

    pub fn encode(self: *const @This()) EncodedTask {
        return .{
            .task_fn = @intCast(@intFromPtr(self.task_fn)),
            .exec_mode = self.exec_mode,
            .data = @intCast(@intFromPtr(self.data)),
            .epoch_slot = @intCast(self.epoch_slot),
        };
    }
};

pub const EncodedTask = packed struct(u128) {
    task_fn: u63,
    exec_mode: ExecutionMode,
    data: u60,
    epoch_slot: u4,

    pub fn decode(self: *const @This()) Task {
        return .{
            .task_fn = @ptrFromInt(self.task_fn),
            .exec_mode = self.exec_mode,
            .data = @ptrFromInt(self.data),
            .epoch_slot = self.epoch_slot,
        };
    }
};

test "Task encoding and decoding returns expected values" {
    const TestFnWrapper = struct {
        fn testFn(arg: *anyopaque) !void {
            const as_int: *u32 = @ptrCast(@alignCast(arg));
            if (as_int.* != 123) {
                return error.ReadUnexpectedArg;
            }
        }
    };

    var test_data: u32 = 123;
    const test_task = Task{
        .task_fn = TestFnWrapper.testFn,
        .data = &test_data,
        .exec_mode = .Synchronous,
        .epoch_slot = 3,
    };
    const encoded = test_task.encode();
    const decoded = encoded.decode();
    try expectEqual( // decoding unpacks into the expected task
        test_task,
        decoded,
    );
    try decoded.task_fn(decoded.data); // testFn reads out the expected data
}
