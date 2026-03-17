const std = @import("std");
const Testspec = @This();

testcases: []Testcase,

const Testcase = struct {
    input: []const u8,
    output: []const u8,
};

pub fn parse(arena: std.mem.Allocator, text: []const u8) !Testspec {
    var testcases: std.ArrayList(Testcase) = .empty;
    var block_it = std.mem.splitSequence(u8, text, "===\n");
    while (block_it.next()) |block| {
        var test_it = std.mem.splitSequence(u8, block, "---\n");
        const input = test_it.next() orelse return error.SyntaxError;
        const output = test_it.next() orelse return error.SyntaxError;
        try testcases.append(arena, .{
            .input = input,
            .output = output,
        });
    }
    return .{
        .testcases = testcases.items,
    };
}
