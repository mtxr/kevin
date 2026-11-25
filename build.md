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
# A .wasm plugin converts inside the sandbox: stdin in, stdout out, its exit code is an error.
printf 'hi\n' > "$tmp/plugin-in.txt"
[ "$($bin --from src/testdata/echo.wasm -f "$tmp/plugin-in.txt" 2>/dev/null)" = "$(printf 'echo:HI')" ] || { echo "smoke: wasm plugin output mismatch"; exit 1; }
: > "$tmp/plugin-empty.txt"
$bin --from src/testdata/echo.wasm -f "$tmp/plugin-empty.txt" 2>/dev/null && { echo "smoke: wasm plugin failure ignored"; exit 1; }
# Registered plugins: added by name, checked against their sha256, refused when changed.
export KEVIN_PLUGIN_DIR="$tmp/plugins"
$bin --plugin-add examples/plugins/lines/lines.wasm >/dev/null || { echo "smoke: --plugin-add failed"; exit 1; }
[ "$($bin --plugin-list | cut -d' ' -f1)" = "lines" ] || { echo "smoke: --plugin-list does not show the plugin"; exit 1; }
printf 'greet: echo hi\n' > "$tmp/reg.txt"
$bin --from lines -f "$tmp/reg.txt" 2>/dev/null | grep -q '^## > greet$' || { echo "smoke: --from <registered plugin> failed"; exit 1; }
printf 'x' >> "$KEVIN_PLUGIN_DIR/lines.wasm"
$bin --from lines -f "$tmp/reg.txt" >/dev/null 2>&1 && { echo "smoke: a modified plugin was run"; exit 1; }
$bin --plugin-remove lines || { echo "smoke: --plugin-remove failed"; exit 1; }
unset KEVIN_PLUGIN_DIR
# The example plugin uses memory.copy/fill (bulk memory), which compilers emit by default.
printf 'greet: echo hi from a plugin\n' > "$tmp/lines.txt"
$bin --from examples/plugins/lines/lines.wasm -f "$tmp/lines.txt" -o "$tmp/lines.md" 2>/dev/null
[ "$($bin -f "$tmp/lines.md" greet)" = "hi from a plugin" ] || { echo "smoke: example plugin output does not run"; exit 1; }

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

# Structured dependencies: expanded values are data, never commands or flags.
sd=examples/structured-deps.md
[ "$($bin -f $sd deploy docs | head -n 1)" = "build target=[docs] dry_run=[unset]" ] || { echo "smoke: a value shadowed by a subcommand"; exit 1; }
[ "$($bin -f $sd deploy -- -n | head -n 1)" = "build target=[-n] dry_run=[unset]" ] || { echo "smoke: a value was read as a flag"; exit 1; }
[ "$($bin -f $sd deploy -- --help | head -n 1)" = "build target=[--help] dry_run=[unset]" ] || { echo "smoke: --help value was honoured"; exit 1; }
[ "$($bin -f $sd deploy '' | head -n 1)" = "build target=[] dry_run=[unset]" ] || { echo "smoke: an empty value was dropped"; exit 1; }
[ "$($bin -f $sd serve | head -n 1)" = "build target=[prod] dry_run=[true]" ] || { echo "smoke: a literal flag in Requires stopped working"; exit 1; }

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

# An absent optional argument is empty even when the caller's environment sets it.
[ "$(name=Bob $bin -f examples/regressions.md optional-arg)" = "name=[]" ] || { echo "smoke: optional argument leaked from the environment"; exit 1; }
[ "$(name=Bob $bin -f examples/regressions.md optional-arg claude)" = "name=[claude]" ] || { echo "smoke: optional argument not passed"; exit 1; }
[ "$($bin -f examples/regressions.md positional a)" = "count=1 first=[a] second=[]" ] || { echo "smoke: positional parameters (one argument)"; exit 1; }
[ "$($bin -f examples/regressions.md positional a b)" = "count=2 first=[a] second=[b]" ] || { echo "smoke: positional parameters (two arguments)"; exit 1; }
$bin -f examples/tasks.md --complete hel | grep -q "^hello" || { echo "smoke: completion of a command name"; exit 1; }
$bin -f examples/tasks.md --complete "" | grep -q . || { echo "smoke: completion lists commands"; exit 1; }
[ "$($bin -f examples/runtimes.md blocks | tail -1)" = "second block sees SHARED=[]" ] || { echo "smoke: blocks must not share variables"; exit 1; }
for sh in zsh bash fish; do $bin --completion $sh | grep -q kevin || { echo "smoke: completion script for $sh"; exit 1; }; done

# Absent or false flags are unset: a same-named variable of the caller never leaks in.
[ "$(dry_run=true port=99 $bin -f examples/regressions.md flagged)" = "dry_run=[unset] port=[unset]" ] || { echo "smoke: absent flags leaked from the environment"; exit 1; }
[ "$(dry_run=true $bin -f examples/regressions.md flagged --dry-run=false)" = "dry_run=[unset] port=[unset]" ] || { echo "smoke: a false flag leaked from the environment"; exit 1; }
[ "$($bin -f examples/regressions.md flagged --dry-run -p 5)" = "dry_run=[true] port=[5]" ] || { echo "smoke: flags not passed"; exit 1; }
case "$(port=3 $bin -f examples/regressions.md --explain flagged)" in *'env: port = (unset'*) ;; *) echo "smoke: explain does not show unset flags"; exit 1 ;; esac

# Example blocks (a block after prose that follows an earlier block) do not run unless tagged `task`.
[ "$($bin -f examples/regressions.md examples)" = "$(printf 'real\nopted-in')" ] || { echo "smoke: example block ran as a script"; exit 1; }
case "$($bin -f examples/regressions.md --explain examples)" in *'skipped (example:'*'add `task`'*) ;; *) echo "smoke: explain does not show the skipped example"; exit 1 ;; esac

# Attribute lines are only recognised as plain lines right after the heading; names are validated.
fence='```'
{
  printf '## > tools\n> Documentation that mentions requirements\n\n**Requires:** Node.js 18+, pnpm\n\n* Requires: eslint\n\n'
  printf '%ssh\necho tools ok\n%s\n\n' "$fence" "$fence"
  printf '## > bad (PATH) (my-arg) (ok) (ok)\n\n%ssh\necho "ok=[$ok]"\n%s\n\n' "$fence" "$fence"
  printf '## > open\n\n%ssh\necho before\n' "$fence"
} > "$tmp/prose.md"
[ "$($bin -f "$tmp/prose.md" tools 2>/dev/null)" = "tools ok" ] || { echo "smoke: decorated Requires text was parsed as an attribute"; exit 1; }
msg=$($bin -f "$tmp/prose.md" bad x 2>&1)
case "$msg" in *"'PATH' is reserved"*"invalid argument name 'my-arg'"*"'ok' is already declared"*"ok=[x]"*) ;; *) echo "smoke: argument names not validated: $msg"; exit 1 ;; esac
msg=$($bin -f "$tmp/prose.md" open 2>&1)
case "$msg" in *"code block opened on line"*"is not closed; it runs to the end of the file"*) ;; *) echo "smoke: unterminated fence not reported: $msg"; exit 1 ;; esac

# xc migration: tagged shell blocks also get set -e, and cd aborts on failure.
printf '## Tasks\n\n### t\n\n%ssh\necho tagged\n%s\n' "$fence" "$fence" > "$tmp/xc-tagged.md"
$bin --from xc -f "$tmp/xc-tagged.md" 2>/dev/null | grep -q '^set -e$' || { echo "smoke: xc tagged block without set -e"; exit 1; }
$bin --from xc -f "$tmp/xc-tagged.md" 2>/dev/null | grep -q 'KEVIN_DIR" || exit 1$' || { echo "smoke: xc cd does not abort on failure"; exit 1; }

# Process handling: stdin, temp scripts, signals, fail-fast, --jobs and recursion.
proc=examples/process.md
[ "$(echo hi | $bin -f $proc read-stdin)" = "got=hi" ] || { echo "smoke: block did not inherit stdin"; exit 1; }
[ "$($bin -f $proc script-path)" = "file" ] || { echo "smoke: block did not run from a temp file"; exit 1; }
mkdir "$tmp/tmpdir"
TMPDIR="$tmp/tmpdir" $bin -f $proc script-path >/dev/null
[ -z "$(ls -A "$tmp/tmpdir")" ] || { echo "smoke: temp directory left behind"; exit 1; }
# A block larger than the kernel's single-argument limit (128 KiB on Linux).
{ printf '## > big\n\n```sh\n# '; head -c 300000 /dev/zero | tr '\0' 'x'; printf '\necho big-ok\n```\n'; } > "$tmp/big.md"
[ "$($bin -f "$tmp/big.md" big)" = "big-ok" ] || { echo "smoke: large block failed"; exit 1; }

# SIGTERM is forwarded to the running child and its subtree; kevin exits 143.
mkdir "$tmp/sig"
TMPDIR="$tmp/tmpdir" $bin -f $proc hang "$tmp/sig" </dev/null >/dev/null 2>&1 &
kpid=$!
for _ in $(seq 1 50); do [ -s "$tmp/sig/hang.pid" ] && break; sleep 0.1; done
[ -s "$tmp/sig/hang.pid" ] || { echo "smoke: hang task did not start"; exit 1; }
cpid=$(cat "$tmp/sig/hang.pid")
kill -TERM "$kpid"
set +e
wait "$kpid"
rc=$?
set -e
[ "$rc" = "143" ] || { echo "smoke: SIGTERM exit code was $rc"; exit 1; }
sleep 0.2
if kill -0 "$cpid" 2>/dev/null; then kill "$cpid"; echo "smoke: child survived SIGTERM"; exit 1; fi
[ -z "$(ls -A "$tmp/tmpdir")" ] || { echo "smoke: temp directory left behind after SIGTERM"; exit 1; }

# A failing async dependency stops running siblings and starts no pending ones.
mkdir "$tmp/ff"
set +e
$bin -f $proc failfast "$tmp/ff" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "9" ] || { echo "smoke: fail-fast exit code was $rc"; exit 1; }
sleep 0.3
[ ! -e "$tmp/ff/slow-finished" ] || { echo "smoke: running sibling was not stopped"; exit 1; }
[ ! -e "$tmp/ff/late-started" ] || { echo "smoke: pending sibling started after a failure"; exit 1; }

# --jobs bounds concurrency in both directions.
mkdir "$tmp/j12" "$tmp/j2"
$bin -j 12 -f $proc probes-12 "$tmp/j12"
[ "$(sort -n "$tmp/j12/peaks" | tail -n 1)" -ge 8 ] || { echo "smoke: -j 12 did not run the dependencies together"; exit 1; }
$bin -j 2 -f $proc probes-4 "$tmp/j2"
[ "$(sort -n "$tmp/j2/peaks" | tail -n 1)" -le 2 ] || { echo "smoke: -j 2 ran more than two at once"; exit 1; }

# A task that calls itself through $KEVIN stops at the nesting limit.
set +e
msg=$($bin -f $proc recurse 2>&1)
rc=$?
set -e
[ "$rc" = "2" ] || { echo "smoke: recursion ended with $rc"; exit 1; }
case "$msg" in *'kevin runs deep'*) ;; *) echo "smoke: no recursion message: $msg"; exit 1 ;; esac

# --introspect prints the command tree as JSON.
intro=$($bin -f examples/tasks.md --introspect)
case "$intro" in *'"name": "hello"'*'"required": true'*) ;; *) echo "smoke: introspect output mismatch"; exit 1 ;; esac

# --explain describes a command without running it; --version prints the version.
exp=$($bin -f examples/tasks.md --explain hello World -t 2)
case "$exp" in *'name (required) = World'*'argv:    bash <temp file>'*) ;; *) echo "smoke: explain output mismatch"; exit 1 ;; esac
$bin -f examples/tasks.md --explain hello World -t abc >/dev/null 2>&1 && { echo "smoke: explain accepted bad input"; exit 1; }
case "$($bin --version)" in "kevin "*) ;; *) echo "smoke: unexpected version output"; exit 1 ;; esac

# Never read the developer's real ~/.kevinrc; the global-rc checks below set their own.
export KEVIN_GLOBAL_RC=
# .kevinrc: globs, direct paths, excludes, $KEVIN over the whole set, repeated -f.
rcbin=$PWD/$bin
rc() { (cd examples/rc && "$rcbin" "$@"); }
[ "$(rc from-readme)" = "readme" ] || { echo "smoke: default file missing with .kevinrc"; exit 1; }
[ "$(rc from-ops)" = "ops" ] || { echo "smoke: direct path include failed"; exit 1; }
[ "$(rc from-guide)" = "guide" ] && [ "$(rc from-api)" = "api" ] || { echo "smoke: glob include failed"; exit 1; }
[ "$(rc deploy)" = "deploy" ] || { echo "smoke: nested glob include failed"; exit 1; }
set +e
rc from-draft >/dev/null 2>&1
[ "$?" = "2" ] || { echo "smoke: direct exclude failed"; exit 1; }
rc from-secret >/dev/null 2>&1
[ "$?" = "2" ] || { echo "smoke: glob exclude failed"; exit 1; }
set -e
[ "$(rc via-kevin)" = "ops" ] || { echo "smoke: \$KEVIN does not see the other files"; exit 1; }
exp=$(rc --explain from-api)
case "$exp" in *'(.kevinrc line 3)'*'excluded: docs/draft.md (.kevinrc line 6)'*) ;; *) echo "smoke: explain does not show .kevinrc: $exp"; exit 1 ;; esac
rc --complete "" | grep -q '^from-guide' || { echo "smoke: completion ignores .kevinrc"; exit 1; }
[ "$(rc -f ops.md -f docs/api.md from-api)" = "api" ] && [ "$(rc -f ops.md -f docs/api.md from-ops)" = "ops" ] || { echo "smoke: repeated -f failed"; exit 1; }
set +e
rc -f README.md from-ops >/dev/null 2>&1
[ "$?" = "2" ] || { echo "smoke: -f did not ignore .kevinrc"; exit 1; }
set -e
# Without a .kevinrc only the default files load; a missing direct path warns.
mkdir "$tmp/rcdefault" "$tmp/rcmissing"
cp examples/rc/README.md examples/rc/ops.md "$tmp/rcdefault/"
cp examples/rc/README.md examples/rc/.kevinrc "$tmp/rcmissing/"
printf 'nope.md\n' >> "$tmp/rcmissing/.kevinrc"
[ "$(cd "$tmp/rcdefault" && "$rcbin" from-readme)" = "readme" ] || { echo "smoke: default discovery changed"; exit 1; }
set +e
(cd "$tmp/rcdefault" && "$rcbin" from-ops >/dev/null 2>&1)
[ "$?" = "2" ] || { echo "smoke: ops.md loaded without .kevinrc"; exit 1; }
set -e
msg=$(cd "$tmp/rcmissing" && "$rcbin" from-readme 2>&1)
case "$msg" in *"\`.kevinrc\` line 8: 'nope.md' does not exist"*) ;; *) echo "smoke: no warning for a missing .kevinrc entry: $msg"; exit 1 ;; esac

# Global .kevinrc: relative to the home directory, applied before the project files.
mkdir -p "$tmp/ghome/docs" "$tmp/gproj"
printf '# global\nops.md\ndocs/*.md\n/etc/x.md\nmissing.md\n' > "$tmp/ghome/.kevinrc"
cp examples/rc/ops.md "$tmp/ghome/ops.md"
printf '# Global\n\n## > from-gdoc\n\n```sh\necho gdoc\n```\n' > "$tmp/ghome/docs/g.md"
cp examples/rc/README.md "$tmp/gproj/"
g() { (cd "$tmp/gproj" && HOME="$tmp/ghome" KEVIN_GLOBAL_RC="$tmp/ghome/.kevinrc" "$rcbin" "$@"); }
[ "$(g from-ops)" = "ops" ] && [ "$(g from-gdoc)" = "gdoc" ] && [ "$(g from-readme)" = "readme" ] || { echo "smoke: global .kevinrc not applied"; exit 1; }
msg=$(g from-readme 2>&1)
case "$msg" in *"global \`.kevinrc\` ($tmp/ghome/.kevinrc) line 4: '/etc/x.md'"*"line 5: 'missing.md' does not exist"*) ;; *) echo "smoke: global warnings do not name the file: $msg"; exit 1 ;; esac
exp=$(g --explain from-ops)
case "$exp" in *"(global .kevinrc line 2)"*) ;; *) echo "smoke: explain does not show the global origin: $exp"; exit 1 ;; esac
# A project .kevinrc can exclude a global file by its home-relative name.
printf '!ops.md\n' > "$tmp/gproj/.kevinrc"
set +e
g from-ops >/dev/null 2>&1
[ "$?" = "2" ] || { echo "smoke: project exclude did not drop a global file"; exit 1; }
set -e
[ "$(g from-gdoc)" = "gdoc" ] || { echo "smoke: project exclude dropped too much"; exit 1; }
# An empty override disables the global file.
set +e
(cd "$tmp/gproj" && HOME="$tmp/ghome" KEVIN_GLOBAL_RC= "$rcbin" from-gdoc >/dev/null 2>&1)
[ "$?" = "2" ] || { echo "smoke: empty KEVIN_GLOBAL_RC did not disable the global file"; exit 1; }
set -e

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
