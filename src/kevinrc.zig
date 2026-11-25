//! `.kevinrc`: chooses which Markdown files kevin reads.
//!
//! One entry per line. Blank lines and full-line `#` comments are ignored,
//! `!entry` excludes files and anything else includes them. An entry is a
//! relative path with `/` separators: either a direct path or a path whose
//! last segment contains `*` (matches any run of characters within that one
//! segment). Nothing else is supported.
//!
//! This module is pure: parsing and matching never touch the disk. Resolution
//! asks a small file-system adapter (`list` and `real`, see `resolve`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const file_name = ".kevinrc";

pub const Rule = struct {
    /// 1-based line number in `.kevinrc`.
    line: usize,
    exclude: bool,
    /// Normalised relative path (`/` separators, no `.` segments).
    path: []const u8,
    /// Directory part of `path` ("" for the current directory).
    dir: []const u8,
    /// Last segment of `path`.
    name: []const u8,
    /// The last segment contains `*`.
    glob: bool,
};

pub const Parsed = struct {
    rules: []const Rule,
    warnings: []const []const u8,
};

fn warn(arena: Allocator, list: *std.ArrayList([]const u8), line: usize, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    try list.append(arena, try std.fmt.allocPrint(arena, "`.kevinrc` line {d}: " ++ fmt, .{line} ++ args));
}

/// Parses the text of a `.kevinrc`. Invalid entries become warnings and are skipped.
pub fn parse(arena: Allocator, text_in: []const u8) Allocator.Error!Parsed {
    var rules: std.ArrayList(Rule) = .empty;
    var warnings: std.ArrayList([]const u8) = .empty;
    var text = text_in;
    if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = text[3..];

    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        var entry = std.mem.trim(u8, raw, " \t\r");
        if (entry.len == 0 or entry[0] == '#') continue;
        var exclude = false;
        if (entry[0] == '!') {
            exclude = true;
            entry = std.mem.trim(u8, entry[1..], " \t");
        }
        if (entry.len == 0) {
            try warn(arena, &warnings, line_no, "an empty '!' entry is not supported", .{});
            continue;
        }

        const norm = try arena.dupe(u8, entry);
        std.mem.replaceScalar(u8, norm, '\\', '/');
        if (norm[0] == '/' or (norm.len >= 2 and norm[1] == ':')) {
            try warn(arena, &warnings, line_no, "'{s}' is outside the current directory (absolute paths are not allowed)", .{entry});
            continue;
        }
        if (norm[norm.len - 1] == '/') {
            try warn(arena, &warnings, line_no, "'{s}': a directory is not supported (name files or a '*' pattern)", .{entry});
            continue;
        }

        var segs: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, norm, '/');
        var bad: ?[]const u8 = null;
        while (it.next()) |seg| {
            if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
            if (std.mem.eql(u8, seg, "..")) {
                bad = "is outside the current directory ('..' is not allowed)";
                break;
            }
            try segs.append(arena, seg);
        }
        if (bad == null and segs.items.len == 0) bad = "is not a file name";
        if (bad == null) {
            for (segs.items, 0..) |seg, i| {
                if (std.mem.indexOf(u8, seg, "**") != null) {
                    bad = "'**' is not supported";
                    break;
                }
                if (i + 1 < segs.items.len and std.mem.indexOfScalar(u8, seg, '*') != null) {
                    bad = "'*' in a directory name is not supported (only the last segment may use '*')";
                    break;
                }
            }
        }
        if (bad) |why| {
            // A reason that starts with a quote is a complete sentence about the pattern.
            if (std.mem.startsWith(u8, why, "'")) {
                try warn(arena, &warnings, line_no, "'{s}': {s}", .{ entry, why });
            } else {
                try warn(arena, &warnings, line_no, "'{s}' {s}", .{ entry, why });
            }
            continue;
        }

        const path = try std.mem.join(arena, "/", segs.items);
        const name = segs.items[segs.items.len - 1];
        const dir = if (path.len > name.len) path[0 .. path.len - name.len - 1] else "";
        try rules.append(arena, .{
            .line = line_no,
            .exclude = exclude,
            .path = path,
            .dir = dir,
            .name = name,
            .glob = std.mem.indexOfScalar(u8, name, '*') != null,
        });
    }
    return .{ .rules = rules.items, .warnings = warnings.items };
}

/// Matches one path segment against a pattern whose only metacharacter is
/// `*` (any run of characters, possibly empty). A name starting with `.` is
/// matched only by a pattern that starts with `.` itself.
pub fn matchSegment(pattern: []const u8, name: []const u8) bool {
    if (name.len > 0 and name[0] == '.' and !(pattern.len > 0 and pattern[0] == '.')) return false;
    var p: usize = 0;
    var n: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (n < name.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            mark = n;
        } else if (p < pattern.len and pattern[p] == name[n]) {
            p += 1;
            n += 1;
        } else if (star) |s| {
            p = s + 1;
            mark += 1;
            n = mark;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

pub const Origin = union(enum) {
    default,
    /// `.kevinrc` line number of the include.
    include: usize,
    /// Line number of the include in the global `.kevinrc`.
    global: usize,
};

pub const Entry = struct {
    /// Relative path as written / listed.
    path: []const u8,
    /// Real absolute path (identity of the file).
    real: []const u8,
    origin: Origin,
    /// For `.global` entries: the path relative to the home directory, so a
    /// project-level exclude can name the file the way the global file did.
    rel: []const u8 = "",
};

pub const Excluded = struct {
    path: []const u8,
    /// `.kevinrc` line number of the exclude.
    line: usize,
};

pub const Result = struct {
    files: []const Entry,
    excluded: []const Excluded,
    warnings: []const []const u8,
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn join(arena: Allocator, dir: []const u8, name: []const u8) Allocator.Error![]const u8 {
    if (dir.len == 0) return name;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
}

fn relMatches(rel: []const u8, rule: Rule) bool {
    const slash = std.mem.lastIndexOfScalar(u8, rel, '/');
    const edir = if (slash) |s| rel[0..s] else "";
    const ename = if (slash) |s| rel[s + 1 ..] else rel;
    if (rule.glob) return std.mem.eql(u8, edir, rule.dir) and matchSegment(rule.name, ename);
    return std.mem.eql(u8, rel, rule.path);
}

fn entryMatches(arena: Allocator, e: Entry, rule: Rule, fs: anytype) bool {
    if (e.origin == .global and relMatches(e.rel, rule)) return true;
    const slash = std.mem.lastIndexOfScalar(u8, e.path, '/');
    const edir = if (slash) |s| e.path[0..s] else "";
    const ename = if (slash) |s| e.path[s + 1 ..] else e.path;
    if (rule.glob) return std.mem.eql(u8, edir, rule.dir) and matchSegment(rule.name, ename);
    if (std.mem.eql(u8, e.path, rule.path)) return true;
    // Defaults are found case-insensitively, so `!README.md` also drops `readme.md`.
    if (e.origin == .default and std.ascii.eqlIgnoreCase(e.path, rule.path)) return true;
    if (fs.real(arena, rule.path)) |r| return std.mem.eql(u8, r, e.real);
    return false;
}

/// Builds the file set: `defaults` first (relative paths, in order), then the
/// rules top to bottom. `fs` provides
/// `list(arena, dir) ![]const []const u8` (names of the files in a directory,
/// "" is the current one; a missing directory is empty) and
/// `real(arena, path) ?[]const u8` (absolute real path of a regular file or
/// symlink to one, null otherwise).
pub fn resolve(arena: Allocator, rules: []const Rule, defaults: []const []const u8, fs: anytype) !Result {
    return resolveLayered(arena, rules, &.{}, defaults, fs);
}

/// Like `resolve`, but the set starts with `seeds` (already resolved entries,
/// e.g. from the global `.kevinrc`), then the defaults, then the rules.
pub fn resolveLayered(arena: Allocator, rules: []const Rule, seeds: []const Entry, defaults: []const []const u8, fs: anytype) !Result {
    var files: std.ArrayList(Entry) = .empty;
    var excluded: std.ArrayList(Excluded) = .empty;
    var warnings: std.ArrayList([]const u8) = .empty;

    for (seeds) |e| try addUnique(arena, &files, e);
    for (defaults) |d| {
        const real = fs.real(arena, d) orelse continue;
        try addUnique(arena, &files, .{ .path = d, .real = real, .origin = .default });
    }
    for (rules) |rule| {
        if (rule.exclude) {
            var kept: std.ArrayList(Entry) = .empty;
            for (files.items) |e| {
                if (entryMatches(arena, e, rule, fs)) {
                    try excluded.append(arena, .{ .path = e.path, .line = rule.line });
                } else try kept.append(arena, e);
            }
            files = kept;
        } else if (rule.glob) {
            const names = try arena.dupe([]const u8, try fs.list(arena, rule.dir));
            std.mem.sort([]const u8, names, {}, lessThan);
            for (names) |n| {
                if (!matchSegment(rule.name, n)) continue;
                const path = try join(arena, rule.dir, n);
                const real = fs.real(arena, path) orelse continue;
                try addUnique(arena, &files, .{ .path = path, .real = real, .origin = .{ .include = rule.line } });
            }
        } else if (fs.real(arena, rule.path)) |real| {
            try addUnique(arena, &files, .{ .path = rule.path, .real = real, .origin = .{ .include = rule.line } });
        } else {
            try warn(arena, &warnings, rule.line, "'{s}' does not exist", .{rule.path});
        }
    }
    return .{ .files = files.items, .excluded = excluded.items, .warnings = warnings.items };
}

/// Environment variable that overrides the global `.kevinrc` location. Set
/// to an empty string (or a missing file) to disable the global file.
pub const global_env = "KEVIN_GLOBAL_RC";

/// Rewrites a warning produced for the global file so it names that file
/// ("global `.kevinrc` (<path>) line N: ..."), and says "home directory".
pub fn relabelGlobal(arena: Allocator, w: []const u8, path: []const u8) Allocator.Error![]const u8 {
    const prefix = "`.kevinrc` line ";
    if (!std.mem.startsWith(u8, w, prefix)) return w;
    const body = try std.mem.replaceOwned(u8, arena, w[prefix.len..], "the current directory", "the home directory");
    return std.fmt.allocPrint(arena, "global `.kevinrc` ({s}) line {s}", .{ path, body });
}

fn addUnique(arena: Allocator, files: *std.ArrayList(Entry), e: Entry) Allocator.Error!void {
    for (files.items) |x| if (std.mem.eql(u8, x.real, e.real)) return;
    try files.append(arena, e);
}

// ------------------------------------------------------------------- tests

/// In-memory file system for the tests: `files` are relative paths.
const FakeFs = struct {
    files: []const []const u8,

    fn real(self: FakeFs, arena: Allocator, path: []const u8) ?[]const u8 {
        for (self.files) |f| {
            if (std.mem.eql(u8, f, path)) return std.fmt.allocPrint(arena, "/w/{s}", .{f}) catch null;
        }
        return null;
    }

    fn list(self: FakeFs, arena: Allocator, dir: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (self.files) |f| {
            const slash = std.mem.lastIndexOfScalar(u8, f, '/');
            const fdir = if (slash) |s| f[0..s] else "";
            if (std.mem.eql(u8, fdir, dir)) try out.append(arena, if (slash) |s| f[s + 1 ..] else f);
        }
        return out.items;
    }
};

fn paths(arena: Allocator, res: Result) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (res.files, 0..) |f, i| {
        if (i > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, f.path);
    }
    return out.items;
}

fn run(arena: Allocator, rc: []const u8, defaults: []const []const u8, files: []const []const u8) !Result {
    const parsed = try parse(arena, rc);
    return resolve(arena, parsed.rules, defaults, FakeFs{ .files = files });
}

test "comments, blank lines, BOM and CRLF" {
    var st = std.heap.ArenaAllocator.init(testing.allocator);
    defer st.deinit();
    const p = try parse(st.allocator(), "\xEF\xBB\xBF# comment\r\n\r\n  # indented comment\r\n  a.md  \r\n!b.md\r\n\r\n");
    try testing.expectEqual(@as(usize, 2), p.rules.len);
    try testing.expectEqualStrings("a.md", p.rules[0].path);
    try testing.expectEqual(@as(usize, 4), p.rules[0].line);
    try testing.expect(!p.rules[0].exclude);
    try testing.expect(p.rules[1].exclude);
    try testing.expectEqual(@as(usize, 5), p.rules[1].line);
    try testing.expectEqual(@as(usize, 0), p.warnings.len);
}

test "backslashes and ./ are normalised" {
    var st = std.heap.ArenaAllocator.init(testing.allocator);
    defer st.deinit();
    const p = try parse(st.allocator(), ".\\docs\\ops\\*.md\n./x.md\n");
    try testing.expectEqualStrings("docs/ops/*.md", p.rules[0].path);
    try testing.expectEqualStrings("docs/ops", p.rules[0].dir);
    try testing.expectEqualStrings("*.md", p.rules[0].name);
    try testing.expect(p.rules[0].glob);
    try testing.expectEqualStrings("x.md", p.rules[1].path);
    try testing.expectEqualStrings("", p.rules[1].dir);
    try testing.expect(!p.rules[1].glob);
}

test "star matching" {
    try testing.expect(matchSegment("*.md", "a.md"));
    try testing.expect(!matchSegment("*.md", ".md")); // hidden
    try testing.expect(matchSegment(".*.md", ".a.md"));
    try testing.expect(matchSegment("a*", "abc"));
    try testing.expect(matchSegment("a*", "a"));
    try testing.expect(matchSegment("*c", "abc"));
    try testing.expect(!matchSegment("*c", "abd"));
    try testing.expect(matchSegment("a*c", "abbbc"));
    try testing.expect(matchSegment("a*c", "ac"));
    try testing.expect(matchSegment("a*b*c", "aXbYc"));
    try testing.expect(matchSegment("a*b*c", "abcbc"));
    try testing.expect(!matchSegment("a*b*c", "acb"));
    try testing.expect(matchSegment("*", "anything"));
    try testing.expect(!matchSegment("*", ".hidden"));
    try testing.expect(matchSegment("exact.md", "exact.md"));
    try testing.expect(!matchSegment("exact.md", "exact.mdx"));
    try testing.expect(!matchSegment("a*", "ba"));
}

test "star never crosses a slash" {
    var st = std.heap.ArenaAllocator.init(testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const res = try run(arena, "docs/*.md\n", &.{}, &.{ "docs/a.md", "docs/ops/b.md", "c.md" });
    try testing.expectEqualStrings("docs/a.md", try paths(arena, res));
}

test "rejected entries" {
    var st = std.heap.ArenaAllocator.init(testing.allocator);
    defer st.deinit();
    const p = try parse(st.allocator(),
        \\**
        \\docs/**/x.md
        \\docs/*/x.md
        \\/etc/x.md
        \\C:\x.md
        \\../x.md
        \\docs/../../x.md
        \\docs/
        \\!
        \\ok.md
    );
    try testing.expectEqual(@as(usize, 1), p.rules.len);
    try testing.expectEqualStrings("ok.md", p.rules[0].path);
    try testing.expectEqual(@as(usize, 9), p.warnings.len);
    try testing.expectEqualStrings("`.kevinrc` line 1: '**': '**' is not supported", p.warnings[0]);
    try testing.expect(std.mem.indexOf(u8, p.warnings[2], "line 3: 'docs/*/x.md'") != null);
    try testing.expect(std.mem.endsWith(u8, p.warnings[2], "is not supported (only the last segment may use '*')"));
    try testing.expect(std.mem.indexOf(u8, p.warnings[3], "absolute") != null);
    try testing.expect(std.mem.indexOf(u8, p.warnings[5], "'..' is not allowed") != null);
}

test "includes append in order, globs sort, duplicates are dropped" {
    var st = std.heap.ArenaAllocator.init(testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const res = try run(arena, "z.md\n*.md\ndocs/*.md\nz.md\n", &.{"README.md"}, &.{ "README.md", "z.md", "b.md", "a.md", "docs/y.md", "docs/x.md" });
    try testing.expectEqualStrings("README.md z.md a.md b.md docs/x.md docs/y.md", try paths(arena, res));
    try testing.expectEqual(Origin{ .include = 1 }, res.files[1].origin);
    try testing.expectEqual(Origin{ .include = 2 }, res.files[2].origin);
    try testing.expectEqual(Origin.default, res.files[0].origin);
}

test "exclusions apply to the set built so far and can drop defaults" {
    var st = std.heap.ArenaAllocator.init(testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const files = [_][]const u8{ "README.md", "build.md", "a.md", "b.md", "docs/c.md" };
    const defaults = [_][]const u8{ "README.md", "build.md" };

    var res = try run(arena, "*.md\n!README.md\n!b.md\n", &defaults, &files);
    try testing.expectEqualStrings("build.md a.md", try paths(arena, res));
    try testing.expectEqual(@as(usize, 2), res.excluded.len);
    try testing.expectEqual(@as(usize, 2), res.excluded[0].line);

    // An exclude before an include does nothing: the include adds it afterwards.
    res = try run(arena, "!a.md\na.md\n", &defaults, &files);
    try testing.expectEqualStrings("README.md build.md a.md", try paths(arena, res));

    // Re-include after exclude.
    res = try run(arena, "!README.md\nREADME.md\n", &defaults, &files);
    try testing.expectEqualStrings("build.md README.md", try paths(arena, res));

    // Glob exclusion only touches its own directory.
    res = try run(arena, "docs/*.md\n*.md\n!docs/*.md\n", &defaults, &files);
    try testing.expectEqualStrings("README.md build.md a.md b.md", try paths(arena, res));
    res = try run(arena, "docs/*.md\n!*.md\n", &defaults, &files);
    try testing.expectEqualStrings("docs/c.md", try paths(arena, res));
}

test "a missing direct path warns, a glob without matches is silent" {
    var st = std.heap.ArenaAllocator.init(testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const res = try run(arena, "# c\nnope.md\nmissing/*.md\n", &.{}, &.{"a.md"});
    try testing.expectEqual(@as(usize, 0), res.files.len);
    try testing.expectEqual(@as(usize, 1), res.warnings.len);
    try testing.expectEqualStrings("`.kevinrc` line 2: 'nope.md' does not exist", res.warnings[0]);
}

test "global seeds come first, project excludes can drop them by home-relative name" {
    var st = std.heap.ArenaAllocator.init(testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const seeds = [_]Entry{
        .{ .path = "/home/u/notes.md", .real = "/home/u/notes.md", .origin = .{ .global = 1 }, .rel = "notes.md" },
        .{ .path = "/home/u/docs/a.md", .real = "/home/u/docs/a.md", .origin = .{ .global = 2 }, .rel = "docs/a.md" },
    };
    const parsed = try parse(arena, "extra.md\n");
    const fs = FakeFs{ .files = &.{ "README.md", "extra.md" } };
    var res = try resolveLayered(arena, parsed.rules, &seeds, &.{"README.md"}, fs);
    try testing.expectEqualStrings("/home/u/notes.md /home/u/docs/a.md README.md extra.md", try paths(arena, res));
    const p2 = try parse(arena, "!notes.md\n!docs/*.md\n");
    res = try resolveLayered(arena, p2.rules, &seeds, &.{"README.md"}, fs);
    try testing.expectEqualStrings("README.md", try paths(arena, res));
    try testing.expectEqual(@as(usize, 2), res.excluded.len);
}

test "global warnings name the global file" {
    var st = std.heap.ArenaAllocator.init(testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const p = try parse(arena, "/etc/x.md\n");
    const w = try relabelGlobal(arena, p.warnings[0], "/home/u/.kevinrc");
    try testing.expect(std.mem.startsWith(u8, w, "global `.kevinrc` (/home/u/.kevinrc) line 1: "));
    try testing.expect(std.mem.indexOf(u8, w, "outside the home directory") != null);
}
