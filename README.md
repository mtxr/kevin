# kevin

**Your README, as a task runner.** kevin turns the Markdown files you already
write (`README.md`, `tasks.md`, `build.md`) into a CLI: headings become
commands, code blocks become their scripts, and `kevin --help` is generated
from the document. A small, dependency-free alternative to `make` and `just`
for project tasks, in the family of [mask](https://github.com/jacobdeichert/mask)
and [xc](https://github.com/joerdav/xc), written in Zig.

> Status: early (0.x). The syntax and flags may still change between minor
> versions; see [Known limitations](#known-limitations).

## Why kevin

- **Docs and commands in one file.** What people read is what runs, so it
  cannot drift. Humans and coding agents use the same source of truth.
- **Real CLI ergonomics.** Positional arguments, typed flags (`number`,
  `string`, `boolean`, `choices`, `required`), validation before anything runs,
  and generated `--help`.
- **Dependencies.** `Requires:` with sync or async execution, `Run: once` and a
  job limit (`--jobs`).
- **Any runtime.** Shell, Node/Bun, TypeScript, Python, Ruby, Lua, PHP and
  PowerShell blocks, several per command, with OS-specific selection.
- **Easy to inspect.** `kevin --explain <cmd>` shows what would run without
  running it, and `kevin --introspect` prints the command tree as JSON.
- **Migration.** `kevin --from mask|xc` converts existing files.
- **One small binary**, no runtime dependencies (about 0.7 MB).

### How it compares

- **make** is unbeatable for incremental, file-timestamp builds. kevin does not
  track files; it is for the tasks around a project (test, lint, release),
  with arguments, flags and documentation.
- **just** uses its own `justfile` syntax. kevin keeps the tasks inside
  Markdown you would write anyway.
- **mask** is the closest relative and kevin borrows its argument and flag
  syntax. kevin adds dependencies, several blocks per command, `--explain`,
  inline tasks and `Requires:`; mask has swift support and a different
  introspection format.
- **xc** also lives in your README and has `Requires:`. kevin adds typed flags
  and nested subcommands, and can migrate xc files.

See the [compatibility table](#compatibility-with-mask-and-xc) for details.

### When not to use kevin

- You need incremental builds driven by file timestamps or content hashes: use
  `make`, `ninja` or a build system such as Bazel.
- You need a stable 1.0 interface today: kevin is 0.x.
- You mainly target Windows: it builds there, but task execution has not been
  exercised on Windows yet.
- Your scripts take an open-ended list of arguments (`$@` with no declared
  arguments, variadic): kevin only passes arguments declared in the heading.

## Get started

Create `tasks.md` (or put this in your `README.md`):

````md
## > hello (name)
> Say hello

```sh
echo "Hello, $name"
```
````

```sh
$ kevin
Commands:
  hello <name>  Say hello

$ kevin hello world
Hello, world
```

This README is itself a kevin file: run `kevin --help` in this repository to
list its tasks (together with the ones from `build.md`). Using kevin from a
coding agent? See [docs/for-agents.md](docs/for-agents.md).

## Install

macOS and Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/mtxr/kevin/main/install.sh | sh
```

It picks the archive for your system from the
[latest release](https://github.com/mtxr/kevin/releases/latest), verifies its
checksum and installs `kevin` into `~/.local/bin` (set `KEVIN_INSTALL_DIR` to
change it, or `KEVIN_VERSION=v0.1.0` to pin a version).

Windows: download `kevin-<version>-x86_64-windows.zip` from the
[releases page](https://github.com/mtxr/kevin/releases/latest), extract it and
put `kevin.exe` on your `PATH`. Every release also has a `SHA256SUMS` file and
the other archives (`aarch64-macos`, `x86_64-macos`, `x86_64-linux`,
`aarch64-linux`) if you prefer to download by hand.

The binaries are not code-signed. If macOS refuses to open one downloaded with
a browser, run `xattr -d com.apple.quarantine kevin` once (the installer does
not need it). Package managers are not available yet.

### Updating

`kevin --check-update` tells you whether a newer release exists (it only asks
GitHub, using `curl`; nothing is downloaded). To update, run the install command
again.

### From source

Requires Zig 0.17.0 or newer.

```sh
zig build                          # first binary in zig-out/bin/kevin
./zig-out/bin/kevin install        # or: zig build --prefix ~/.local
```

## > install
> Build an optimized binary and install it into a prefix

**OPTIONS**
* prefix
    * flags: -p --prefix
    * type: string
    * desc: Install prefix (default $HOME/.local)

```sh
zig build -Doptimize=ReleaseSafe --prefix "${prefix:-$HOME/.local}"
echo "installed to ${prefix:-$HOME/.local}/bin/kevin"
```

## Quick start

Create `tasks.md`:

````md
# My project

## > build (target) [mode]
> Compile the project

```bash
echo "building $target in ${mode:-debug} mode"
```

### > docs
> Build the docs (becomes `kevin build docs`)

```sh
echo docs
```

## Run Migrations

```bash task (env)
echo "migrating $env"
```
````

```sh
kevin                      # list commands
kevin build web release    # -> building web in release mode
kevin build docs
kevin run-migrations prod  # name slugified from the heading
kevin build --help
```

## File discovery

Without `--file`, kevin looks in the current directory for `README.md`,
`tasks.md` and `build.md` (case-insensitive) and merges them into a single
command tree, in that order. Pure namespaces are merged; if the same command
exists in two files, the later file wins and a warning is printed.

`kevin -f path/to/file.md ...` (or `--file`) uses exactly that file. Global
flags (`-f`, `-j`, `--from`, `-o`, `--explain`) are only recognised before the command name, so tasks are free to
declare their own `-f`.

## Declaring commands

**Marked headings.** Any heading level (`#` to `######`) followed by `>`
declares a command. Nesting follows the heading hierarchy, so `### > server`
under `## > setup` is `kevin setup server`. Positional arguments go after the
name: `(required)` and `[optional]`. Blockquote lines right below the heading
become the description in `--help`. Code blocks directly under the heading are
the command's script.

**Inline tasks.** Under a normal heading, a code block becomes a command only
if its info string contains `task`: `` ```bash task (a) [b] `` or
`` ```ts task:custom-name (a) ``. Without `:name`, the command is named after
the heading (`## Run Migrations` becomes `run-migrations`). Several task blocks
under one heading form a single command. Inline tasks attach to the nearest
`>` ancestor and never leak into earlier commands.

**Example blocks.** Only the first blocks of a `>` command are its script. A
code block that comes after a prose paragraph that itself follows an earlier
block is documentation (an example, a sample output) and is not run, unless its
info string contains the word `task`. A description paragraph before the first
block, blank lines, blockquotes and attribute lines do not count. Once a block
was skipped as an example, the blocks after it are examples too until one is
tagged `task`. `kevin --explain <command>` lists the skipped blocks and says
why.

**Names.** Argument and flag names must match `[A-Za-z_][A-Za-z0-9_]*`. These
are rejected with a warning (the declaration is skipped): `PATH`, `HOME`, `IFS`,
`ENV`, `BASH_ENV`, `SHELL`, `PWD`, `OLDPWD`, `USER`, `LANG`, `TMPDIR`, names
starting with `KEVIN`, and `verbose`/`help` (any case). Declaring the same name
twice, as an argument and a flag or twice as either, keeps the first one. In
headings and `task` info strings only `(...)` and `[...]` groups placed
directly after the name are read, and only when each holds one valid name, so
trailing prose such as `(slow, needs [network])` stays prose.

Everything inside a fenced block is opaque: headings, `>` and `**OPTIONS**`
inside it are ignored, and a fence only closes on a line with at least as many
identical characters as the opening one (so ```` ```` ```` can wrap ``` ```).

## Flags

An `**OPTIONS**` list before the code block declares named flags (same syntax
as mask):

````md
## > serve

**OPTIONS**
* port
    * flags: -p --port
    * type: number
    * desc: Port to listen on
    * required
* env
    * flags: -e --env
    * type: string
    * choices: dev, prod
* watch
    * flags: -w --watch
````

The root item is the environment variable name. `type` is `string`, `number`
or `boolean`; when omitted it is `boolean` (`"true"` if passed, unset
otherwise). `number` and `choices` are validated before anything runs, and
`required` flags must be present. Supported forms: `--port 80`, `--port=80`,
`-p 80`, `-p80`, `-wp 80`, and `--` to stop flag parsing.

Every command also accepts `-h/--help` (generated from the file) and
`-v/--verbose`, which echoes each block before running it and sets
`verbose=true`.

A flag that is absent, or passed as `--flag=false`, is removed from the
script's environment: a variable of the same name in the caller's environment
(`port=99 kevin serve`) never leaks into the task. `--explain` shows such flags
as unset.

## Dependencies

A command can require other commands. Put `Requires:` lines in the header of
the command: right after the heading and its `>` description, before any other
paragraph, list or code block. They must be plain lines, with no `*`, `_`,
backticks or list markers, so a documentation sentence such as
`**Requires:** Node.js 18+` is never read as an attribute. An unknown name in a
plain `Requires:` line is an error. `RunDeps:`, `Run:` and `Jobs:` lines are
optional. They work on `>` commands and on inline tasks. A command with only
`Requires:` and no code block is a runnable group.

````md
## > deploy (target)
> Ship to an environment

Requires: test, build $target
RunDeps: async
Jobs: 2

```sh
./deploy.sh "$target"
```
````

| Attribute        | Meaning                                                                          |
|------------------|----------------------------------------------------------------------------------|
| `Requires: a, b` | Comma separated entries. Each is a command name followed by its arguments, with `$name` / `${name}` expanded from the requiring command's own arguments and flags. Alias: `Req:` |
| `RunDeps: async` | Run the dependencies concurrently. `sync` (the default) runs them in order. Alias: `RunDependencies:` |
| `Run: once`      | Run this command a single time per invocation, however many commands require it. `always` is the default |
| `Jobs: N`        | At most N of this command's dependencies at the same time (async only)           |

The whole dependency tree is resolved before anything runs, so unknown names,
bad arguments and cycles (`dependency cycle: a -> b -> a`) fail up front with
exit code 2. Sync dependencies stop at the first failure. Async dependencies
fail fast: when one of them fails, the siblings that are still running receive
SIGTERM, the ones that have not started yet never start, and kevin fails with
the exit code of the first failure (not of the siblings it stopped). Their
output is interleaved. Failing dependencies stop the command's own script from
running, and the exit code is propagated.

`-j N` / `--jobs N` (or `KEVIN_JOBS=N`) caps how many scripts run at once across
the whole tree, in both directions: `-j 2` never runs more than two, and `-j 41`
runs 41 async dependencies at the same time, whatever the CPU count. The
default is the number of CPUs. `Jobs:` limits one command's group of
dependencies, and `--jobs` still applies on top. Scripts that call
`$KEVIN other` start a separate kevin process, which inherits `KEVIN_JOBS` but
counts its own scripts.

## Signals and cleanup

On Linux and macOS kevin handles SIGINT, SIGTERM and SIGHUP: the signal is
forwarded to every running script, kevin waits for them and exits with 128 plus
the signal number (143 for SIGTERM). Pending tasks do not start. A second
signal sends SIGKILL to the scripts instead of waiting for them. Scripts that
trap the signal get to clean up first.

Each script runs in its own process group, so the signal reaches the whole
subtree (for example a `sleep` started by a shell script), except when stdin is
a terminal: a background group cannot read the terminal, so scripts then stay in
kevin's group, the terminal delivers Ctrl-C to all of them and kevin does not
forward SIGINT a second time. SIGKILL to kevin itself cannot be handled and
leaves the scripts and the temp directory behind.

kevin stops a task that calls itself through `$KEVIN` (directly or in a cycle)
at 32 nested runs: it sets `KEVIN_DEPTH` for every child and exits with code 2
and a message once the limit is reached.

## Explaining a command

`kevin --explain <command> [args]` shows how a command was resolved without
running anything: the merged source files, where the command is declared,
each argument and flag with its validated value, the variables kevin injects,
and, for every code block, whether it would run or be skipped (and why), which
runtime was picked from `PATH`, the final argv and the code. It exits with 2
when validation fails and 127 when a runtime is missing, so it also works as a
pre-flight check. Like the other global flags it goes before the command name.

```sh
kevin --explain hello World -t 2 -c red
```

## Shell completion

kevin completes command names, subcommands, flags and `choices:` values from
the Markdown file of the current directory. Add one line to your shell config:

```sh
eval "$(kevin --completion zsh)"      # ~/.zshrc (after compinit)
eval "$(kevin --completion bash)"     # ~/.bashrc
kevin --completion fish | source      # ~/.config/fish/config.fish
```

The script calls back into `kevin` at tab time, so new tasks show up without
regenerating anything. Command descriptions are shown where the shell supports
them (zsh and fish).

## Environment

Arguments and flags are injected into the script's environment. Declared
arguments also arrive as `$1..$n` in `sh`, `bash` and `zsh` blocks (xc style;
`$0` is the temporary script file, and trailing optional arguments that were
not given are left out). Also injected:

| Variable      | Value                                                        |
|---------------|--------------------------------------------------------------|
| `$KEVIN`      | `<kevin binary> --file <absolute path of the declaring .md>` |
| `$KEVIN_DIR`  | Directory of the Markdown file that declared the task        |
| `KEVIN_JOBS`  | Maximum number of scripts running at once                    |
| `KEVIN_DEPTH` | How many kevin runs are nested (1 in a task started by kevin); 32 is the limit |
| `verbose`, `KEVIN_VERBOSE` | `true` when `-v/--verbose` was given            |

`$KEVIN other-task` lets a task call its siblings from any directory. The value
is not quoted, so a binary path with spaces needs `eval`. Tasks run in the
directory kevin was started from.

## Runtimes and multiple blocks

Every block is written to a file in a private temporary directory (created per
run with mode 0700, removed afterwards, also after a failure or a signal) and
run as `<interpreter> <file> [args]`. stdin is never touched, so scripts can
read from the terminal or a pipe, and the code size is not limited by the OS
argument limit. Error messages of shells show the temporary path instead of
`bash -c`; `$0` is that path. The directory is created under `$TMPDIR` (`/tmp`),
or `%TEMP%` on Windows.

| Language                      | Runs with (first one found in `PATH`)             |
|-------------------------------|---------------------------------------------------|
| `sh` `bash` `zsh` `fish`      | `<shell> file` (`$1..$n` in sh, bash, zsh)        |
| `js` `javascript`             | `node file`, else `bun run file`                  |
| `ts` `typescript`             | `bun run file`, else `tsx file`, else `deno run -A file` |
| `py` `python`                 | `python3 file`, `python file`, else `uv run --no-project python file` |
| `ruby` `rb`                   | `ruby file`                                       |
| `lua`                         | `lua file`                                        |
| `php`                         | `php file` (`<?php` is added unless the block starts with an open tag) |
| `powershell` `pwsh`           | `pwsh -NoProfile -File file.ps1`, else `powershell -NoProfile -ExecutionPolicy Bypass -File file.ps1` |
| `bat` `cmd`                   | `cmd /c file.bat` (`@echo off` is added, line endings become CRLF) |

A command with several blocks runs them in order and stops at the first
non-zero exit code, which becomes kevin's exit code. If it has both
POSIX-shell blocks (`sh`/`bash`/`zsh`/`fish`) and Windows-shell blocks
(`powershell`/`pwsh`/`bat`/`cmd`), only the family for the current OS runs.
Blocks without a language, or with data languages (`json`, `yaml`, `toml`,
`text`, `md`), are ignored.

Every block is a separate process, so a variable exported by one block is not
visible to the next, in the same language or another one. Arguments and flags
reach every block as environment variables. See
[`examples/runtimes.md`](examples/runtimes.md) for a command that mixes Node,
bash and Python.

Every block is a separate process, so a variable exported by one block is not
visible to the next, in the same language or another one. Arguments and flags
reach every block as environment variables. See
[`examples/runtimes.md`](examples/runtimes.md) for a command that mixes Node,
bash and Python.

Every block is a separate process, so a variable exported by one block is not
visible to the next, in the same language or another one. Arguments and flags
reach every block as environment variables. See
[`examples/runtimes.md`](examples/runtimes.md) for a command that mixes Node,
bash and Python.

## Compatibility with mask and xc

kevin borrows mask's argument and flag syntax almost verbatim, but it is
**not** a drop-in replacement for either tool: existing `maskfile.md` or xc
files need small edits (see below). A `?` means the behaviour was not verified against that tool's upstream docs.

| Feature                                   | mask                   | xc                            | kevin                                   |
|-------------------------------------------|------------------------|-------------------------------|-----------------------------------------|
| Default file                              | `maskfile.md`          | `README.md`                   | `README.md`, `tasks.md`, `build.md` (merged) |
| Explicit file flag                        | `--maskfile`           | ?                             | `-f` / `--file`                         |
| Command declaration                       | every heading          | headings one level below a `Tasks` heading | `## > name` or ```` ```lang task ```` |
| Nested subcommands by heading depth       | yes                    | no (flat list)                | yes                                     |
| Subcommand names prefixed with parent (`### services start`) | yes | no                       | no (use the hierarchy)                  |
| Description                               | `>` blockquote         | paragraph under heading       | `>` blockquote                          |
| Required `(arg)` / optional `[arg]`       | yes                    | `Inputs:` (+ `Env:` default)  | yes                                     |
| Positional `$1` / `$@` in scripts         | no                     | yes                           | `$1..$n` for declared args in sh/bash/zsh; no variadic |
| `**OPTIONS**` flags, `type`, `choices`, `required` | yes           | no                            | yes (same syntax)                       |
| Implicit `-v/--verbose` and `verbose` env | yes                    | ?                             | yes                                     |
| Helper variables                          | `$MASK`, `$MASKFILE_DIR` | ?                           | `$KEVIN`, `$KEVIN_DIR`                  |
| Runtimes                                  | shell, node, python, ruby, php, lua, swift, powershell, bat | shell, or any interpreter via shebang | shell, node/bun, ts, python, ruby, php, lua, powershell, bat (no swift) |
| OS-specific blocks                        | yes (matching block)   | ?                             | yes (family filter)                     |
| Several blocks run in sequence            | ?                      | ?                             | yes                                     |
| Inline tasks under plain headings         | no                     | ?                             | yes (`task` keyword)                    |
| Call another task from a script           | `mask cmd` / `$MASK cmd` | via `Requires:`             | `$KEVIN cmd`                            |
| `Requires:` (task dependencies)           | no                     | yes (`Run: once` dedupes)     | yes, same syntax and `Run: once`        |
| Parallel dependencies                     | no                     | yes (`RunDeps: async`)        | yes (`RunDeps: async`, `--jobs`, `Jobs:`) |
| `Directory:` / `Env:` attributes          | no                     | yes                           | no (translated by `--from xc`)          |
| org-mode files                            | no                     | yes                           | no                                      |

## Migrating from mask or xc

`kevin --from mask|xc` converts a file to kevin syntax. It reads `maskfile.md`
(mask) or `README.md` (xc) unless you pass `-f`, prints to stdout, and with
`-o <path>` writes a new file (it never overwrites an existing one). Anything
it could not translate is listed on stderr as `kevin: note: ...`. Because it is
a global flag rather than a command, it can never clash with your own tasks.

```sh
kevin --from mask > tasks.md
kevin --from xc -f README.md -o tasks.md
```

**mask**: adds the `>` marker to every command heading (level 1 titles and
anything inside code fences are left alone), strips parent prefixes
(`### services start` under `## services` becomes `start`), and rewrites
`$MASK`, `$MASKFILE_DIR` and `mask <cmd>` calls in executable blocks to
`$KEVIN`, `$KEVIN_DIR` and `$KEVIN <cmd>`. Flags and code blocks are kept as is.
`swift` blocks are reported because kevin cannot run them. Headings that are
only documentation (several words, no matching parent) are renamed with
hyphens and reported, so review the notes.

**xc**: finds the `Tasks` section and converts each task, keeping all other
prose.

| xc                              | kevin                                                           |
|---------------------------------|-----------------------------------------------------------------|
| `### name`                      | `### > name`                                                    |
| first description paragraph     | `> description`                                                 |
| `Inputs: A, B`                  | `(A) (B)`; becomes `[A]` when `Env:` gives it a default         |
| `Requires: a, b`                | `Requires: a, b` (kept as is, arguments included)               |
| `RunDeps: async`                | `RunDeps: async`                                                |
| `Run: once`                     | `Run: once`                                                     |
| `Directory: x`, or none         | `cd "$KEVIN_DIR/x"`, or `cd "$KEVIN_DIR"` as xc runs in the file's directory |
| `Env: K=V`                      | `export K='V'`                                                  |
| unlabeled block / shebang       | `bash`, or the shebang's language (shebang removed)             |
| shell blocks (`sh`, `bash`, `zsh`) | `set -e` first, as xc runs every shell script with it, tagged or not |
| `$1`, `$@` in scripts           | not converted, reported (declare named args instead)            |

Shell scripts migrated from xc `cd` into the file's directory (aborting if the
`cd` fails), like xc does;
other runtimes keep the current directory and are reported. org-mode files are
not supported.

## Development

Build, test and release tasks live in [build.md](build.md); contribution rules
and git hooks are in [CONTRIBUTING.md](CONTRIBUTING.md). Typical loop:

```sh
kevin check     # format check + unit tests + end-to-end smoke test
kevin release   # cross-compile for linux, macos and windows into dist/
```

## Known limitations

- Only declared arguments are passed (as named variables and, in `sh`, `bash`
  and `zsh` blocks, as `$1..$n`); variadic arguments and `$@` without
  declared arguments are not supported.
- Dependencies that run `async` print their output interleaved.
- Task execution on Windows has not been exercised yet (it only cross-compiles).
  There is no signal forwarding on Windows: Ctrl-C reaches every process of the
  console on its own, and `RunDeps: async` fail-fast terminates the siblings
  with TerminateProcess (no grace period, grandchildren are not reached).
- Signal handling needs a process group per script; with a terminal as stdin a
  script's own background children can outlive a SIGTERM sent to kevin.
- A script that ignores SIGTERM keeps an async group (and kevin) waiting; send a
  second signal to force it.
- `--from xc` does not read inputs given only through environment variables,
  setext headings or org-mode files; `--from mask` keeps every code block of a
  command, while mask runs only one.
- The compatibility suite in `tests/compat` tracks each known gap as an
  expected failure (`xfail`); run `kevin compat` to see the list.

## License

[MIT](LICENSE). Copies and substantial portions must keep the copyright
notice and the license text. Third-party material is listed in
`THIRD_PARTY_NOTICES.md` when present.
