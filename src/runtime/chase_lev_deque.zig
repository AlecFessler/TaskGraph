const std = @import("std");
const expectEqual = std.testing.expectEqual;

const task_mod = @import("task.zig");
const EncodedTask = task_mod.EncodedTask;
const Task = task_mod.Task;

pub const StealResult = struct {
    pub const StealStatus = enum {
        Stolen,
        Empty,
        Lost,
    };
    status: StealStatus,
    task: Task,
};

// extern so the compiler can't reorder fields
pub const ChaseLevDeque = extern struct {
    slots: [*]EncodedTask,
    mask: i64,
    top: i64 align(std.atomic.cache_line) = 0,
    bottom: i64 align(std.atomic.cache_line) = 0,
    cached_top: i64 align(std.atomic.cache_line) = 0,

    pub fn init(capacity: u64, alloc: std.mem.Allocator) !ChaseLevDeque {
        std.debug.assert(std.math.isPowerOfTwo(capacity));
        const memory = try alloc.alloc(EncodedTask, capacity);
        return .{
            .slots = memory.ptr,
            .mask = @intCast(capacity - 1),
        };
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        const capacity: u64 = @intCast(self.mask + 1);
        alloc.free(self.slots[0..capacity]);
    }

    pub fn enqueue(self: *@This(), task: Task) bool {
        if (self.bottom - self.cached_top > self.mask) {
            // pairs with the top CAS in steal() before reusing a released slot
            self.cached_top = @atomicLoad(i64, &self.top, .acquire);
        }
        if (self.bottom - self.cached_top > self.mask) return false;
        const slot_index: u64 = @intCast(self.bottom & self.mask);
        self.slots[slot_index] = task.encode();
        // pairs with the bottom load in steal()
        @atomicStore(i64, &self.bottom, self.bottom + 1, .release);
        return true;
    }

    pub fn enqueueBatch(self: *@This(), tasks: []const Task) u64 {
        const capacity = self.mask + 1;
        var available = capacity - (self.bottom - self.cached_top);
        if (available < tasks.len) {
            // pairs with the top CAS in steal() before reusing a released slot
            self.cached_top = @atomicLoad(i64, &self.top, .acquire);
        }
        available = capacity - (self.bottom - self.cached_top);
        const count: u64 = @intCast(@min(available, tasks.len));
        for (0..count) |i| {
            const index: i64 = @intCast(i);
            const slot_index: u64 = @intCast((self.bottom + index) & self.mask);
            self.slots[slot_index] = tasks[i].encode();
        }
        if (count != 0) {
            // pairs with the bottom load in steal(), publishing every filled slot at once
            const signed_count: i64 = @intCast(count);
            @atomicStore(i64, &self.bottom, self.bottom + signed_count, .release);
        }
        return count;
    }

    pub fn pop(self: *@This()) ?Task {
        const bottom = self.bottom - 1;
        // bottom must be written before top is read
        @atomicStore(i64, &self.bottom, bottom, .seq_cst);
        const top = @atomicLoad(i64, &self.top, .seq_cst);
        if (top > bottom) {
            @atomicStore(i64, &self.bottom, bottom + 1, .monotonic);
            return null;
        }
        const slot_index: u64 = @intCast(bottom & self.mask);
        const task = self.slots[slot_index];
        if (top < bottom) return task.decode();
        // competes with the cmpxchg in steal()
        const result = @cmpxchgStrong(
            i64,
            &self.top,
            top,
            top + 1,
            .seq_cst,
            .monotonic,
        );
        @atomicStore(i64, &self.bottom, bottom + 1, .monotonic);
        if (result != null) return null;
        return task.decode();
    }

    pub fn steal(self: *@This()) StealResult {
        // pairs with the releasing top CAS in steal() or pop()
        const top = @atomicLoad(i64, &self.top, .seq_cst);
        // pairs with the bottom store in enqueue() or enqueueBatch()
        const bottom = @atomicLoad(i64, &self.bottom, .seq_cst);
        if (top >= bottom) {
            return .{
                .status = .Empty,
                .task = undefined,
            };
        }
        const slot_index: u64 = @intCast(top & self.mask);
        const task = self.slots[slot_index];
        // syncs with the acquire top refresh in enqueue()
        // competes with cmpxchg in pop()
        const result = @cmpxchgStrong(
            i64,
            &self.top,
            top,
            top + 1,
            .seq_cst,
            .monotonic,
        );
        if (result != null) return .{
            .status = .Lost,
            .task = undefined,
        };
        return .{
            .status = .Stolen,
            .task = task.decode(),
        };
    }
};

test "ChaseLevDeque empty pop returns null" {
    const capacity = 8;
    var deque = try ChaseLevDeque.init(capacity, std.testing.allocator);
    defer deque.deinit(std.testing.allocator);

    try expectEqual( // pop on an empty queue returns null
        null,
        deque.pop(),
    );
}

test "ChaseLevDeque empty steal returns Empty" {
    const capacity = 8;
    var deque = try ChaseLevDeque.init(capacity, std.testing.allocator);
    defer deque.deinit(std.testing.allocator);

    const empty_steal_result = deque.steal();
    try expectEqual( // steal on an empty deque returns StealResult with Empty StealStatus
        StealResult.StealStatus.Empty,
        empty_steal_result.status,
    );
}

test "ChaseLevDeque enqueue succeeds when space remains" {
    const capacity = 8;
    var deque = try ChaseLevDeque.init(capacity, std.testing.allocator);
    defer deque.deinit(std.testing.allocator);

    var test_data: u64 = 0;

    for (0..2) |i| {
        const setup_task = testTask(@intCast(i), &test_data);
        try expectEqual( // enqueue with sufficient capacity returns true
            true,
            deque.enqueue(setup_task),
        );
    }
    const test_task = testTask(2, &test_data);
    try expectEqual( // enqueue with sufficient capacity returns true
        true,
        deque.enqueue(test_task),
    );
    // current slots state:
    // {0, 1, 2, _, _, _, _, _,}
    try expectEqual( // slot 2 has the expected task
        2,
        deque.slots[2].epoch_slot,
    );
}

test "ChaseLevDeque enqueue fails when full" {
    const capacity = 8;
    var deque = try ChaseLevDeque.init(capacity, std.testing.allocator);
    defer deque.deinit(std.testing.allocator);

    var test_data: u64 = 0;

    for (0..capacity) |i| {
        const setup_task = testTask(@intCast(i), &test_data);
        try expectEqual( // enqueue with sufficient capacity returns true
            true,
            deque.enqueue(setup_task),
        );
    }
    const test_task = testTask(2, &test_data);
    try expectEqual( // enqueue without sufficient capacity returns false
        false,
        deque.enqueue(test_task),
    );
}

test "ChaseLevDeque enqueueBatch accepts the whole batch when it fits" {
    const capacity = 8;
    var deque = try ChaseLevDeque.init(capacity, std.testing.allocator);
    defer deque.deinit(std.testing.allocator);

    var test_data: u64 = 0;

    // tests will use epoch slot as a unique task id to verify pop/steal ordering
    const test_task_base = testTask(0, &test_data);
    var test_batch: [2]Task = .{test_task_base} ** 2;
    test_batch[1].epoch_slot = 1;
    try expectEqual( // enqueueBatch with sufficient capacity returns the expected count
        test_batch.len,
        deque.enqueueBatch(&test_batch),
    );
    // current slots state:
    // {0, 1, _, _, _, _, _, _,}
    try expectEqual( // slot 0 has the expected task
        0,
        deque.slots[0].epoch_slot,
    );
    try expectEqual( // slot 1 has the expected task
        1,
        deque.slots[1].epoch_slot,
    );
}

test "ChaseLevDeque enqueueBatch accepts only the available capacity" {
    const capacity = 8;
    var deque = try ChaseLevDeque.init(capacity, std.testing.allocator);
    defer deque.deinit(std.testing.allocator);

    var test_data: u64 = 0;

    for (0..3) |i| {
        const setup_task = testTask(@intCast(i), &test_data);
        try expectEqual( // enqueue with sufficient capacity returns true
            true,
            deque.enqueue(setup_task),
        );
    }
    const test_task_base = testTask(0, &test_data);
    var epoch_slot_counter: u8 = 3;

    const batch_size = 6;
    var oversized_test_batch: [batch_size]Task = .{test_task_base} ** batch_size;
    for (0..batch_size) |i| {
        oversized_test_batch[i].epoch_slot = epoch_slot_counter;
        if (i < batch_size - 1) epoch_slot_counter += 1;
    }
    try expectEqual( // enqueueBatch without sufficient capacity returns partial count
        batch_size - 1,
        deque.enqueueBatch(&oversized_test_batch),
    );
    // current slots state:
    // {0, 1, 2, 3, 4, 5, 6, 7,}
    for (3..8) |i| {
        try expectEqual( // newly inserted slots have the expected tasks
            i,
            deque.slots[i].epoch_slot,
        );
    }
}

test "ChaseLevDeque pop returns tasks in lifo ordering" {
    const capacity = 8;
    var deque = try ChaseLevDeque.init(capacity, std.testing.allocator);
    defer deque.deinit(std.testing.allocator);

    var test_data: u64 = 0;

    for (0..capacity) |i| {
        const setup_task = testTask(@intCast(i), &test_data);
        try expectEqual( // enqueue with sufficient capacity returns true
            true,
            deque.enqueue(setup_task),
        );
    }
    const expected_popped_epoch_slot = 7;
    try expectEqual( // pop removes from the bottom with lifo ordering
        expected_popped_epoch_slot,
        deque.pop().?.epoch_slot,
    );
    // current slots state:
    // {0, 1, 2, 3, 4, 5, 6, _,}
}

test "ChaseLevDeque steal returns tasks in fifo ordering" {
    const capacity = 8;
    var deque = try ChaseLevDeque.init(capacity, std.testing.allocator);
    defer deque.deinit(std.testing.allocator);

    var test_data: u64 = 0;

    for (0..capacity) |i| {
        const setup_task = testTask(@intCast(i), &test_data);
        try expectEqual( // enqueue with sufficient capacity returns true
            true,
            deque.enqueue(setup_task),
        );
    }
    const expected_stolen_epoch_slot = 0;
    const result = deque.steal();
    try expectEqual( // successful steals have Stolen status
        StealResult.StealStatus.Stolen,
        result.status,
    );
    try expectEqual( // steal removes from the top with fifo ordering
        expected_stolen_epoch_slot,
        result.task.epoch_slot,
    );
    // current slots state:
    // {_, 1, 2, 3, 4, 5, 6, 7,}
}

test "ChaseLevDeque pop preserves lifo ordering across wrap around" {
    const capacity = 8;
    var deque = try ChaseLevDeque.init(capacity, std.testing.allocator);
    defer deque.deinit(std.testing.allocator);

    var test_data: u64 = 0;

    for (0..capacity) |i| {
        const setup_task = testTask(@intCast(i), &test_data);
        try expectEqual( // enqueue with sufficient capacity returns true
            true,
            deque.enqueue(setup_task),
        );
    }
    // current slots state:
    // {0, 1, 2, 3, 4, 5, 6, 7,}

    const expected_popped_epoch_slot = 7;
    try expectEqual( // pop removes from the bottom with lifo ordering
        expected_popped_epoch_slot,
        deque.pop().?.epoch_slot,
    );
    // current slots state:
    // {0, 1, 2, 3, 4, 5, 6, _,}

    const expected_stolen_epoch_slot = 0;
    const result = deque.steal();
    try expectEqual( // successful steals have Stolen status
        StealResult.StealStatus.Stolen,
        result.status,
    );
    try expectEqual( // steal removes from the top with fifo ordering
        expected_stolen_epoch_slot,
        result.task.epoch_slot,
    );
    // current slots state:
    // {_, 1, 2, 3, 4, 5, 6, _,}

    var epoch_slot_counter: u8 = 7;
    for (0..2) |_| {
        const test_task = testTask(epoch_slot_counter, &test_data);
        epoch_slot_counter += 1;
        try expectEqual( // enqueue with sufficient capacity returns true
            true,
            deque.enqueue(test_task),
        );
    }
    // current slots state:
    // {8, 1, 2, 3, 4, 5, 6, 7,}
    for (1..capacity + 1) |i| {
        const expected_pop_epoch_slot: u8 = @intCast(capacity + 1 - i); // 8..1
        try expectEqual( // pop results in correct ordering across slots wrap around
            expected_pop_epoch_slot,
            deque.pop().?.epoch_slot,
        );
    }
}

test "ChaseLevDeque steal preserves fifo ordering across wrap around" {
    const capacity = 8;
    var deque = try ChaseLevDeque.init(capacity, std.testing.allocator);
    defer deque.deinit(std.testing.allocator);

    var test_data: u64 = 0;

    for (0..capacity) |i| {
        const setup_task = testTask(@intCast(i), &test_data);
        try expectEqual( // enqueue with sufficient capacity returns true
            true,
            deque.enqueue(setup_task),
        );
    }
    // current slots state:
    // {0, 1, 2, 3, 4, 5, 6, 7,}

    const expected_popped_epoch_slot = 7;
    try expectEqual( // pop removes from the bottom with lifo ordering
        expected_popped_epoch_slot,
        deque.pop().?.epoch_slot,
    );
    // current slots state:
    // {0, 1, 2, 3, 4, 5, 6, _,}

    const expected_stolen_epoch_slot = 0;
    const result = deque.steal();
    try expectEqual( // successful steals have Stolen status
        StealResult.StealStatus.Stolen,
        result.status,
    );
    try expectEqual( // steal removes from the top with fifo ordering
        expected_stolen_epoch_slot,
        result.task.epoch_slot,
    );
    // current slots state:
    // {_, 1, 2, 3, 4, 5, 6, _,}

    var epoch_slot_counter: u8 = 7;
    for (0..2) |_| {
        const test_task = testTask(epoch_slot_counter, &test_data);
        epoch_slot_counter += 1;
        try expectEqual( // enqueue with sufficient capacity returns true
            true,
            deque.enqueue(test_task),
        );
    }
    // current slots state:
    // {8, 1, 2, 3, 4, 5, 6, 7,}
    for (1..capacity + 1) |i| {
        const expected_steal_epoch_slot: u8 = @intCast(i); // 1..8
        const steal_result = deque.steal();
        try expectEqual( // each steal result has the expected Stolen status
            StealResult.StealStatus.Stolen,
            steal_result.status,
        );
        try expectEqual( // steal results in correct ordering across slots wrap around
            expected_steal_epoch_slot,
            steal_result.task.epoch_slot,
        );
    }
}

test "ChaseLevDeque concurrent pop and steal claim every task exactly once" {
    // with a single owner and thief thread, all slots are popped/stolen exactly once
    const num_slots = 256;
    const TestThread = struct {
        fn testThreadMain(
            threaded_test_deque: *ChaseLevDeque,
            ready: *bool,
            saw_double_claim: *bool,
            slots_claimed: *[num_slots]bool,
        ) void {
            @atomicStore(bool, ready, true, .release);
            while (true) {
                const steal_result = threaded_test_deque.steal();
                if (steal_result.status == .Lost) continue;
                if (steal_result.status == .Empty) break;
                const id: u64 = @intFromPtr(steal_result.task.data) - 1;
                if (!@atomicRmw(bool, &slots_claimed[id], .Xchg, true, .monotonic)) continue;
                @atomicStore(bool, saw_double_claim, true, .monotonic);
                break;
            }
        }
    };
    var slots_claimed: [num_slots]bool = .{false} ** num_slots;
    var threaded_test_deque = try ChaseLevDeque.init(num_slots, std.testing.allocator);
    defer threaded_test_deque.deinit(std.testing.allocator);
    for (0..num_slots) |i| {
        const threaded_test_task = Task{
            .task_fn = testFn,
            .exec_mode = .Synchronous,
            .data = @ptrFromInt(i + 1), // using data ptr bits to store a task id for testing
            .epoch_slot = 0,
        };
        _ = threaded_test_deque.enqueue(threaded_test_task);
    }
    var ready = false;
    var saw_double_claim = false;
    const thief = try std.Thread.spawn(.{}, TestThread.testThreadMain, .{
        &threaded_test_deque,
        &ready,
        &saw_double_claim,
        &slots_claimed,
    });
    while (!@atomicLoad(bool, &ready, .acquire)) {}
    while (true) {
        const pop_result = threaded_test_deque.pop();
        if (pop_result == null) break;
        const id: u64 = @intFromPtr(pop_result.?.data) - 1;
        if (!@atomicRmw(bool, &slots_claimed[id], .Xchg, true, .monotonic)) continue;
        @atomicStore(bool, &saw_double_claim, true, .monotonic);
        break;
    }
    thief.join();
    try expectEqual( // neither the owner nor thief should have observed a double claimed slot
        false,
        saw_double_claim,
    );
    for (slots_claimed) |slot| {
        try expectEqual( // every slot should've been claimed by a pop or steal
            true,
            slot,
        );
    }
}

fn testFn(arg: *anyopaque) !void {
    _ = arg;
}

fn testTask(epoch_slot: u8, test_data: *u64) Task {
    return .{
        .task_fn = testFn,
        .exec_mode = .Synchronous,
        .data = @ptrCast(test_data),
        .epoch_slot = epoch_slot,
    };
}
