# kevin

A task runner that turns Markdown into a CLI. Describe commands in `README.md`,
`tasks.md` or `build.md`, and `kevin` runs the code blocks. Inspired by
[mask](https://github.com/jacobdeichert/mask) and [xc](https://github.com/joerdav/xc),
written in Zig with no dependencies.

This README is itself a kevin file: run `kevin --help` in this repository to
list its tasks (together with the ones from `build.md`).

## Install

### From the releases page

Every release publishes one archive per platform on
[github.com/mtxr/kevin/releases](https://github.com/mtxr/kevin/releases),
plus a `SHA256SUMS` file. Pick the one for your system:

| Platform              | Asset                                   |
|-----------------------|-----------------------------------------|
| macOS, Apple silicon  | `kevin-<version>-aarch64-macos.tar.gz`  |
| macOS, Intel          | `kevin-<version>-x86_64-macos.tar.gz`   |
| Linux, x86_64         | `kevin-<version>-x86_64-linux.tar.gz`   |
| Linux, arm64          | `kevin-<version>-aarch64-linux.tar.gz`  |
| Windows, x86_64       | `kevin-<version>-x86_64-windows.zip`    |

Each archive contains a single `kevin` binary (`kevin.exe` on Windows), the
`LICENSE` and this README. On macOS and Linux:

```sh
VERSION=v0.1.0              # see the releases page for the latest one
TARGET=aarch64-macos        # x86_64-macos, x86_64-linux or aarch64-linux
BASE="https://github.com/mtxr/kevin/releases/download/$VERSION"

curl -fsSLO "$BASE/kevin-$VERSION-$TARGET.tar.gz"
curl -fsSLO "$BASE/SHA256SUMS"
grep "kevin-$VERSION-$TARGET.tar.gz" SHA256SUMS | shasum -a 256 -c -   # use sha256sum -c on Linux
tar -xzf "kevin-$VERSION-$TARGET.tar.gz"
install -m 0755 "kevin-$VERSION-$TARGET/kevin" ~/.local/bin/kevin      # any directory on your PATH
kevin --version
```

On Windows (PowerShell), download the `.zip`, extract it and put `kevin.exe` in
a directory on your `PATH`:

```powershell
$Version = "v0.1.0"
$Name = "kevin-$Version-x86_64-windows"
Invoke-WebRequest "https://github.com/mtxr/kevin/releases/download/$Version/$Name.zip" -OutFile "$Name.zip"
Expand-Archive "$Name.zip" -DestinationPath .
```

The binaries are not code-signed. If macOS refuses to open a binary you
downloaded with a browser, run `xattr -d com.apple.quarantine kevin` once
(downloading with `curl` as above does not need it). Package managers are not
available yet.

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

## Dependencies

A command can require other commands. Put `Requires:` (and optionally
`RunDeps:`, `Run:` and `Jobs:`) lines under the heading, before the first code
block. They work on `>` commands and on inline tasks. A command with only
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
all run to completion, then kevin fails with the first failing exit code in
declaration order; their output is interleaved. Failing dependencies stop the
command's own script from running, and the exit code is propagated.

`-j N` / `--jobs N` (or `KEVIN_JOBS=N`) caps how many scripts run at once across
the whole tree. The default is the number of CPUs. `Jobs:` limits one command's
group of dependencies, and `--jobs` still applies on top. Scripts that call
`$KEVIN other` start a separate kevin process, which inherits `KEVIN_JOBS` but
counts its own scripts.

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

## Environment

Arguments and flags are injected into the script's environment, along with:

| Variable      | Value                                                        |
|---------------|--------------------------------------------------------------|
| `$KEVIN`      | `<kevin binary> --file <absolute path of the declaring .md>` |
| `$KEVIN_DIR`  | Directory of the Markdown file that declared the task        |
| `KEVIN_JOBS`  | Maximum number of scripts running at once                    |
| `verbose`, `KEVIN_VERBOSE` | `true` when `-v/--verbose` was given            |

`$KEVIN other-task` lets a task call its siblings from any directory. The value
is not quoted, so a binary path with spaces needs `eval`. Tasks run in the
directory kevin was started from.

## Runtimes and multiple blocks

| Language                      | Runs with                                         |
|-------------------------------|---------------------------------------------------|
| `sh` `bash` `zsh` `fish`      | `<shell> -c`                                      |
| `js` `javascript`             | `node -e`, else `bun -e`                          |
| `ts` `typescript`             | `bun run -`, else `tsx -e`, else `deno run -`     |
| `py` `python`                 | `uv run python -c`, else `python3 -c`, `python -c`|
| `ruby` `rb`                   | `ruby -e`                                         |
| `lua`                         | `lua -e`                                          |
| `php`                         | `php -r`                                          |
| `powershell` `pwsh`           | `pwsh -Command`, else `powershell -Command`       |
| `bat` `cmd`                   | `cmd /c`                                          |

A command with several blocks runs them in order and stops at the first
non-zero exit code, which becomes kevin's exit code. If it has both
POSIX-shell blocks (`sh`/`bash`/`zsh`/`fish`) and Windows-shell blocks
(`powershell`/`pwsh`/`bat`/`cmd`), only the family for the current OS runs.
Blocks without a language, or with data languages (`json`, `yaml`, `toml`,
`text`, `md`), are ignored.

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
| Positional `$1` / `$@` in scripts         | no                     | yes                           | no (named env vars)                     |
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
| unlabeled block / shebang       | `bash` with `set -e` (as xc runs it), or the shebang's language (shebang removed) |
| `$1`, `$@` in scripts           | not converted, reported (declare named args instead)            |

Shell scripts migrated from xc `cd` into the file's directory, like xc does;
other runtimes keep the current directory and are reported. org-mode files are
not supported.

## Development

Build, test and release tasks live in [build.md](build.md); contribution rules
and git hooks are in [CONTRIBUTING.md](CONTRIBUTING.md). Typical loop:

```sh
kevin check     # format check + unit tests + end-to-end smoke test
kevin release   # cross-compile for linux, macos and windows into dist/
```

## License

[MIT](LICENSE). Copies and substantial portions must keep the copyright
notice and the license text. Third-party material is listed in
`THIRD_PARTY_NOTICES.md` when present.
