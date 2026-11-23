//! Shell completion: static scripts for zsh, bash and fish that call back into
//! `kevin --complete <words...>`, because the commands come from the Markdown
//! file of the current directory and are only known at tab time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ast = @import("ast.zig");
const cli = @import("cli.zig");

pub const Shell = enum { zsh, bash, fish };

pub fn script(shell: Shell) []const u8 {
    return switch (shell) {
        .zsh => zsh_script,
        .bash => bash_script,
        .fish => fish_script,
    };
}

const zsh_script =
    \\#compdef kevin
    \\_kevin() {
    \\  local -a items
    \\  local name desc
    \\  while IFS=$'\t' read -r name desc; do
    \\    [[ -z $name ]] && continue
    \\    if [[ -n $desc ]]; then items+=("${name//:/\\:}:$desc"); else items+=("${name//:/\\:}"); fi
    \\  done < <(command kevin --complete "${(@)words[2,CURRENT]}" 2>/dev/null)
    \\  if (( ${#items} )); then _describe 'kevin' items; else _files; fi
    \\}
    \\if [ "$funcstack[1]" = "_kevin" ]; then _kevin "$@"; else compdef _kevin kevin; fi
    \\
;

const bash_script =
    \\_kevin() {
    \\  local out name
    \\  COMPREPLY=()
    \\  out=$(command kevin --complete "${COMP_WORDS[@]:1:COMP_CWORD}" 2>/dev/null)
    \\  if [ -z "$out" ]; then
    \\    COMPREPLY=($(compgen -f -- "${COMP_WORDS[COMP_CWORD]}"))
    \\    return 0
    \\  fi
    \\  while IFS=$'\t' read -r name _; do
    \\    [ -n "$name" ] && COMPREPLY+=("$name")
    \\  done <<< "$out"
    \\}
    \\complete -o default -F _kevin kevin
    \\
;

const fish_script =
    \\function __kevin_complete
    \\    set -l cur (commandline -ct)
    \\    command kevin --complete (commandline -opc)[2..-1] "$cur" 2>/dev/null
    \\end
    \\complete -c kevin -f -a '(__kevin_complete)'
    \\
;

const global_flags = [_][]const u8{ "--file", "--from", "--output", "--jobs", "--explain", "--introspect", "--completion", "--version", "--help" };
/// Global flags that consume the next word.
const global_with_value = [_][]const u8{ "-f", "--file", "-o", "--output", "-j", "--jobs", "--from", "--completion" };

fn isGlobalWithValue(t: []const u8) bool {
    for (global_with_value) |g| if (std.mem.eql(u8, g, t)) return true;
    return false;
}

fn put(out: *Io.Writer, prefix: []const u8, name: []const u8, desc: []const u8) Io.Writer.Error!void {
    if (!std.mem.startsWith(u8, name, prefix)) return;
    try out.writeAll(name);
    const nl = std.mem.indexOfScalar(u8, desc, '\n') orelse desc.len;
    const first = std.mem.trim(u8, desc[0..nl], " \t\r");
    if (first.len > 0) {
        try out.writeByte('\t');
        for (first) |c| try out.writeByte(if (c == '\t') ' ' else c);
    }
    try out.writeByte('\n');
}

/// Writes completion candidates (`name` or `name<TAB>description`, one per line)
/// for the command line `words`, whose last element is the word being completed.
pub fn candidates(arena: Allocator, out: *Io.Writer, root: *const ast.Command, words: []const []const u8) (Allocator.Error || Io.Writer.Error)!void {
    const cur: []const u8 = if (words.len > 0) words[words.len - 1] else "";
    const prior = if (words.len > 0) words[0 .. words.len - 1] else words;

    // Drop global flags (and their values) so they do not hide the command.
    var tokens: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var seen_command = false;
    while (i < prior.len) : (i += 1) {
        const t = prior[i];
        if (!seen_command and t.len > 0 and t[0] == '-') {
            if (isGlobalWithValue(t)) i += 1;
            continue;
        }
        seen_command = true;
        try tokens.append(arena, t);
    }

    const r = try cli.resolve(arena, root, tokens.items);
    const cmd = r.cmd;

    // The previous word is a flag that takes a value: offer its choices.
    if (r.rest.len > 0) {
        const prev = r.rest[r.rest.len - 1];
        for (cmd.flags.items) |f| {
            if (f.ftype == .boolean) continue;
            const hit = (f.long != null and std.mem.eql(u8, f.long.?, prev)) or (f.short != null and std.mem.eql(u8, f.short.?, prev));
            if (!hit) continue;
            for (f.choices) |c| try put(out, cur, c, "");
            return;
        }
    }

    if (cur.len > 0 and cur[0] == '-') {
        for (cmd.flags.items) |f| {
            if (f.long) |l| try put(out, cur, l, f.desc);
            if (f.short) |s| try put(out, cur, s, f.desc);
        }
        try put(out, cur, "--help", "Show help");
        try put(out, cur, "-v", "Print the scripts before running them");
        if (cmd == root) for (global_flags) |g| try put(out, cur, g, "");
        return;
    }

    for (cmd.children.items) |c| try put(out, cur, c.name, c.description);
}

const testing = std.testing;
const parser = @import("parser.zig");

fn run(arena: Allocator, root: *const ast.Command, words: []const []const u8) ![]const u8 {
    var buf: Io.Writer.Allocating = .init(arena);
    try candidates(arena, &buf.writer, root, words);
    return buf.written();
}

test "completes commands, subcommands, flags and choices" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\## > serve
        \\
        \\> Run the server
        \\
        \\**OPTIONS**
        \\* env
        \\    * flags: -e --env
        \\    * type: string
        \\    * choices: dev, prod
        \\* watch
        \\    * flags: -w --watch
        \\
        \\### > web
        \\
        \\```bash
        \\true
        \\```
        \\
        \\## > build
        \\
        \\```bash
        \\true
        \\```
        \\
    ;
    const root = (try parser.parseSource(arena, "/x.md", src)).root;

    const top = try run(arena, root, &.{""});
    try testing.expect(std.mem.indexOf(u8, top, "serve\tRun the server\n") != null);
    try testing.expect(std.mem.indexOf(u8, top, "build\n") != null);

    const pre = try run(arena, root, &.{"se"});
    try testing.expectEqualStrings("serve\tRun the server\n", pre);

    const sub = try run(arena, root, &.{ "serve", "" });
    try testing.expectEqualStrings("web\n", sub);

    const flags = try run(arena, root, &.{ "serve", "--" });
    try testing.expect(std.mem.indexOf(u8, flags, "--env\n") != null);
    try testing.expect(std.mem.indexOf(u8, flags, "--help") != null);

    const choices = try run(arena, root, &.{ "serve", "--env", "" });
    try testing.expectEqualStrings("dev\nprod\n", choices);

    // global flags and their values do not hide the command
    const skipped = try run(arena, root, &.{ "-f", "x.md", "serve", "" });
    try testing.expectEqualStrings("web\n", skipped);
}
