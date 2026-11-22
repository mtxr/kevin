# kevin

A task runner that turns Markdown into a CLI. Describe commands in `README.md`,
`tasks.md` or `build.md`, and `kevin` runs the code blocks. Inspired by
[mask](https://github.com/jacobdeichert/mask) and [xc](https://github.com/joerdav/xc),
written in Zig with no dependencies.

This README is itself a kevin file: run `kevin --help` in this repository to
list its tasks (together with the ones from `build.md`).

## Install

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
flags are only recognised before the command name, so tasks are free to
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

## Environment

Arguments and flags are injected into the script's environment, along with:

| Variable      | Value                                                        |
|---------------|--------------------------------------------------------------|
| `$KEVIN`      | `<kevin binary> --file <absolute path of the declaring .md>` |
| `$KEVIN_DIR`  | Directory of the Markdown file that declared the task        |
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
| Command declaration                       | every heading          | headings under `# Tasks`      | `## > name` or ```` ```lang task ````   |
| Nested subcommands by heading depth       | yes                    | ?                             | yes                                     |
| Subcommand names prefixed with parent (`### services start`) | yes | ?                        | no (use the hierarchy)                  |
| Description                               | `>` blockquote         | paragraph under heading       | `>` blockquote                          |
| Required `(arg)` / optional `[arg]`       | yes                    | ?                             | yes                                     |
| `**OPTIONS**` flags, `type`, `choices`, `required` | yes           | ?                             | yes (same syntax)                       |
| Implicit `-v/--verbose` and `verbose` env | yes                    | ?                             | yes                                     |
| Helper variables                          | `$MASK`, `$MASKFILE_DIR` | ?                           | `$KEVIN`, `$KEVIN_DIR`                  |
| Runtimes                                  | shell, node, python, ruby, php, lua, swift, powershell, bat | ? | shell, node/bun, ts, python, ruby, php, lua, powershell, bat (no swift) |
| OS-specific blocks                        | yes (matching block)   | ?                             | yes (family filter)                     |
| Several blocks run in sequence            | ?                      | ?                             | yes                                     |
| Inline tasks under plain headings         | no                     | ?                             | yes (`task` keyword)                    |
| `Requires:` (task dependencies)           | no                     | yes                           | no (call `$KEVIN other` instead)       |
| `Directory:` attribute                    | no                     | yes                           | no                                      |
| `Env:` / `Run:` attributes                | no                     | ?                             | no                                      |
| `Inputs:` environment variables           | no                     | yes                           | no (use args or flags)                  |
| org-mode files                            | no                     | yes                           | no                                      |

Migrating from mask: add `> ` after the `#`s of every command heading
(`## serve (port)` becomes `## > serve (port)`), replace `$MASK` /
`$MASKFILE_DIR` with `$KEVIN` / `$KEVIN_DIR`, and drop parent prefixes from
subcommand names. Flags and code blocks work unchanged. Migrating from xc is
a manual rewrite of tasks and their `Requires:` / `Inputs:` lines.

## Development

Build, test and release tasks live in [build.md](build.md); contribution rules
and git hooks are in [CONTRIBUTING.md](CONTRIBUTING.md). Typical loop:

```sh
kevin check     # format check + unit tests + end-to-end smoke test
kevin release   # cross-compile for linux, macos and windows into dist/
```

## License

No license has been chosen yet.
