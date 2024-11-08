const std = @import("std");
const builtin = @import("builtin");
const sig = @import("sig.zig");
const pt = @import("prettytable");
const math = std.math;

const Decl = std.builtin.Type.Declaration;
const Duration = sig.time.Duration;

pub const BenchTimeUnit = enum {
    nanos,
    millis,
    seconds,

    pub fn convertDuration(self: BenchTimeUnit, duration: Duration) u64 {
        return switch (self) {
            .nanos => duration.asNanos(),
            .millis => duration.asMillis(),
            .seconds => duration.asSecs(),
        };
    }
};

/// to run gossip benchmarks:
/// zig build benchmark -- gossip
pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var std_logger = try sig.trace.ChannelPrintLogger.init(.{
        .allocator = allocator,
        .max_level = .info, // NOTE: change to debug to see all logs
        .max_buffer = 1 << 15,
    });
    defer std_logger.deinit();
    const logger = std_logger.logger();

    if (builtin.mode == .Debug) logger.warn().log("warning: running benchmark in Debug mode");

    var cli_args = try std.process.argsWithAllocator(allocator);
    defer cli_args.deinit();

    _ = cli_args.skip();

    const maybe_filter = cli_args.next();
    const filter = blk: {
        if (maybe_filter) |filter| {
            logger.info().logf("filtering benchmarks with prefix: {s}", .{filter});
            break :blk filter;
        } else {
            logger.info().logf("no filter: running all benchmarks", .{});
            break :blk "";
        }
    };

    const max_time_per_bench = Duration.fromSecs(5); // !!
    const run_all_benchmarks = filter.len == 0;

    if (std.mem.startsWith(u8, filter, "swissmap") or run_all_benchmarks) {
        try benchmarkCSV(
            allocator,
            logger,
            @import("accountsdb/swiss_map.zig").BenchmarkSwissMap,
            max_time_per_bench,
            .nanos,
        );
    }

    if (std.mem.startsWith(u8, filter, "accounts_db") or run_all_benchmarks) {
        var run_all = false;
        if (std.mem.eql(u8, "accounts_db", filter) or run_all_benchmarks) {
            run_all = true;
        }

        if (std.mem.eql(u8, "accounts_db_readwrite", filter) or run_all) {
            try benchmarkCSV(
                allocator,
                logger,
                @import("accountsdb/db.zig").BenchmarkAccountsDB,
                max_time_per_bench,
                .millis,
            );
        }

        if (std.mem.eql(u8, "accounts_db_snapshot", filter) or run_all) blk: {
            // NOTE: for this benchmark you need to setup a snapshot in test-data/snapshot_bench
            // and run as a binary ./zig-out/bin/... so the open file limits are ok
            const dir_path = sig.TEST_DATA_DIR ++ "bench_snapshot/";
            var snapshot_dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
                logger.debug().logf("[accounts_db_snapshot]: need to setup a snapshot in {s} for this benchmark...", .{dir_path});
                break :blk;
            };
            snapshot_dir.close();

            try benchmarkCSV(
                allocator,
                logger,
                @import("accountsdb/db.zig").BenchmarkAccountsDBSnapshotLoad,
                max_time_per_bench,
                .millis,
            );
        }
    }

    if (std.mem.startsWith(u8, filter, "socket_utils") or run_all_benchmarks) {
        try benchmarkCSV(
            allocator,
            logger,
            @import("net/socket_utils.zig").BenchmarkPacketProcessing,
            max_time_per_bench,
            .millis,
        );
    }

    if (std.mem.startsWith(u8, filter, "gossip") or run_all_benchmarks) {
        try benchmarkCSV(
            allocator,
            logger,
            @import("gossip/service.zig").BenchmarkGossipServiceGeneral,
            max_time_per_bench,
            .millis,
        );
        try benchmarkCSV(
            allocator,
            logger,
            @import("gossip/service.zig").BenchmarkGossipServicePullRequests,
            max_time_per_bench,
            .millis,
        );
    }

    if (std.mem.startsWith(u8, filter, "sync") or run_all_benchmarks) {
        try benchmarkCSV(
            allocator,
            logger,
            @import("sync/channel.zig").BenchmarkChannel,
            max_time_per_bench,
            .nanos,
        );
    }

    if (std.mem.startsWith(u8, filter, "ledger") or run_all_benchmarks) {
        try benchmarkCSV(
            allocator,
            logger,
            @import("ledger/benchmarks.zig").BenchmarkLedger,
            max_time_per_bench,
            .nanos,
        );
        try benchmarkCSV(
            allocator,
            logger,
            @import("ledger/benchmarks.zig").BenchmarkLedgerSlow,
            max_time_per_bench,
            .millis,
        );
    }

    if (std.mem.startsWith(u8, filter, "bincode") or run_all_benchmarks) {
        try benchmarkCSV(
            allocator,
            logger,
            @import("bincode/benchmarks.zig").BenchmarkEntry,
            max_time_per_bench,
            .nanos,
        );
    }

    // NOTE: we dont support CSV output on this method so all results are printed as debug
    if (std.mem.startsWith(u8, filter, "geyser") or run_all_benchmarks) {
        logger.debug().log("Geyser Streaming Benchmark:");
        try @import("geyser/lib.zig").benchmark.runBenchmark(logger);
    }
}

/// src: https://github.com/Hejsil/zig-bench
/// NOTE: we only support Nanos for now beacuse we also support floats which makes it harder to implement.
pub fn benchmarkCSV(
    allocator: std.mem.Allocator,
    logger: sig.trace.Logger,
    comptime B: type,
    max_time_per_benchmark: Duration,
    time_unit: BenchTimeUnit,
) !void {
    const has_args = if (@hasDecl(B, "args")) true else false;
    const args = if (has_args) B.args else [_]void{{}};
    const min_iterations = if (@hasDecl(B, "min_iterations")) B.min_iterations else 10_000;
    const max_iterations = if (@hasDecl(B, "max_iterations")) B.max_iterations else 100_000;

    const functions = comptime blk: {
        var res: []const Decl = &[_]Decl{};
        for (@typeInfo(B).Struct.decls) |decl| {
            if (@typeInfo(@TypeOf(@field(B, decl.name))) != .Fn)
                continue;
            res = res ++ [_]Decl{decl};
        }

        break :blk res;
    };

    if (functions.len == 0) {
        @compileError("No benchmarks to run.");
    }

    const results_dir = try std.fs.cwd().makeOpenPath(sig.BENCHMARK_RESULTS_DIR, .{});
    var raw_benchmark_name = @typeName(B);

    // find the last dot in the benchmark name (since imports are usually x.a.b.YBenchmark, this
    // gets us to YBenchmark)
    var index: u64 = 0;
    while (true) {
        const maybe_index = std.mem.indexOf(u8, raw_benchmark_name[index + 1 ..], ".");
        index += 1;
        index += maybe_index orelse break;
    }
    const benchmark_name = raw_benchmark_name[index..];
    results_dir.makeDir(benchmark_name) catch |err| {
        switch (err) {
            std.fs.Dir.MakeError.PathAlreadyExists => {},
            else => return err,
        }
    };

    var is_multi_return = try std.ArrayList(bool).initCapacity(allocator, functions.len);
    defer is_multi_return.deinit();

    inline for (functions) |def| {
        var fmt_buf: [512]u8 = undefined;
        const file_name_average = try std.fmt.bufPrint(&fmt_buf, "{s}/{s}.csv", .{ benchmark_name, def.name });
        const file_average = try results_dir.createFile(file_name_average, .{ .read = true });
        defer file_average.close();
        const writer_average = file_average.writer();
        logger.debug().logf("writing benchmark results to {s}", .{file_name_average});

        var fmt_buf2: [512]u8 = undefined;
        const file_name_runtimes = try std.fmt.bufPrint(&fmt_buf2, "{s}/{s}_runtimes.csv", .{ benchmark_name, def.name });
        const file_runtimes = try results_dir.createFile(file_name_runtimes, .{ .read = true });
        defer file_runtimes.close();
        const writer_runtimes = file_runtimes.writer();

        inline for (args, 0..) |arg, arg_i| {
            const arg_name = if (has_args) arg.name else "_";
            logger.debug().logf("benchmarking arg: {d}/{d}: {s}", .{ arg_i + 1, args.len, arg_name });

            const benchFunction = @field(B, def.name);
            // NOTE: @TypeOf guarantees no runtime side-effects of argument expressions.
            // this means the function will *not* be called, this is just computing the return
            // type.
            const arguments = blk: {
                // NOTE: to know if we should pass in the time unit we
                // check the input params of the function, so any multi-return
                // function NEEDS to have the time unit as the first parameter
                const info = @typeInfo(@TypeOf(benchFunction)).Fn;
                const has_time_unit = info.params.len > 0 and info.params[0].type.? == BenchTimeUnit;
                const time_arg = if (has_time_unit) .{time_unit} else .{};
                const other_arg = if (@TypeOf(arg) != void) .{arg} else .{};
                break :blk time_arg ++ other_arg;
            };
            const ResultType: type = @TypeOf(try @call(.auto, benchFunction, arguments));
            const RuntimeType = blk: {
                switch (ResultType) {
                    // single value
                    Duration => {
                        try is_multi_return.append(false);
                        break :blk struct { result: u64 };
                    },
                    // multiple values
                    else => {
                        try is_multi_return.append(true);
                        break :blk ResultType;
                    },
                }
            };
            var runtimes: std.MultiArrayList(RuntimeType) = .{};
            defer runtimes.deinit(allocator);

            //
            var min: u64 = math.maxInt(u64);
            var max: u64 = 0;
            var sum: u64 = 0;

            // NOTE: these are set to valid values on first iteration
            const runtime_info = @typeInfo(RuntimeType).Struct;
            var sum_s: RuntimeType = undefined;
            var min_s: RuntimeType = undefined;
            var max_s: RuntimeType = undefined;

            //
            var ran_out_of_time = false;
            var runtime_timer = try sig.time.Timer.start();
            var iter_count: u64 = 0;
            while (iter_count < min_iterations or
                (iter_count < max_iterations and ran_out_of_time)) : (iter_count += 1)
            {
                switch (ResultType) {
                    Duration => {
                        const duration = try @call(.auto, benchFunction, arguments);
                        const runtime = time_unit.convertDuration(duration);
                        min = @min(runtime, min);
                        max = @max(runtime, max);
                        sum += runtime;
                        try runtimes.append(allocator, .{ .result = runtime });
                    },
                    else => {
                        const result = try @call(.auto, benchFunction, arguments);
                        try runtimes.append(allocator, result);

                        if (iter_count == 0) {
                            min_s = result;
                            max_s = result;
                            sum_s = result;
                        } else {
                            inline for (runtime_info.fields) |field| {
                                const f_max = @field(max_s, field.name);
                                const f_min = @field(min_s, field.name);
                                @field(max_s, field.name) = @max(@field(result, field.name), f_max);
                                @field(min_s, field.name) = @min(@field(result, field.name), f_min);
                                @field(sum_s, field.name) += @field(result, field.name);
                            }
                        }
                    },
                }
                ran_out_of_time = runtime_timer.read().asNanos() < max_time_per_benchmark.asNanos();
            }

            if (ran_out_of_time) {
                logger.debug().log("ran out of time...");
            }

            // print all runtimes, eg:
            //
            // benchmark, result
            // read_write (100k) (read), 1, 2, 3, 4,
            // read_write (100k) (write), 1, 2, 3, 4,
            switch (ResultType) {
                Duration => {
                    try writer_runtimes.print("{s}({s}), results", .{ def.name, arg_name });
                    for (runtimes.items(.result), 0..) |runtime, i| {
                        if (i != 0) try writer_runtimes.print(", ", .{});
                        try writer_runtimes.print("{d}", .{runtime});
                    }
                    try writer_runtimes.print("\n", .{});
                },
                else => {
                    inline for (runtime_info.fields, 0..) |field, j| {
                        try writer_runtimes.print("{s}({s}) ({s}), ", .{ def.name, arg_name, field.name });
                        const x: std.MultiArrayList(RuntimeType).Field = @enumFromInt(j);
                        for (runtimes.items(x), 0..) |runtime, i| {
                            if (i != 0) try writer_runtimes.print(", ", .{});
                            try writer_runtimes.print("{d}", .{runtime});
                        }
                        try writer_runtimes.print("\n", .{});
                    }
                },
            }

            // print aggregated results, eg:
            //
            // benchmark, read_min, read_max, read_mean, read_variance, write_min, write_max, write_mean, write_variance
            // read_write (100k), 1, 2, 3, 4, 1, 2, 3, 4
            // read_write (200k), 1, 2, 3, 4, 1, 2, 3, 4
            switch (ResultType) {
                Duration => {
                    // print column headers
                    if (arg_i == 0) {
                        try writer_average.print("{s}, min, max, mean, std_dev\n", .{def.name});
                    }
                    const mean = sum / iter_count;
                    var variance: u64 = 0;
                    for (runtimes.items(.result)) |runtime| {
                        const d = if (runtime > mean) runtime - mean else mean - runtime;
                        const d_sq = d *| d;
                        variance +|= d_sq;
                    }
                    variance /= iter_count;
                    const std_dev = std.math.sqrt(variance);

                    // print column results
                    try writer_average.print("{s}, {d}, {d}, {d}, {d}\n", .{ arg_name, min, max, mean, std_dev });
                },
                else => {
                    // print column headers
                    if (arg_i == 0) {
                        try writer_average.print("{s}, ", .{def.name});
                        inline for (runtime_info.fields, 0..) |field, i| {
                            if (i == runtime_info.fields.len - 1) {
                                // dont print trailing comma
                                try writer_average.print("{s}_min, {s}_max, {s}_mean, {s}_std_dev", .{ field.name, field.name, field.name, field.name });
                            } else {
                                try writer_average.print("{s}_min, {s}_max, {s}_mean, {s}_std_dev, ", .{ field.name, field.name, field.name, field.name });
                            }
                        }
                        try writer_average.print("\n", .{});
                    }

                    // print results
                    try writer_average.print("{s}, ", .{arg_name});
                    inline for (runtime_info.fields, 0..) |field, j| {
                        const f_max = @field(max_s, field.name);
                        const f_min = @field(min_s, field.name);
                        const f_sum = @field(sum_s, field.name);
                        const T = @TypeOf(f_sum);
                        const n_iters = switch (@typeInfo(T)) {
                            .Float => @as(T, @floatFromInt(iter_count)),
                            else => iter_count,
                        };
                        const f_mean = f_sum / n_iters;

                        var f_variance: T = 0;
                        const x: std.MultiArrayList(RuntimeType).Field = @enumFromInt(j);
                        for (runtimes.items(x)) |f_runtime| {
                            const d = if (f_runtime > f_mean) f_runtime - f_mean else f_mean - f_runtime;
                            switch (@typeInfo(T)) {
                                .Float => f_variance = d * d,
                                else => f_variance +|= d *| d,
                            }
                        }
                        f_variance /= n_iters;
                        const f_std_dev = std.math.sqrt(f_variance);

                        if (j == runtime_info.fields.len - 1) {
                            // dont print trailing comma
                            try writer_average.print("{d}, {d}, {any}, {any}", .{ f_max, f_min, f_mean, f_std_dev });
                        } else {
                            try writer_average.print("{d}, {d}, {any}, {any}, ", .{ f_max, f_min, f_mean, f_std_dev });
                        }
                    }
                    try writer_average.print("\n", .{});
                },
            }
        }
    }

    // print the results in a formatted table
    inline for (functions, 0..) |def, fcni| {
        var fmt_buf: [512]u8 = undefined;
        const file_name_average = try std.fmt.bufPrint(&fmt_buf, "{s}/{s}.csv", .{ benchmark_name, def.name });
        const file_average = try results_dir.openFile(file_name_average, .{});
        defer file_average.close();

        var table = pt.Table.init(allocator);
        defer table.deinit();
        var read_buf: [1024 * 1024]u8 = undefined;
        try table.readFrom(file_average.reader(), &read_buf, ",", true);

        if (!is_multi_return.items[fcni]) {
            // direct print works ok in this case
            try table.printstd();
        } else {
            // re-parse the return type
            const benchFunction = @field(B, def.name);
            // NOTE: @TypeOf guarantees no runtime side-effects of argument expressions.
            // this means the function will *not* be called, this is just computing the return
            // type.
            const arguments = blk: {
                // NOTE: to know if we should pass in the time unit we
                // check the input params of the function, so any multi-return
                // function NEEDS to have the time unit as the first parameter
                const info = @typeInfo(@TypeOf(benchFunction)).Fn;
                const has_time_unit = info.params.len > 0 and info.params[0].type.? == BenchTimeUnit;
                const time_arg = if (has_time_unit) .{time_unit} else .{};
                const other_arg = if (@TypeOf(args[0]) != void) .{args[0]} else .{};
                break :blk time_arg ++ other_arg;
            };
            const ResultType: type = @TypeOf(try @call(.auto, benchFunction, arguments));
            const RuntimeType = blk: {
                switch (ResultType) {
                    // single value
                    Duration => {
                        break :blk struct { result: u64 };
                    },
                    // multiple values
                    else => {
                        break :blk ResultType;
                    },
                }
            };
            const runtime_info = @typeInfo(RuntimeType).Struct;

            // organize the data into a table:
            // field_name,              field_name2
            // min, max, mean, std_dev  min, max, mean, std_dev
            const stat_titles: [4][]const u8 = .{ "min", "max", "mean", "std_dev" };
            const per_field_column_count = stat_titles.len;
            // first column is the field names
            const field_name_data = try allocator.alloc([]const u8, 1 + per_field_column_count * runtime_info.fields.len);
            field_name_data[0] = ""; // benchmark name is blank
            const stat_data_row = try allocator.alloc([]const u8, 1 + per_field_column_count * runtime_info.fields.len);
            stat_data_row[0] = def.name;
            var i: u64 = 1;
            var k: u64 = 1;

            inline for (runtime_info.fields) |field| {
                field_name_data[i] = field.name;
                i += 1;
                for (0..per_field_column_count - 1) |_| {
                    field_name_data[i] = "";
                    i += 1;
                }
                for (0..per_field_column_count) |j| {
                    stat_data_row[k] = stat_titles[j];
                    k += 1;
                }
            }

            var field_names_cells = std.ArrayList(pt.Cell).init(allocator);
            var stats_cells = std.ArrayList(pt.Cell).init(allocator);
            for (0..i) |cell_i| {
                try field_names_cells.append(try pt.Cell.init(allocator, field_name_data[cell_i]));
                try stats_cells.append(try pt.Cell.init(allocator, stat_data_row[cell_i]));
            }
            const field_name_row = pt.Row.init(allocator, field_names_cells);
            const stats_row = pt.Row.init(allocator, stats_cells);

            table.titles = field_name_row;
            try table.rows.insert(0, stats_row);
            try table.printstd();
        }
    }
}
