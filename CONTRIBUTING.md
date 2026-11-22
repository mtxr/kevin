# Contributing to kevin

Everything in this repository is written in **English**: code, comments,
documentation, issues, pull requests and commit messages. Our own build and
review processes are kevin tasks, so contributing doubles as dogfooding.

## Getting started

You need Zig 0.17.0 or newer.

```sh
zig build                  # bootstrap the first binary
./zig-out/bin/kevin --help # list every task declared in README.md and build.md
./zig-out/bin/kevin -f CONTRIBUTING.md --help   # tasks declared in this file
```

Put `zig-out/bin` on your `PATH` (or run `kevin install`) to type `kevin` directly.

## Daily workflow

| Goal                     | Command                  |
|--------------------------|--------------------------|
| Compile                  | `kevin build`            |
| Unit tests               | `kevin test`             |
| Format sources           | `kevin fmt`              |
| Everything CI runs       | `kevin check`            |
| Cross-compile releases   | `kevin release`          |

Run `kevin check` before opening a pull request. New behaviour needs a
`test "..."` block next to the code it covers, and user-visible changes need
a README update (the README is itself a kevin file, so keep its tasks working).

## Commit messages

History must stay English-only and use
[Conventional Commits](https://www.conventionalcommits.org/):

```text
type(scope): imperative summary of at most 72 characters

Optional body explaining why, wrapped at about 72 columns.
```

Allowed types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `build`,
`ci`, `perf`, `style`. Scopes are optional, for example `parser`, `cli`,
`runner`. The hook below rejects non-ASCII text and malformed subjects.

## > hooks
> Install the repository git hooks (run once after cloning)

```sh
git config core.hooksPath .githooks
echo "hooks installed: commit messages are now validated"
```

## > lint-commits
> Validate the messages of existing commits with the same rules as the hook

**OPTIONS**
* range
    * flags: -r --range
    * type: string
    * desc: Git revision range to check (default HEAD)

```bash
set -eu
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
for commit in $(git rev-list "${range:-HEAD}"); do
  git log -1 --format=%B "$commit" > "$tmp"
  .githooks/commit-msg "$tmp" || { echo "offending commit: $commit" >&2; exit 1; }
done
echo "all commit messages are valid"
```
