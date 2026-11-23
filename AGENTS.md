# Working on kevin

kevin is a Markdown task runner written in Zig (0.17 or newer). Read
`README.md` for what it does and `CONTRIBUTING.md` for the workflow.

## Tasks

This repository dogfoods itself: build, test and release processes are kevin
tasks in `build.md` (and `README.md`). Bootstrap once with `zig build`, then:

- `./zig-out/bin/kevin check`: format check, unit tests, smoke test and the
  mask/xc compatibility suite. Run it before finishing any change.
- `./zig-out/bin/kevin test`, `fmt`, `smoke`, `compat`, `release`.
- `./zig-out/bin/kevin -f CONTRIBUTING.md hooks`: install the commit message hook.

## Conventions

- Everything is English: code, comments, docs, commit messages.
- Commits follow Conventional Commits (`type(scope): summary`, at most 72
  characters, imperative). The hook in `.githooks/commit-msg` enforces it.
  Do not commit unless asked.
- Zig 0.17's `std` differs from older versions (`std.Io`, `std.process.Init`,
  unmanaged `ArrayList`). Read `lib/std` of the installed toolchain instead of
  guessing APIs.
- New behaviour needs a `test "..."` block, and bug fixes get a regression
  check in the `smoke` task of `build.md`.
- Compatibility with mask and xc is tracked in `tests/compat`. A known gap is
  a case with an `xfail:` line; when a fix makes it pass, remove that line.
  Files copied from mask or xc must keep their license notices (see
  `THIRD_PARTY_NOTICES.md`).

## Map

- `src/parser.zig`: line-based state machine, Markdown to command tree.
- `src/cli.zig`: command resolution, argument and flag parsing, `--help`.
- `src/deps.zig`, `src/runner.zig`: dependency graph, block selection, processes.
- `src/proc.zig`: live-child registry, signal forwarding, fail-fast scopes, temp script directory.
- `src/explain.zig`, `src/introspect.zig`: `--explain` and `--introspect`.
- `src/migrate.zig`: `--from mask|xc`.
- `src/main.zig`: global flags and wiring.
