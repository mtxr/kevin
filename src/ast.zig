//! AST produced by the Markdown parser. Everything is allocated from a single
//! arena; string fields are slices into the (arena-owned) file buffer whenever
//! possible.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Arg = struct {
    name: []const u8,
    required: bool,
};

pub const FlagType = enum {
    string,
    number,
    boolean,

    pub fn label(t: FlagType) []const u8 {
        return switch (t) {
            .string => "STRING",
            .number => "NUMBER",
            .boolean => "",
        };
    }
};

pub const Flag = struct {
    /// Environment variable name injected into the task.
    name: []const u8,
    /// e.g. "-p"
    short: ?[]const u8 = null,
    /// e.g. "--port"
    long: ?[]const u8 = null,
    /// Omitted `type` means boolean.
    ftype: FlagType = .boolean,
    desc: []const u8 = "",
    choices: []const []const u8 = &.{},
    required: bool = false,
};

pub const CodeBlock = struct {
    /// First word of the info string (may be empty).
    lang: []const u8,
    code: []const u8,
    /// 1-based line of the opening fence.
    line: usize,
};

pub const Command = struct {
    name: []const u8,
    description: []const u8 = "",
    args: std.ArrayList(Arg) = .empty,
    flags: std.ArrayList(Flag) = .empty,
    blocks: std.ArrayList(CodeBlock) = .empty,
    children: std.ArrayList(*Command) = .empty,
    /// Absolute path of the Markdown file that declared this command.
    source_path: []const u8 = "",
    /// Line of the declaring heading (used to merge several inline tasks
    /// that share one heading).
    decl_line: usize = 0,

    pub fn findIndex(self: *const Command, name: []const u8) ?usize {
        for (self.children.items, 0..) |c, i| {
            if (std.mem.eql(u8, c.name, name)) return i;
        }
        return null;
    }

    pub fn find(self: *const Command, name: []const u8) ?*Command {
        const i = self.findIndex(name) orelse return null;
        return self.children.items[i];
    }
};

/// Merge `from`'s subtree into `into`. Pure namespaces are merged
/// recursively; on a real conflict the later file wins and a warning is
/// recorded.
pub fn merge(
    arena: Allocator,
    into: *Command,
    from: *Command,
    warnings: *std.ArrayList([]const u8),
) Allocator.Error!void {
    if (into.description.len == 0) into.description = from.description;
    for (from.children.items) |child| {
        const idx = into.findIndex(child.name) orelse {
            try into.children.append(arena, child);
            continue;
        };
        const existing = into.children.items[idx];
        if (existing.blocks.items.len == 0 and child.blocks.items.len == 0) {
            try merge(arena, existing, child, warnings);
            continue;
        }
        try warnings.append(arena, try std.fmt.allocPrint(
            arena,
            "command '{s}' defined in {s} overrides the one from {s}",
            .{ child.name, child.source_path, existing.source_path },
        ));
        into.children.items[idx] = child;
    }
}
