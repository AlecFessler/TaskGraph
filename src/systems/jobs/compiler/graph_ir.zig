const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const bounded_array = @import("bounded_array.zig");
const BoundedArray = bounded_array.BoundedArray;
const graph_builder = @import("graph_builder.zig");
const array_capacity = graph_builder.array_capacity;
const Carry = graph_builder.Carry;
const Edge = graph_builder.Edge;
const JobGraphBuilder = graph_builder.JobGraphBuilder;
const JobFn = graph_builder.JobFn;
const JobID = graph_builder.JobID;
const JobParam = graph_builder.JobParam;
const ResourceLayout = graph_builder.ResourceLayout;
const packed_slices = @import("packed_slices.zig");
const PackedSlices = packed_slices.PackedSlices;

pub const JobGraphIR = struct {
    resource_layout: BoundedArray(ResourceLayout, array_capacity) = .{},
    resource_carry: BoundedArray(Carry, array_capacity) = .{},
    job_fn: BoundedArray(JobFn, array_capacity) = .{},
    job_params: PackedSlices(JobParam, array_capacity, array_capacity) = .{},
    roots: BoundedArray(JobID, array_capacity) = .{},
    initial_dependency_counters: BoundedArray(u32, array_capacity) = .{},
    dependents: PackedSlices(JobID, array_capacity, array_capacity) = .{},
    carry_dependents: PackedSlices(JobID, array_capacity, array_capacity) = .{},
};

pub fn compileJobGraphIR(comptime builder: *JobGraphBuilder) !JobGraphIR {
    var ir: JobGraphIR = .{};
    const job_count = builder.job_fn.size;
    std.debug.assert(0 < job_count and job_count + 1 <= array_capacity);

    var carry_edges: BoundedArray(Edge, array_capacity) = .{};
    for (builder.resource_carry.elements[0..builder.resource_carry.size]) |carry| {
        const producer = builder.resource_producer.elements[carry.from];
        for (0..job_count) |job_id| {
            for (try builder.job_params.subslice(@intCast(job_id))) |param| {
                if (param.id != carry.to) continue;
                try carry_edges.append(Edge{ .producer = producer, .consumer = @intCast(job_id) });
            }
        }
    }

    const EdgePacker = struct {
        fn pack(
            edges: *const BoundedArray(Edge, array_capacity),
            compressed_sparse_rows: *PackedSlices(JobID, array_capacity, array_capacity),
        ) void {
            const offsets_size = job_count + 1;
            @memset(compressed_sparse_rows.offsets[0..offsets_size], 0);
            for (edges.elements[0..edges.size]) |edge| {
                compressed_sparse_rows.offsets[edge.producer + 1] += 1;
            }

            for (1..offsets_size) |job_id| {
                compressed_sparse_rows.offsets[job_id] += compressed_sparse_rows.offsets[job_id - 1];
            }

            var cursor: [offsets_size - 1]u32 = compressed_sparse_rows.offsets[0 .. offsets_size - 1].*;
            for (edges.elements[0..edges.size]) |edge| {
                compressed_sparse_rows.values[cursor[edge.producer]] = edge.consumer;
                cursor[edge.producer] += 1;
            }

            compressed_sparse_rows.values_size = edges.size;
            compressed_sparse_rows.offsets_size = offsets_size;
        }
    };
    EdgePacker.pack(&builder.edges, &ir.dependents);
    EdgePacker.pack(&carry_edges, &ir.carry_dependents);

    var has_dependency: [job_count]bool = [_]bool{false} ** job_count;
    for (builder.edges.elements[0..builder.edges.size]) |edge| {
        has_dependency[edge.consumer] = true;
    }
    for (has_dependency, 0..) |is_not_root, job_id| {
        if (is_not_root) continue;
        try ir.roots.append(@intCast(job_id));
    }

    @memset(ir.initial_dependency_counters.elements[0..job_count], 0);
    ir.initial_dependency_counters.size = job_count;
    for (builder.edges.elements[0..builder.edges.size]) |edge| {
        ir.initial_dependency_counters.elements[edge.consumer] += 1;
    }
    for (carry_edges.elements[0..carry_edges.size]) |edge| {
        ir.initial_dependency_counters.elements[edge.consumer] += 1;
    }
    for (ir.roots.elements[0..ir.roots.size]) |job_id| {
        ir.initial_dependency_counters.elements[job_id] += 1;
    }

    // optimization pipeline runs here

    ir.resource_layout = builder.resource_layout;
    ir.resource_carry = builder.resource_carry;
    ir.job_fn = builder.job_fn;
    ir.job_params = builder.job_params;

    return ir;
}

test "compileJobGraphIR()" {
    const declareJob = graph_builder.declareJob;
    const declareResourceCarry = graph_builder.declareResourceCarry;
    const runGraphBuildFn = graph_builder.runGraphBuildFn;
    comptime {
        const TestFnWrapper = struct {
            fn root(read_param: *const u32, write_param: *u32) !void {
                _ = read_param;
                _ = write_param;
            }

            fn fanOut(read_param: *const u32, write_param: *u32) !void {
                _ = read_param;
                _ = write_param;
            }

            fn fanOutWithCarry(read_param0: *const u32, read_param1: *const u32, write_param: *u32) !void {
                _ = read_param0;
                _ = read_param1;
                _ = write_param;
            }

            fn fanIn(read_param0: *const u32, read_param1: *const u32, write_param0: *u32, write_param1: *u32) !void {
                _ = read_param0;
                _ = read_param1;
                _ = write_param0;
                _ = write_param1;
            }

            fn graphBuildFn(comptime builder: *JobGraphBuilder) !void {
                const resource0_v0 = try builder.declareResource(u32);
                const resource0_v1 = try declareJob(root, .{ resource0_v0, resource0_v0 });
                const resource0_v2 = try declareJob(fanOut, .{ resource0_v1, resource0_v1 });
                const resource1_v0 = try builder.declareResource(u32);
                const resource1_v1 = try declareJob(fanOutWithCarry, .{ resource0_v1, resource1_v0, resource1_v0 });
                const resource0_v3, const resource1_v2 = try declareJob(fanIn, .{ resource0_v2, resource1_v1, resource0_v2, resource1_v1 });
                try declareResourceCarry(resource0_v3);
                try declareResourceCarry(resource1_v2);
            }
        };

        var builder = try runGraphBuildFn(TestFnWrapper.graphBuildFn);
        const ir = try compileJobGraphIR(&builder);

        // derived dependents packed slices arrays have the expected sizes and elements
        const expected_dependents_values_size = 4;
        const expected_dependents_values_array: [expected_dependents_values_size]JobID = .{ 1, 2, 3, 3 };
        try expectEqual(
            expected_dependents_values_size,
            ir.dependents.values_size,
        );
        try expectEqualSlices(
            JobID,
            &expected_dependents_values_array,
            ir.dependents.values[0..ir.dependents.values_size],
        );
        const expected_dependents_offsets_size = 5;
        const expected_dependents_offsets_array: [expected_dependents_offsets_size]u32 = .{ 0, 2, 3, 4, 4 };
        try expectEqual(
            expected_dependents_offsets_size,
            ir.dependents.offsets_size,
        );
        try expectEqualSlices(
            u32,
            &expected_dependents_offsets_array,
            ir.dependents.offsets[0..ir.dependents.offsets_size],
        );

        // derived carry dependents packed slices arrays have the expected sizes and elements
        const expected_carry_dependents_values_size = 2;
        const expected_carry_dependents_values_array: [expected_carry_dependents_values_size]JobID = .{ 0, 2 };
        try expectEqual(
            expected_carry_dependents_values_size,
            ir.carry_dependents.values_size,
        );
        try expectEqualSlices(
            JobID,
            &expected_carry_dependents_values_array,
            ir.carry_dependents.values[0..ir.carry_dependents.values_size],
        );
        const expected_carry_dependents_offsets_size = 5;
        const expected_carry_dependents_offsets_array: [expected_carry_dependents_offsets_size]u32 = .{ 0, 0, 0, 0, 2 };
        try expectEqual(
            expected_carry_dependents_offsets_size,
            ir.carry_dependents.offsets_size,
        );
        try expectEqualSlices(
            u32,
            &expected_carry_dependents_offsets_array,
            ir.carry_dependents.offsets[0..ir.carry_dependents.offsets_size],
        );

        // roots array has expected size and elements
        const expected_roots_size = 1;
        const expected_roots_array: [expected_roots_size]JobID = .{0};
        try expectEqual(
            expected_roots_size,
            ir.roots.size,
        );
        try expectEqualSlices(
            JobID,
            &expected_roots_array,
            ir.roots.elements[0..ir.roots.size],
        );

        // initial dependency counters has expected size and elements
        const expected_dependency_counters_size = 4;
        // job 0 has 1 counter from the carry and 1 for being a root
        // job 1 has 1 counter from reading job 0's write
        // job 2 has 1 counter from the carry and 1 from reading job 0's write
        // job 3 has 1 counter from reading from job 1's write and one counter from reading job 2's write
        const expected_dependency_counters_array: [expected_dependency_counters_size]u32 = .{ 2, 1, 2, 2 };
        try expectEqual(
            expected_dependency_counters_size,
            ir.initial_dependency_counters.size,
        );
        try expectEqualSlices(
            u32,
            &expected_dependency_counters_array,
            ir.initial_dependency_counters.elements[0..ir.initial_dependency_counters.size],
        );

        // copied resource_layout array has the expected size and elements
        try expectEqual(
            builder.resource_layout.size,
            ir.resource_layout.size,
        );
        try expectEqualSlices(
            ResourceLayout,
            builder.resource_layout.elements[0..builder.resource_layout.size],
            ir.resource_layout.elements[0..ir.resource_layout.size],
        );
        // copied resource_carry array has the expected size and elements
        try expectEqual(
            builder.resource_carry.size,
            ir.resource_carry.size,
        );
        try expectEqualSlices(
            Carry,
            builder.resource_carry.elements[0..builder.resource_carry.size],
            ir.resource_carry.elements[0..ir.resource_carry.size],
        );
        // copied job_fn array has the expected size and elements
        try expectEqual(
            builder.job_fn.size,
            ir.job_fn.size,
        );
        try expectEqualSlices(
            JobFn,
            builder.job_fn.elements[0..builder.job_fn.size],
            ir.job_fn.elements[0..ir.job_fn.size],
        );
        // copied job_params packed slices arrays have the expected sizes and elements
        try expectEqual(
            builder.job_params.values_size,
            ir.job_params.values_size,
        );
        try expectEqualSlices(
            JobParam,
            builder.job_params.values[0..builder.job_params.values_size],
            ir.job_params.values[0..ir.job_params.values_size],
        );
        try expectEqual(
            builder.job_params.offsets_size,
            ir.job_params.offsets_size,
        );
        try expectEqualSlices(
            u32,
            builder.job_params.offsets[0..builder.job_params.offsets_size],
            ir.job_params.offsets[0..ir.job_params.offsets_size],
        );
    }
}
