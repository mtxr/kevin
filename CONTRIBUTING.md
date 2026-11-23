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

## Continuous integration

GitHub Actions runs on hosted runners (`.github/workflows`):

- `ci.yml` on every push to `main` and every pull request: `kevin check` on
  Linux and macOS, unit tests on Windows, a cross-compile of every release
  target, and a lint of the pull request's commit messages.
- `release-please.yml` on every push to `main`: runs
  [release-please](https://github.com/googleapis/release-please-action) in
  manifest mode (`release-please-config.json`, `.release-please-manifest.json`).
  Its `assets` job runs only when a release was created: it builds the tag,
  runs `kevin check`, cross-compiles every target and uploads the archives and
  a `SHA256SUMS` file to the release. It lives in the same workflow because
  tags created with the default `GITHUB_TOKEN` do not trigger other workflows.

Actions are pinned to commit SHAs. When bumping one, update the SHA and the
tag named in the trailing comment together.

## Releases

Releases are automated from Conventional Commits; never tag by hand.

1. Merge Conventional Commits into `main`.
2. release-please opens (and keeps updating) a release PR that bumps
   `.version` in `build.zig.zon` (the `x-release-please-version` annotation)
   and updates `CHANGELOG.md`. Only `feat`, `fix`, `perf`, `refactor` and
   `docs` appear in the changelog.
3. Merging that PR creates the `vX.Y.Z` tag and GitHub release, and the
   `assets` job attaches the binaries.

Versioning below 1.0 (`bump-minor-pre-major`): `feat` and breaking changes
(`!` or a `BREAKING CHANGE:` footer) bump the minor version, `fix` bumps the
patch. To force a version, add a `Release-As: x.y.z` footer to a commit body
on `main`.

The first release (v0.1.0) was forced with `release-as`; that line is gone, so
later versions follow the commit types (`feat` bumps the minor while below 1.0).

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
