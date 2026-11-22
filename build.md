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
