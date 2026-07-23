const std = @import("std");
const Testspec = @import("Testspec.zig");

var program_name: []const u8 = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    var args_it = init.minimal.args.iterate();

    program_name = args_it.next().?;
    const cmd = args_it.next() orelse {
        usage("missing command to run");
    };
    const argv = try parseCmd(arena, cmd);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout_w = &stdout_writer.interface;

    const cwd = std.Io.Dir.cwd();

    var seen_testfile = false;
    var failed = false;
    while (args_it.next()) |arg| {
        seen_testfile = true;
        const contents = cwd.readFileAlloc(io, arg, arena, .unlimited) catch |err| {
            fatal("cannot read '{s}': {t}", .{ arg, err });
        };
        const testspec = Testspec.parse(arena, contents) catch |err| {
            fatal("failed to parse '{s}': {t}", .{ arg, err });
        };

        for (testspec.testcases, 1..) |tc, i| {
            const result = runCmd(io, arena, argv, tc.input) catch |err| {
                fatal("failed to run '{s}': {t}", .{ cmd, err });
            };
            if (result.stderr.len > 0) {
                std.debug.print("{s}: unexpected '{s}' stderr output:\n{s}", .{ program_name, cmd, result.stderr });
            }

            if (!std.mem.eql(u8, result.stdout, tc.output)) {
                failed = true;
                const header = try std.fmt.allocPrint(arena, "=== Test #{d} failed ===", .{i});
                try stdout_w.print("{s}\n", .{header});
                try padPrint(stdout_w, "------- Input --------", header.len);
                try stdout_w.print("\n{s}", .{tc.input});
                try padPrint(stdout_w, "------ Expected ------", header.len);
                try stdout_w.print("\n{s}", .{tc.output});
                try padPrint(stdout_w, "-------- Got ---------", header.len);
                try stdout_w.print("\n{s}", .{result.stdout});
                try stdout_w.flush();
            }
        }
    }
    if (!seen_testfile) {
        usage("missing path to testfile after command");
    }
    if (failed) {
        std.process.exit(1);
    }
}

fn parseCmd(arena: std.mem.Allocator, cmd: []const u8) ![]const []const u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, cmd, ' ');
    while (it.next()) |tok| try tokens.append(arena, tok);
    return tokens.items;
}

/// Spawns a child process, sends the provided input to stdin, waits for it,
/// collecting stdout and stderr, and then returns.
///
/// Based on `std.process.run`.
pub fn runCmd(
    io: std.Io,
    arena: std.mem.Allocator,
    argv: []const []const u8,
    input: []const u8,
) !std.process.RunResult {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var stdin = child.stdin.?;
    try stdin.writeStreamingAll(io, input);
    stdin.close(io);
    child.stdin = null;

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(arena, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    while (multi_reader.fill(64, .none)) |_| {
        if (std.Io.Limit.unlimited.toInt()) |limit| {
            if (stdout_reader.buffered().len > limit)
                return error.StreamTooLong;
        }
        if (std.Io.Limit.unlimited.toInt()) |limit| {
            if (stderr_reader.buffered().len > limit)
                return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    try multi_reader.checkAnyError();

    const term = try child.wait(io);

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer arena.free(stdout_slice);

    const stderr_slice = try multi_reader.toOwnedSlice(1);
    errdefer arena.free(stderr_slice);

    return .{
        .stdout = stdout_slice,
        .stderr = stderr_slice,
        .term = term,
    };
}

fn padPrint(w: *std.Io.Writer, comptime fmt: []const u8, len: usize) !void {
    try w.print(fmt, .{});
    const padding = len - fmt.len;
    try w.splatByteAll('-', padding);
}

fn usage(err: []const u8) noreturn {
    std.debug.print("{s}: {s}\nusage: {0s} COMMAND TESTFILE...\n", .{ program_name, err });
    std.process.exit(2);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("{s}: ", .{program_name});
    std.debug.print(format ++ "\n", args);
    std.process.exit(1);
}
