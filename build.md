# Build tasks

Build, test and release processes for kevin, written as kevin tasks.
Bootstrap once with `zig build`, then use `./zig-out/bin/kevin <task>`.

## > build
> Compile kevin into zig-out/bin

**OPTIONS**
* optimize
    * flags: -O --optimize
    * type: string
    * choices: Debug, ReleaseSafe, ReleaseFast, ReleaseSmall
    * desc: Optimization mode (default Debug)

```sh
zig build -Doptimize="${optimize:-Debug}"
```

## > test
> Run the unit tests

```sh
zig build test --summary all
```

## > fmt
> Format all Zig sources in place

```sh
zig fmt build.zig src
```

## > fmt-check
> Fail if any Zig source is not formatted

```sh
zig fmt --check build.zig src
```

## > smoke
> Build, then run examples/tasks.md end to end and assert the results

```bash
set -eu
zig build
bin=./zig-out/bin/kevin

out=$($bin -f examples/tasks.md hello World -s -t 2 -c red)
expected=$(printf 'HELLO, WORLD (red)\nHELLO, WORLD (red)')
[ "$out" = "$expected" ] || { echo "smoke: hello output mismatch: $out"; exit 1; }

$bin -f examples/tasks.md hello World -t abc 2>/dev/null && { echo "smoke: bad number accepted"; exit 1; }
$bin -f examples/tasks.md hello World -c blue 2>/dev/null && { echo "smoke: bad choice accepted"; exit 1; }

set +e
$bin -f examples/tasks.md fail >/dev/null
[ "$?" = "7" ] || { echo "smoke: exit code was not propagated"; exit 1; }
set -e

mig=$($bin -f examples/tasks.md rodar-migracoes prod)
case "$mig" in *'migrating prod'*'py sees prod'*) ;; *) echo "smoke: pipeline output mismatch"; exit 1 ;; esac
# Migration from mask and xc produces files kevin can run.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
$bin --from mask -f examples/maskfile.md -o "$tmp/mask.md" 2>/dev/null
[ "$($bin -f "$tmp/mask.md" greet Ann -s)" = "HELLO, ANN" ] || { echo "smoke: mask migration failed"; exit 1; }
[ "$($bin -f "$tmp/mask.md" both)" = "$(printf 'Hello, Mask\nservices are up')" ] || { echo "smoke: mask chaining failed"; exit 1; }
$bin --from xc -f examples/xc.md -o "$tmp/xc.md" 2>/dev/null
[ "$($bin -f "$tmp/xc.md" greet Joe)" = "Hello, Joe." ] || { echo "smoke: xc inputs failed"; exit 1; }
[ "$($bin -f "$tmp/xc.md" both)" = "$(printf 'hi\nboth')" ] || { echo "smoke: xc requires failed"; exit 1; }
$bin --from xc -f examples/maskfile.md -o "$tmp/none.md" 2>/dev/null && { echo "smoke: xc without Tasks accepted"; exit 1; }

# Dependencies: order, once-per-run, async, arguments, failure and cycles.
[ "$($bin -f examples/deps.md ordered)" = "$(printf 'setup\nstep 1\nstep 2\nordered')" ] || { echo "smoke: sync requires failed"; exit 1; }
par=$($bin -f examples/deps.md parallel)
[ "$(printf '%s\n' "$par" | grep -c '^setup$')" = "1" ] || { echo "smoke: Run: once did not dedupe"; exit 1; }
[ "$(printf '%s\n' "$par" | grep -c '^step ')" = "3" ] && [ "$(printf '%s\n' "$par" | tail -n 1)" = "parallel" ] || { echo "smoke: async requires failed"; exit 1; }
[ "$($bin -j 1 -f examples/deps.md parallel | tail -n 1)" = "parallel" ] || { echo "smoke: --jobs 1 failed"; exit 1; }
[ "$($bin -f examples/deps.md forward x | tail -n 1)" = "forward x" ] || { echo "smoke: argument expansion failed"; exit 1; }
set +e
out=$($bin -f examples/deps.md fails)
[ "$?" = "9" ] || { echo "smoke: dependency failure code not propagated"; exit 1; }
case "$out" in *"never printed"*) echo "smoke: script ran after a failed dependency"; exit 1 ;; esac
$bin -f examples/deps.md loop-a >/dev/null 2>&1
[ "$?" = "2" ] || { echo "smoke: dependency cycle not rejected"; exit 1; }
$bin -j 0 -f examples/deps.md parallel >/dev/null 2>&1
[ "$?" = "2" ] || { echo "smoke: invalid --jobs accepted"; exit 1; }
set -e

# Regressions: indented fences inside a block, flags without a flags line,
# a UTF-8 BOM, and a directory without any task file.
[ "$($bin -f examples/regressions.md heredoc | tail -n 1)" = "after" ] || { echo "smoke: indented fence truncated the script"; exit 1; }
[ "$($bin -f examples/regressions.md heredoc | grep -c 'code sample')" = "1" ] || { echo "smoke: heredoc content lost"; exit 1; }
[ "$($bin -f examples/regressions.md derived-flag --watch-mode)" = "watch_mode=true" ] || { echo "smoke: derived flag rejected"; exit 1; }
printf '\357\273\277## > hi\n\n```sh\necho hi\n```\n' > "$tmp/bom.md"
[ "$($bin -f "$tmp/bom.md" hi)" = "hi" ] || { echo "smoke: BOM hides the first heading"; exit 1; }
mkdir "$tmp/empty"
set +e
msg=$(cd "$tmp/empty" && "$OLDPWD/$bin" build 2>&1)
[ "$?" = "2" ] || { echo "smoke: missing task file did not exit 2"; exit 1; }
set -e
case "$msg" in *'no README.md, tasks.md or build.md found'*) ;; *) echo "smoke: wrong message without task files: $msg"; exit 1 ;; esac

# --explain describes a command without running it; --version prints the version.
exp=$($bin -f examples/tasks.md --explain hello World -t 2)
case "$exp" in *'name (required) = World'*'argv:    bash -c <code>'*) ;; *) echo "smoke: explain output mismatch"; exit 1 ;; esac
$bin -f examples/tasks.md --explain hello World -t abc >/dev/null 2>&1 && { echo "smoke: explain accepted bad input"; exit 1; }
case "$($bin --version)" in "kevin "*) ;; *) echo "smoke: unexpected version output"; exit 1 ;; esac

echo "smoke: ok"
```

## > compat
> Build, then run the mask/xc compatibility suite in tests/compat (pass/xfail summary)

```sh
set -e
cd "$KEVIN_DIR"
zig build
sh tests/compat/run.sh zig-out/bin/kevin
```

## > check
> Everything CI runs: formatting, unit tests, the smoke test and the compatibility suite

```sh
set -e
$KEVIN fmt-check
$KEVIN test
$KEVIN smoke
$KEVIN compat
```

## > release
> Cross-compile ReleaseSafe binaries for every supported target into dist/

```bash
set -eu
rm -rf dist
for target in x86_64-linux aarch64-linux x86_64-macos aarch64-macos x86_64-windows; do
  echo "building $target"
  zig build -Dtarget="$target" -Doptimize=ReleaseSafe --prefix "dist/$target"
done
```

## > clean
> Remove build artifacts

```sh
rm -rf zig-out .zig-cache dist
```
