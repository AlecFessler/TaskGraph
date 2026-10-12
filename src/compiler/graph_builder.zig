const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const bounded_array = @import("bounded_array.zig");
const BoundedArray = bounded_array.BoundedArray;
const packed_slices = @import("packed_slices.zig");
const PackedSlices = packed_slices.PackedSlices;

pub const ResourceID = u32;
pub const JobID = u32;
pub const JobFn = *const fn ([*]const *anyopaque) anyerror!void;

pub const array_capacity = 1024;
const no_job = std.math.maxInt(JobID);

pub fn Resource(comptime T: type) type {
    return struct {
        pub const resource_type = T;
        id: ResourceID,
        builder: *JobGraphBuilder,
    };
}

pub const ResourceLayout = struct {
    size: u32,
    alignment: u32,
};

pub const JobParam = struct {
    id: ResourceID,
    is_writable: bool,
};

pub const Edge = struct {
    producer: JobID,
    consumer: JobID,
};

pub const Carry = struct {
    from: ResourceID,
    to: ResourceID,
};

pub const JobGraphBuilder = struct {
    resource_producer: BoundedArray(JobID, array_capacity) = .{},
    resource_origin: BoundedArray(ResourceID, array_capacity) = .{},
    resource_layout: BoundedArray(ResourceLayout, array_capacity) = .{},
    resource_carry: BoundedArray(Carry, array_capacity) = .{},
    job_fn: BoundedArray(JobFn, array_capacity) = .{},
    job_params: PackedSlices(JobParam, array_capacity, array_capacity) = .{},
    edges: BoundedArray(Edge, array_capacity) = .{},

    pub fn declareResource(
        self: *JobGraphBuilder,
        comptime T: type,
    ) !Resource(T) {
        try self.resource_producer.append(no_job);
        try self.resource_layout.append(.{ .size = @sizeOf(T), .alignment = @alignOf(T) });
        const id: ResourceID = self.resource_producer.size - 1;
        try self.resource_origin.append(id);
        return .{ .id = id, .builder = self };
    }
};

pub fn invokeGraphBuildFn(
    comptime graphBuildFn: *const fn (comptime *JobGraphBuilder) anyerror!void,
) !JobGraphBuilder {
    var builder: JobGraphBuilder = .{};
    try graphBuildFn(&builder);
    return builder;
}

fn DeclareJobReturnType(comptime func: anytype) type {
    const fn_type = @TypeOf(func);
    const fn_info = @typeInfo(fn_type).@"fn";
    const fn_type_name = @typeName(fn_type);

    var writable_param_types: []const type = &.{};
    for (fn_info.params, 0..) |param, i| {
        const param_info = @typeInfo(param.type.?);
        const param_type_name = @typeName(param.type.?);

        if (param_info != .pointer) {
            @compileError(std.fmt.comptimePrint(
                "Parameter {} must be a pointer: found {s} in {s}\n",
                .{ i, param_type_name, fn_type_name },
            ));
        }

        if (param_info.pointer.is_const) continue;
        writable_param_types = writable_param_types ++ .{Resource(param_info.pointer.child)};
    }

    if (writable_param_types.len == 0) {
        return void;
    } else if (writable_param_types.len == 1) {
        return writable_param_types[0];
    } else {
        return std.meta.Tuple(writable_param_types);
    }
}

pub fn declareJob(
    comptime func: anytype,
    comptime resources: anytype,
) !DeclareJobReturnType(func) {
    const fn_type = @TypeOf(func);
    const fn_info = @typeInfo(fn_type).@"fn";
    const fn_type_name = @typeName(fn_type);

    if (fn_info.params.len == 0) {
        @compileError(std.fmt.comptimePrint(
            "Jobs must declare at least one parameter: in {s}",
            .{fn_type_name},
        ));
    }

    const resources_type_name = @typeName(@TypeOf(resources));
    if (fn_info.params.len != resources.len) {
        @compileError(std.fmt.comptimePrint(
            "Job expects {} resources but received {}: in {s}, resources {s}\n",
            .{ fn_info.params.len, resources.len, fn_type_name, resources_type_name },
        ));
    }

    var builder: *JobGraphBuilder = resources[0].builder;
    for (resources, 0..) |resource, i| {
        const param_type = fn_info.params[i].type.?;
        const param_info = @typeInfo(param_type);
        const param_type_name = @typeName(param_type);

        if (param_info != .pointer) {
            @compileError(std.fmt.comptimePrint(
                "Parameter {} must be a pointer: found {s} in {s}\n",
                .{ i, param_type_name, fn_type_name },
            ));
        }
        if (param_info.pointer.size != .one or param_info.pointer.is_allowzero) {
            @compileError(std.fmt.comptimePrint(
                "Parameter {} must be a single-item pointer without allowzero (*T or *const T): found {s} in {s}",
                .{ i, param_type_name, fn_type_name },
            ));
        }

        const resource_type = @TypeOf(resource).resource_type;
        const resource_type_name = @typeName(resource_type);
        const param_pointer_to_type = param_info.pointer.child;
        const param_pointer_to_type_name = @typeName(param_pointer_to_type);

        if (param_pointer_to_type != resource_type) {
            @compileError(std.fmt.comptimePrint(
                "Parameter {} points to {s}, but its resource contains {s} in {s}",
                .{ i, param_pointer_to_type_name, resource_type_name, fn_type_name },
            ));
        }
        if (i >= 1) {
            const prev_resource_type_name = @typeName(@TypeOf(resources[i - 1]).resource_type);
            if (resource.builder != builder) {
                @compileError(std.fmt.comptimePrint(
                    "Resources {} {s} and {} {s} belong to different JobGraphBuilders: in {s}\n",
                    .{ i, resource_type_name, i - 1, prev_resource_type_name, fn_type_name },
                ));
            }
        }

        builder = resource.builder;
    }

    const FnWrapper = struct {
        fn invoke(params: [*]const *anyopaque) anyerror!void {
            const ArgsType = std.meta.ArgsTuple(fn_type);
            var args: ArgsType = undefined;
            inline for (0..fn_info.params.len) |i| {
                args[i] = @ptrCast(@alignCast(params[i]));
            }
            return @call(.auto, func, args);
        }
    };

    try builder.job_fn.append(FnWrapper.invoke);
    const job_id = builder.job_fn.size - 1;

    var resource_ids: [fn_info.params.len]ResourceID = undefined;
    var writable_indices: [fn_info.params.len]u32 = undefined;
    var writable_params_count: u32 = 0;
    for (fn_info.params, 0..) |param, i| {
        resource_ids[i] = resources[i].id;
        const param_info = @typeInfo(param.type.?);
        if (param_info.pointer.is_const) {
            try builder.job_params.append(.{ .id = resource_ids[i], .is_writable = false });
            const producer = builder.resource_producer.elements[resource_ids[i]];
            if (producer != no_job) {
                try builder.edges.append(.{ .producer = producer, .consumer = job_id });
            }
        } else {
            try builder.resource_producer.append(job_id);
            try builder.resource_layout.append(builder.resource_layout.elements[resource_ids[i]]);
            try builder.resource_origin.append(builder.resource_origin.elements[resource_ids[i]]);
            const resource_id = builder.resource_producer.size - 1;
            try builder.job_params.append(.{ .id = resource_id, .is_writable = true });
            resource_ids[i] = resource_id;
            writable_indices[writable_params_count] = i;
            writable_params_count += 1;
        }
    }

    for (0..resource_ids.len) |i| {
        for (i + 1..resource_ids.len) |j| {
            const resource_id1 = resource_ids[i];
            const resource_id2 = resource_ids[j];
            if (resource_id1 == resource_id2) {
                @compileError(std.fmt.comptimePrint(
                    "Resources {} and {} reference the same resource version: in {s}, resources {s}\n",
                    .{ i, j, fn_type_name, resources_type_name },
                ));
            }
        }
    }

    try builder.job_params.endSlice();

    if (writable_params_count == 0) {
        return;
    }

    var return_value: DeclareJobReturnType(func) = undefined;
    for (0..writable_params_count) |i| {
        const writable_index = writable_indices[i];
        const param_type = fn_info.params[writable_index].type.?;
        const param_info = @typeInfo(param_type);
        const ResourceType = Resource(param_info.pointer.child);
        const resource = ResourceType{ .builder = builder, .id = resource_ids[writable_index] };
        if (writable_params_count == 1) {
            return resource;
        }
        return_value[i] = resource;
    }

    return return_value;
}

pub fn declareResourceCarry(comptime resource: anytype) !void {
    const builder: *JobGraphBuilder = resource.builder;
    const producer = builder.resource_producer.elements[resource.id];
    const resource_type_name = @typeName(@TypeOf(resource).resource_type);
    if (producer == no_job) {
        @compileError(std.fmt.comptimePrint(
            "Carry source must be a resource version produced by a job's writable parameter: resource version {} of type {s}\n",
            .{ resource.id, resource_type_name },
        ));
    }
    const origin = builder.resource_origin.elements[resource.id];
    for (0..builder.resource_carry.size) |i| {
        const carry = builder.resource_carry.elements[i];
        if (carry.to == origin) {
            @compileError(std.fmt.comptimePrint(
                "Carry target version {} of type {s} already has source version {}; cannot assign source version {}\n",
                .{ carry.to, resource_type_name, carry.from, resource.id },
            ));
        }
    }
    try builder.resource_carry.append(.{ .from = resource.id, .to = origin });
}

test "declareResource()" {
    comptime { // declareResource() runs at compile time
        var builder = JobGraphBuilder{};

        const resource1_type = u32;
        const resource1 = try builder.declareResource(resource1_type);
        const layout1 = ResourceLayout{
            .size = @sizeOf(resource1_type),
            .alignment = @alignOf(resource1_type),
        };

        const resource2_type = i32;
        const resource2 = try builder.declareResource(resource2_type);
        const layout2 = ResourceLayout{
            .size = @sizeOf(resource2_type),
            .alignment = @alignOf(resource2_type),
        };

        const resource3_type = u64;
        const resource3 = try builder.declareResource(resource3_type);
        const layout3 = ResourceLayout{
            .size = @sizeOf(resource3_type),
            .alignment = @alignOf(resource3_type),
        };

        // resources were assigned incremental ids
        try expectEqual(0, resource1.id);
        try expectEqual(1, resource2.id);
        try expectEqual(2, resource3.id);

        // all Resource specializations have the correct type
        try expectEqual(resource1_type, @TypeOf(resource1).resource_type);
        try expectEqual(resource2_type, @TypeOf(resource2).resource_type);
        try expectEqual(resource3_type, @TypeOf(resource3).resource_type);

        // all builder.resource_producer entries use the no_job sentinel
        try expectEqual(no_job, builder.resource_producer.elements[resource1.id]);
        try expectEqual(no_job, builder.resource_producer.elements[resource2.id]);
        try expectEqual(no_job, builder.resource_producer.elements[resource3.id]);

        // all builder.resource_origin entries match the expected id
        try expectEqual(resource1.id, builder.resource_origin.elements[resource1.id]);
        try expectEqual(resource2.id, builder.resource_origin.elements[resource2.id]);
        try expectEqual(resource3.id, builder.resource_origin.elements[resource3.id]);

        // all builder.resource_layout entries match the expected layout given the type specialization
        try expectEqual(layout1, builder.resource_layout.elements[resource1.id]);
        try expectEqual(layout2, builder.resource_layout.elements[resource2.id]);
        try expectEqual(layout3, builder.resource_layout.elements[resource3.id]);

        // all builder.resource_* arrays have the expected size
        try expectEqual(3, builder.resource_producer.size);
        try expectEqual(3, builder.resource_origin.size);
        try expectEqual(3, builder.resource_layout.size);

        // all resources have the same correct builder pointer assignment
        try expect(resource1.builder == &builder and
            resource1.builder == resource2.builder and
            resource1.builder == resource3.builder and
            resource2.builder == resource3.builder);
    }
}

test "declareJob()" {
    comptime { // declareJob() runs at compile time
        const TestFnWrapper = struct {
            fn testOneRead(read_param: *const u32) !void {
                if (read_param.* != 0xABC) {
                    return error.ReadUnexpectedValue;
                }
            }
            fn testTwoWrites(write_param0: *u64, write_param1: *i32) !void {
                write_param0.* = 123;
                write_param1.* = 456;
            }
            fn testOneWrite(write_param: *u32) !void {
                write_param.* = 123;
            }
            fn testOneReadOneWrite(read_param: *const u32, write_param: *u32) !void {
                if (read_param.* != 123) {
                    return error.ReadUnexpectedValue;
                }
                write_param.* = 456;
            }
            fn testTwoReads(read_param0: *const u32, read_param1: *const u32) !void {
                if (read_param0.* != 456 or read_param1.* != 456) {
                    return error.ReadUnexpectedValue;
                }
            }
        };

        var builder = JobGraphBuilder{};
        var job_id = 0; // increment job id with each declared job

        // test fn with one read
        const resource_test_one_read = try builder.declareResource(u32);
        try declareJob(TestFnWrapper.testOneRead, .{resource_test_one_read});
        const test_one_read_expected_job_id = job_id;
        var test_one_read_value: u32 = 0xABC;
        const test_one_read_args: [1]*anyopaque = .{@ptrCast(&test_one_read_value)};
        // fn pointer exists in table indexed by expected job id
        try builder.job_fn.elements[test_one_read_expected_job_id](&test_one_read_args);
        const test_one_read_params_subslice = try builder.job_params.subslice(test_one_read_expected_job_id);
        try expectEqual( // the job params subslice indexed by the expected job id contains 1 value
            1,
            test_one_read_params_subslice.len,
        );
        try expectEqual( // the value contained in the job params subslice has the expected resource id and writability
            JobParam{ .id = resource_test_one_read.id, .is_writable = false },
            test_one_read_params_subslice[0],
        );
        try expectEqual( // no edge was created because the resource didn't originate from a prior write
            0,
            builder.edges.size,
        );

        job_id += 1;

        // test fn with two writes
        const resource_test_two_writes_in0 = try builder.declareResource(u64);
        const resource_test_two_writes_in1 = try builder.declareResource(i32);
        const resource_test_two_writes_out0, const resource_test_two_writes_out1 = try declareJob(
            TestFnWrapper.testTwoWrites,
            .{ resource_test_two_writes_in0, resource_test_two_writes_in1 },
        );
        const test_two_writes_expected_job_id = job_id;
        var test_two_writes_initial_value0: u64 = 0;
        var test_two_writes_initial_value1: i32 = 0;
        const test_two_writes_args: [2]*anyopaque = .{
            @ptrCast(&test_two_writes_initial_value0),
            @ptrCast(&test_two_writes_initial_value1),
        };
        // fn pointer exists in the table indexed by expected job id and wrote the two expected values
        try builder.job_fn.elements[test_two_writes_expected_job_id](&test_two_writes_args);
        try expectEqual(123, test_two_writes_initial_value0);
        try expectEqual(456, test_two_writes_initial_value1);
        const test_two_writes_params_subslice = try builder.job_params.subslice(test_two_writes_expected_job_id);
        try expectEqual( // the job params subslice indexed by the expected job id contains 2 values
            2,
            test_two_writes_params_subslice.len,
        );
        try expectEqual( // the first value contained in the job params subslice has the expected resource id and writability
            JobParam{ .id = resource_test_two_writes_out0.id, .is_writable = true },
            test_two_writes_params_subslice[0],
        );
        try expectEqual( // the second value contained in the job params subslice has the expected resource id and writability
            JobParam{ .id = resource_test_two_writes_out1.id, .is_writable = true },
            test_two_writes_params_subslice[1],
        );
        try expectEqual( // the first expected resource producer entry was appended
            test_two_writes_expected_job_id,
            builder.resource_producer.elements[resource_test_two_writes_out0.id],
        );
        try expectEqual( // the second expected resource producer entry was appended
            test_two_writes_expected_job_id,
            builder.resource_producer.elements[resource_test_two_writes_out1.id],
        );
        try expectEqual( // the first expected resource layout entry was appended
            builder.resource_layout.elements[resource_test_two_writes_in0.id],
            builder.resource_layout.elements[resource_test_two_writes_out0.id],
        );
        try expectEqual( // the second expected resource layout entry was appended
            builder.resource_layout.elements[resource_test_two_writes_in1.id],
            builder.resource_layout.elements[resource_test_two_writes_out1.id],
        );
        try expectEqual( // the first expected resource origin entry was appended
            resource_test_two_writes_in0.id,
            builder.resource_origin.elements[resource_test_two_writes_out0.id],
        );
        try expectEqual( // the second expected resource origin entry was appended
            resource_test_two_writes_in1.id,
            builder.resource_origin.elements[resource_test_two_writes_out1.id],
        );
        try expectEqual( // no edge was created because the resources aren't reads to prior writes
            0,
            builder.edges.size,
        );

        job_id += 1;

        // test a diamond subgraph starting with one write, then fanning out to 2x one read one write, then fanning in to two reads
        const resource_test_one_write_in = try builder.declareResource(u32);
        const resource_test_one_write_out = try declareJob(
            TestFnWrapper.testOneWrite,
            .{resource_test_one_write_in},
        );
        const test_one_write_expected_job_id = job_id;
        var test_one_write_initial_value: u32 = 0;
        const test_one_write_args: [1]*anyopaque = .{@ptrCast(&test_one_write_initial_value)};
        // fn pointer exists in the table indexed by expected job id and wrote the expected value
        try builder.job_fn.elements[test_one_write_expected_job_id](&test_one_write_args);
        try expectEqual(123, test_one_write_initial_value);
        const test_one_write_params_subslice = try builder.job_params.subslice(test_one_write_expected_job_id);
        try expectEqual( // the job params subslice indexed by the expected job id contains 1 value
            1,
            test_one_write_params_subslice.len,
        );
        try expectEqual( // the value contained in the job params subslice has the expected resource id and writability
            JobParam{ .id = resource_test_one_write_out.id, .is_writable = true },
            test_one_write_params_subslice[0],
        );
        try expectEqual( // the expected resource producer entry was appended
            test_one_write_expected_job_id,
            builder.resource_producer.elements[resource_test_one_write_out.id],
        );
        try expectEqual( // the expected resource layout entry was appended
            builder.resource_layout.elements[resource_test_one_write_in.id],
            builder.resource_layout.elements[resource_test_one_write_out.id],
        );
        try expectEqual( // the expected resource origin entry was appended
            resource_test_one_write_in.id,
            builder.resource_origin.elements[resource_test_one_write_out.id],
        );
        try expectEqual( // no edge was created because the resource didn't originate from a prior write
            0,
            builder.edges.size,
        );

        job_id += 1;

        const resource_test_one_read_one_write_fn0_out = try declareJob(
            TestFnWrapper.testOneReadOneWrite,
            .{ resource_test_one_write_out, resource_test_one_write_out }, // read the last job's write, and get a successor resource to write to
        );
        const test_one_read_one_write_fn0_expected_job_id = job_id;
        var test_one_read_one_write_fn0_initial_value: u32 = 0;
        const test_one_read_one_write_fn0_args: [2]*anyopaque = .{
            @ptrCast(&test_one_write_initial_value), // read the last job's write
            @ptrCast(&test_one_read_one_write_fn0_initial_value),
        };
        // fn pointer exists in the table indexed by expected job id and wrote the expected value
        try builder.job_fn.elements[test_one_read_one_write_fn0_expected_job_id](&test_one_read_one_write_fn0_args);
        try expectEqual(456, test_one_read_one_write_fn0_initial_value);
        const test_one_read_one_write_fn0_params_subslice = try builder.job_params.subslice(test_one_read_one_write_fn0_expected_job_id);
        try expectEqual( // the job params subslice indexed by the expected job id contains 2 values
            2,
            test_one_read_one_write_fn0_params_subslice.len,
        );
        try expectEqual( // the first value contained in the job params subslice has the expected resource id and writability
            JobParam{ .id = resource_test_one_write_out.id, .is_writable = false },
            test_one_read_one_write_fn0_params_subslice[0],
        );
        try expectEqual( // the second value contained in the job params subslice has the expected resource id and writability
            JobParam{ .id = resource_test_one_read_one_write_fn0_out.id, .is_writable = true },
            test_one_read_one_write_fn0_params_subslice[1],
        );
        try expectEqual( // the expected resource producer entry was appended
            test_one_read_one_write_fn0_expected_job_id,
            builder.resource_producer.elements[resource_test_one_read_one_write_fn0_out.id],
        );
        try expectEqual( // the expected resource layout entry was appended
            builder.resource_layout.elements[resource_test_one_write_in.id],
            builder.resource_layout.elements[resource_test_one_read_one_write_fn0_out.id],
        );
        try expectEqual( // the expected resource origin entry was appended
            resource_test_one_write_in.id,
            builder.resource_origin.elements[resource_test_one_read_one_write_fn0_out.id],
        );
        try expectEqual( // one edge was created because of the read from a prior read
            1,
            builder.edges.size,
        );
        try expectEqual( // the first edge has the expected producer and consumer
            Edge{ .producer = test_one_write_expected_job_id, .consumer = test_one_read_one_write_fn0_expected_job_id },
            builder.edges.elements[0],
        );

        job_id += 1;

        const resource_test_one_read_one_write_fn1_out = try declareJob(
            TestFnWrapper.testOneReadOneWrite,
            .{ resource_test_one_write_out, resource_test_one_write_out }, // read the job before the last's write, and get a different successor resource to write to
        );
        const test_one_read_one_write_fn1_expected_job_id = job_id;
        var test_one_read_one_write_fn1_initial_value: u32 = 0;
        const test_one_read_one_write_fn1_args: [2]*anyopaque = .{
            @ptrCast(&test_one_write_initial_value), // read the job before the last's write
            @ptrCast(&test_one_read_one_write_fn1_initial_value),
        };
        // fn pointer exists in the table indexed by expected job id and wrote the expected value
        try builder.job_fn.elements[test_one_read_one_write_fn1_expected_job_id](&test_one_read_one_write_fn1_args);
        try expectEqual(456, test_one_read_one_write_fn1_initial_value);
        const test_one_read_one_write_fn1_params_subslice = try builder.job_params.subslice(test_one_read_one_write_fn1_expected_job_id);
        try expectEqual( // the job params subslice indexed by the expected job id contains 2 values
            2,
            test_one_read_one_write_fn1_params_subslice.len,
        );
        try expectEqual( // the first value contained in the job params subslice has the expected resource id and writability
            JobParam{ .id = resource_test_one_write_out.id, .is_writable = false },
            test_one_read_one_write_fn1_params_subslice[0],
        );
        try expectEqual( // the second value contained in the job params subslice has the expected resource id and writability
            JobParam{ .id = resource_test_one_read_one_write_fn1_out.id, .is_writable = true },
            test_one_read_one_write_fn1_params_subslice[1],
        );
        try expectEqual( // the expected resource producer entry was appended
            test_one_read_one_write_fn1_expected_job_id,
            builder.resource_producer.elements[resource_test_one_read_one_write_fn1_out.id],
        );
        try expectEqual( // the expected resource layout entry was appended
            builder.resource_layout.elements[resource_test_one_write_in.id],
            builder.resource_layout.elements[resource_test_one_read_one_write_fn1_out.id],
        );
        try expectEqual( // the expected resource origin entry was appended
            resource_test_one_write_in.id,
            builder.resource_origin.elements[resource_test_one_read_one_write_fn1_out.id],
        );
        try expectEqual( // a second edge was created because of the read from a prior read
            2,
            builder.edges.size,
        );
        try expectEqual( // the second edge has the expected producer and consumer
            Edge{ .producer = test_one_write_expected_job_id, .consumer = test_one_read_one_write_fn1_expected_job_id },
            builder.edges.elements[1],
        );

        job_id += 1;

        try declareJob(
            TestFnWrapper.testTwoReads,
            .{ resource_test_one_read_one_write_fn0_out, resource_test_one_read_one_write_fn1_out },
        );
        const test_two_reads_expected_job_id = job_id;
        const test_two_reads_args: [2]*anyopaque = .{
            @ptrCast(&test_one_read_one_write_fn0_initial_value),
            @ptrCast(&test_one_read_one_write_fn1_initial_value),
        };
        // fn pointer exists in the table indexed by expected job id
        try builder.job_fn.elements[test_two_reads_expected_job_id](&test_two_reads_args);
        const test_two_reads_params_subslice = try builder.job_params.subslice(test_two_reads_expected_job_id);
        try expectEqual( // the job params subslice indexed by the expected job id contains 2 values
            2,
            test_two_reads_params_subslice.len,
        );
        try expectEqual( // the first value contained in the job params subslice has the expected resource id and writability
            JobParam{ .id = resource_test_one_read_one_write_fn0_out.id, .is_writable = false },
            test_two_reads_params_subslice[0],
        );
        try expectEqual( // the second value contained in the job params subslice has the expected resource id and writability
            JobParam{ .id = resource_test_one_read_one_write_fn1_out.id, .is_writable = false },
            test_two_reads_params_subslice[1],
        );
        try expectEqual( // two more edges were created because of the two reads from different resource versions
            4,
            builder.edges.size,
        );
        try expectEqual( // the third edge has the expected producer and consumer
            Edge{ .producer = test_one_read_one_write_fn0_expected_job_id, .consumer = test_two_reads_expected_job_id },
            builder.edges.elements[2],
        );
        try expectEqual( // the fourth edge has the expected producer and consumer
            Edge{ .producer = test_one_read_one_write_fn1_expected_job_id, .consumer = test_two_reads_expected_job_id },
            builder.edges.elements[3],
        );
    }
}

test "declareResourceCarry()" {
    comptime { // declareResourceCarry runs at compile time
        const TestFnWrapper = struct {
            fn testFn(read_param: *const u32, write_param: *u32) !void {
                _ = read_param;
                _ = write_param;
            }
        };
        var builder = JobGraphBuilder{};
        const resource0 = try builder.declareResource(u32);
        const resource1 = try declareJob(
            TestFnWrapper.testFn,
            .{ resource0, resource0 },
        );
        const resource2 = try declareJob(
            TestFnWrapper.testFn,
            .{ resource1, resource1 },
        );
        try declareResourceCarry(resource2);
        try expectEqual( // resource carry table has one entry
            1,
            builder.resource_carry.size,
        );
        try expectEqual( // the resource carry table entry has the expected resources ids assigned to .from and .to
            Carry{ .from = resource2.id, .to = resource0.id },
            builder.resource_carry.elements[0],
        );
    }
}
