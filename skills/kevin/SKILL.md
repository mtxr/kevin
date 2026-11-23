---
name: kevin
description: Use when a project declares tasks in Markdown for the kevin task runner (README.md, tasks.md or build.md with headings like `## > build`), or when the user wants to list, preview, run, write or migrate (from mask or xc) kevin tasks. Also use when asked for a task runner whose commands live in the project's documentation.
---

# kevin

kevin turns `README.md`, `tasks.md` and `build.md` into a CLI: a heading marked
with `>` is a command and its code blocks are the script. Full docs:
https://github.com/mtxr/kevin (README.md, docs/for-agents.md).

## Workflow

1. Discover: run `kevin` (lists commands) or `kevin --introspect` (JSON with
   arguments, flags, dependencies and the code of every command).
2. Preview: `kevin --explain <command> [args]` shows what would run, with
   validated arguments and the runtime found, without running anything.
3. Run: `kevin <command> [args] [--flag value]`. The exit code is the
   script's. Global flags (`-f`, `-j`, `--explain`) go before the command.
4. Before finishing a change in a project that has a `check` command, run
   `kevin check`.

If kevin says `no README.md, tasks.md or build.md found`, the directory has no
kevin tasks; use `kevin --file <path>` for a specific file (repeat `-f` for
several; `-f` ignores `.kevinrc`). A `.kevinrc` in the current directory adds
(`docs/*.md`, `ops.md`) or removes (`!docs/draft.md`) files on top of the
defaults: `#` comments, relative paths, `*` only in the last segment.
`kevin --explain` shows which files were read and why.

## Syntax cheat sheet

````md
## > deploy (target) [region]
> Description shown in --help

**OPTIONS**
* dry_run
    * flags: -n --dry-run
    * type: boolean
    * desc: Print instead of deploying

Requires: test, build $target
RunDeps: async

```sh
./deploy.sh "$target" "${region:-us-east-1}"
```
````

- `(name)` is a required argument and `[name]` an optional one. They reach the
  script as environment variables (`$target`) and, in `sh`, `bash` and `zsh`
  blocks, also as `$1..$n` (no variadic `$@`). Absent flags are unset.
- Nesting follows the heading hierarchy: `### > server` under `## > setup` is
  `kevin setup server`.
- Under a plain heading, a block is a command only with `task` in its info
  string: ` ```bash task (env) ` or ` ```ts task:custom-name `.
- Flag types: `string`, `number`, `boolean` (default), plus `choices:` and
  `required`. Invalid values fail before anything runs.
- `Requires:` lists commands (with arguments); `RunDeps: async` runs them
  concurrently; `Run: once` runs a command once per invocation; `Jobs: N` caps
  concurrency; `-j N` caps concurrent scripts globally.
- Several code blocks in one command run in order and stop at the first
  failure. Blocks without a language or with data languages are ignored. A
  block after prose that follows an earlier block is an example and does not
  run unless its info string has `task`.
- Attribute lines (`Requires:`...) must be plain lines right after the heading
  and description; reserved or duplicate argument/flag names are skipped.
- Call a sibling task from a script with `$KEVIN other-task`.

## Migrating

`kevin --from mask > tasks.md` or `kevin --from xc -f README.md -o tasks.md`
converts an existing file and prints what it could not translate on stderr.
Review those notes.

## Limits to know

kevin is an early 0.x project. It does not do incremental file-timestamp
builds (use make or ninja for that), and task execution on Windows has not
been exercised yet.
