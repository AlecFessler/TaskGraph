const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const bounded_array = @import("bounded_array.zig");
const BoundedArray = bounded_array.BoundedArray;
const graph_builder = @import("graph_builder.zig");
const JobGraphBuilder = graph_builder.JobGraphBuilder;
const invokeGraphBuildFn = graph_builder.invokeGraphBuildFn;
const JobFn = graph_builder.JobFn;
const JobID = graph_builder.JobID;
const JobParam = graph_builder.JobParam;
const ResourceID = graph_builder.ResourceID;
const graph_ir = @import("graph_ir.zig");
const JobGraphIR = graph_ir.JobGraphIR;
const compileJobGraphIR = graph_ir.compileJobGraphIR;
const packed_slices = @import("packed_slices.zig");
const PackedSlices = packed_slices.PackedSlices;

const epochs_in_flight = 2;
const armed_ahead_slots = 1;
const epoch_slot_count = epochs_in_flight + armed_ahead_slots;

pub fn JobGraph(
    comptime graphBuildFn: *const fn (comptime *JobGraphBuilder) anyerror!void,
) type {
    var mutable_builder = invokeGraphBuildFn(graphBuildFn) catch |err| {
        @compileError(std.fmt.comptimePrint("Job graph declaration failed: {s}", .{@errorName(err)}));
    };
    const ir = compileJobGraphIR(&mutable_builder) catch |err| {
        @compileError(std.fmt.comptimePrint("Job graph IR compilation failed: {s}", .{@errorName(err)}));
    };
    const builder = mutable_builder;

    var resource_offsets: [builder.resource_layout.size]u32 = undefined;
    var job_param_offsets: [epoch_slot_count * builder.job_params.values_size]u32 = undefined;
    var slot_bytes: u32 = 0;
    var slot_align: u32 = 1;

    for (0..builder.resource_layout.size) |resource_id| {
        const layout = builder.resource_layout.elements[resource_id];
        const aligned = std.mem.alignForward(u32, slot_bytes, layout.alignment);
        resource_offsets[resource_id] = aligned;
        slot_bytes = aligned + layout.size;
        slot_align = @max(slot_align, layout.alignment);
    }
    slot_bytes = std.mem.alignForward(u32, slot_bytes, slot_align);

    for (0..epoch_slot_count) |slot| {
        for (builder.job_params.values[0..builder.job_params.values_size], 0..) |param, i| {
            var source_id = param.id;
            var source_slot = slot;
            const carry_from: ?ResourceID = result: for (builder.resource_carry.elements[0..builder.resource_carry.size]) |carry| {
                if (carry.to == param.id) break :result carry.from;
            } else null;
            if (carry_from != null) {
                source_id = carry_from.?;
                source_slot = (slot + epoch_slot_count - 1) % epoch_slot_count;
            }
            job_param_offsets[slot * builder.job_params.values_size + i] =
                source_slot * slot_bytes + resource_offsets[source_id];
        }
    }

    const job_param_offsets_final = job_param_offsets;
    const slot_bytes_final = slot_bytes;
    const slot_align_final = slot_align;

    return struct {
        // readonly fields
        job_fn: [builder.job_fn.size]JobFn =
            builder.job_fn.elements[0..builder.job_fn.size].*,
        job_params_offsets: [builder.job_params.offsets_size]u32 =
            builder.job_params.offsets[0..builder.job_params.offsets_size].*,
        roots: [ir.roots.size]JobID =
            ir.roots.elements[0..ir.roots.size].*,
        initial_dependency_counters: [ir.initial_dependency_counters.size]u32 =
            ir.initial_dependency_counters.elements[0..ir.initial_dependency_counters.size].*,
        dependents: PackedSlices(JobID, ir.dependents.values_size, ir.dependents.offsets_size) = .{
            .values = ir.dependents.values[0..ir.dependents.values_size].*,
            .values_size = ir.dependents.values_size,
            .offsets = ir.dependents.offsets[0..ir.dependents.offsets_size].*,
            .offsets_size = ir.dependents.offsets_size,
        },
        carry_dependents: PackedSlices(JobID, ir.carry_dependents.values_size, ir.carry_dependents.offsets_size) = .{
            .values = ir.carry_dependents.values[0..ir.carry_dependents.values_size].*,
            .values_size = ir.carry_dependents.values_size,
            .offsets = ir.carry_dependents.offsets[0..ir.carry_dependents.offsets_size].*,
            .offsets_size = ir.carry_dependents.offsets_size,
        },

        // runtime mutable state fields
        dependency_counters: [epoch_slot_count * ir.initial_dependency_counters.size]u32 =
            ir.initial_dependency_counters.elements[0..ir.initial_dependency_counters.size].* ** epoch_slot_count,
        job_params: [epoch_slot_count * builder.job_params.values_size]*anyopaque =
            undefined,

        alloc: std.mem.Allocator =
            undefined,
        resource_buffer: []align(slot_align_final) u8 =
            undefined,

        pub fn init(self: *@This(), alloc: std.mem.Allocator) !void {
            const total_bytes = epoch_slot_count * slot_bytes_final;
            self.resource_buffer = try alloc.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(slot_align_final), total_bytes);
            self.alloc = alloc;
            for (job_param_offsets_final, 0..) |offset, i| {
                self.job_params[i] = self.resource_buffer.ptr + offset;
            }
        }

        pub fn deinit(self: *@This()) void {
            self.alloc.free(self.resource_buffer);
        }
    };
}

test "JobGraph()" {
    const declareJob = graph_builder.declareJob;
    const declareResourceCarry = graph_builder.declareResourceCarry;

    const TestFnWrapper = struct {
        fn root(read_param: *const u32, write_param: *u32) !void {
            _ = read_param;
            _ = write_param;
        }

        fn fanOut(read_param: *const u32, write_param: *u32) !void {
            _ = read_param;
            _ = write_param;
        }

        fn fanOutWithCarry(read_param0: *const u32, read_param1: *const u64, write_param: *u64) !void {
            _ = read_param0;
            _ = read_param1;
            _ = write_param;
        }

        fn fanIn(read_param0: *const u32, read_param1: *const u64, write_param0: *u32, write_param1: *u64) !void {
            _ = read_param0;
            _ = read_param1;
            _ = write_param0;
            _ = write_param1;
        }

        fn graphBuildFn(comptime builder: *JobGraphBuilder) !void {
            const resource0_v0 = try builder.declareResource(u32);
            const resource0_v1 = try declareJob(root, .{ resource0_v0, resource0_v0 });
            const resource0_v2 = try declareJob(fanOut, .{ resource0_v1, resource0_v1 });
            const resource1_v0 = try builder.declareResource(u64);
            const resource1_v1 = try declareJob(fanOutWithCarry, .{ resource0_v1, resource1_v0, resource1_v0 });
            const resource0_v3, const resource1_v2 = try declareJob(fanIn, .{ resource0_v2, resource1_v1, resource0_v2, resource1_v1 });
            try declareResourceCarry(resource0_v3);
            try declareResourceCarry(resource1_v2);
        }
    };

    var job_graph: JobGraph(TestFnWrapper.graphBuildFn) = .{};
    try job_graph.init(std.testing.allocator);
    defer job_graph.deinit();

    const Layout = struct {
        offset: u32,
        alignment: u32,
        prev_slot: bool,
    };
    const r0v0 = Layout{ .offset = 32, .alignment = 4, .prev_slot = true };
    const r0v1 = Layout{ .offset = 4, .alignment = 4, .prev_slot = false };
    const r0v2 = Layout{ .offset = 8, .alignment = 4, .prev_slot = false };
    const r0v3 = Layout{ .offset = 32, .alignment = 4, .prev_slot = false };
    const r1v0 = Layout{ .offset = 40, .alignment = 8, .prev_slot = true };
    const r1v1 = Layout{ .offset = 24, .alignment = 8, .prev_slot = false };
    const r1v2 = Layout{ .offset = 40, .alignment = 8, .prev_slot = false };
    const param_layouts: [job_graph.job_fn.len][]const Layout = .{
        &.{ r0v0, r0v1 },
        &.{ r0v1, r0v2 },
        &.{ r0v1, r1v0, r1v1 },
        &.{ r0v2, r1v1, r0v3, r1v2 },
    };
    const bytes_per_slot = 48;

    try expectEqual( // the resource buffer length has the expected size
        epoch_slot_count * bytes_per_slot,
        job_graph.resource_buffer.len,
    );

    for (0..epoch_slot_count) |slot| {
        for (0..job_graph.job_fn.len) |job_id| {
            const begin = job_graph.job_params_offsets[job_id];
            const end = job_graph.job_params_offsets[job_id + 1];
            try expectEqual( // the graph's param's subslice should match the hardcoded expected slice size
                param_layouts[job_id].len,
                end - begin,
            );
            for (begin..end, 0..) |param_offset, layout_index| {
                // reconstruct the expected offset from hardcoded data
                const layout = param_layouts[job_id][layout_index];
                const source_slot = if (layout.prev_slot)
                    (slot + epoch_slot_count - 1) % epoch_slot_count
                else
                    slot;
                const resource_offset = source_slot * bytes_per_slot + layout.offset;

                // retrieve the actual offset using the graphs intended mechanism
                const params_per_slot = job_graph.job_params_offsets[job_graph.job_params_offsets.len - 1];
                const param_index = slot * params_per_slot + param_offset;
                const param = job_graph.job_params[param_index];

                try expectEqual( // the param address falls at the expected offset
                    @intFromPtr(&job_graph.resource_buffer[resource_offset]),
                    @intFromPtr(param),
                );
                // the param address has the required alignment
                try expect(@intFromPtr(param) % layout.alignment == 0);
            }
        }
    }

    const expected_counters_sequence =
        job_graph.initial_dependency_counters ** epoch_slot_count;
    try expectEqualSlices( // the initial counters sequence is correctly repeated for each slot
        u32,
        &expected_counters_sequence,
        &job_graph.dependency_counters,
    );
}
