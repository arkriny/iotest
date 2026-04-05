const std = @import("std");
const Testspec = @import("Testspec.zig");

pub fn main() !void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var args_it = try std.process.argsWithAllocator(arena);
    _ = args_it.skip(); // program name
    const cmd = args_it.next() orelse {
        usage("missing command to run");
    };
    const argv = try parseCmd(arena, cmd);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout_w = &stdout_writer.interface;

    const cwd = std.fs.cwd();

    var seen_testfile = false;
    var failed = false;
    while (args_it.next()) |arg| {
        seen_testfile = true;
        const contents = cwd.readFileAlloc(arena, arg, 1 << 31) catch |err| {
            fatal("cannot read '{s}': {t}", .{ arg, err });
        };
        const testspec = Testspec.parse(arena, contents) catch |err| {
            fatal("failed to parse '{s}': {t}", .{ arg, err });
        };

        for (testspec.testcases, 1..) |tc, i| {
            const result = runCmd(arena, argv, tc.input) catch |err| {
                fatal("failed to run '{s}': {t}", .{ cmd, err });
            };
            if (result.stderr.len > 0) {
                std.debug.print("iotest: unexpected '{s}' stderr output:\n{s}", .{ cmd, result.stderr });
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
/// Based on `std.process.Child.run`.
pub fn runCmd(
    arena: std.mem.Allocator,
    argv: []const []const u8,
    input: []const u8,
) !std.process.Child.RunResult {
    var child: std.process.Child = .init(argv, arena);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;

    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
    }

    var stdin = child.stdin.?;
    try stdin.writeAll(input);
    stdin.close();
    child.stdin = null;

    try child.collectOutput(arena, &stdout, &stderr, 1 << 31);
    return .{
        .stdout = stdout.items,
        .stderr = stderr.items,
        .term = try child.wait(),
    };
}

fn padPrint(w: *std.Io.Writer, comptime fmt: []const u8, len: usize) !void {
    try w.print(fmt, .{});
    const padding = len - fmt.len;
    try w.splatByteAll('-', padding);
}

fn usage(err: []const u8) noreturn {
    std.debug.print("iotest: {s}\nUsage: iotest COMMAND TESTFILE...\n", .{err});
    std.process.exit(2);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("iotest: " ++ format ++ "\n", args);
    std.process.exit(1);
}
