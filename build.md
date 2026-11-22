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
echo "smoke: ok"
```

## > check
> Everything CI runs: formatting, unit tests and the smoke test

```sh
$KEVIN fmt-check
$KEVIN test
$KEVIN smoke
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
