# Converter plugins

kevin reads Markdown. Everything else (a `package.json`, a `justfile`, a
`Makefile`, ...) is turned into Markdown by a **converter**. `mask` and `xc`
are built in; for any other format a converter can be a **WebAssembly plugin**
that anyone can write, in any language that compiles to WebAssembly, and run
with `kevin --from ./plugin.wasm -f <input>`.

> **Status: experimental.** What is described under [How it works](#how-it-works),
> [Try it](#try-it-in-two-minutes), [Writing a plugin](#writing-a-plugin),
> [Testing](#testing), [Registering a plugin](#registering-a-plugin) and
> [Running straight from the source file](#running-straight-from-the-source-file) exists and is tested. [Publishing](#publishing) and
> [Not yet](#not-yet) are plans or known gaps, and are labelled as such.

## How it works

A plugin is a plain command-line program compiled to WebAssembly (WASI). kevin
starts it with the arguments `--path <the input file as given>`, so a plugin
can tell what it is converting. The contract is one function, `parse(content: String) -> Result<String, Error>`,
expressed with the three standard streams:

| Plugin does | Meaning for kevin |
|---|---|
| Reads **stdin** | The whole content of the input file. |
| Writes **stdout** | The kevin Markdown. Exit code 0 means this is the result. |
| Writes **stderr** | Notes for a human, one per line (printed as `kevin: note: ...`). |
| Exits with a **non-zero code** | An error. Nothing is written; stderr is shown with the code. |

kevin does not run the output. `--from` prints it (or writes it with `-o`) so
you can read it before you run it.

### The sandbox

A plugin is untrusted code, and it can only do one thing: turn the bytes it is
given into other bytes. The host functions it may import are fixed, and none
of them reaches the outside world:

| Capability | Policy |
|---|---|
| Network | None. The runtime has no network functions to import. |
| Shell, processes | None. |
| Filesystem | None. There are no preopened directories; the input arrives on stdin. |
| Environment | Empty. |
| Arguments | Only `--path <input file>`. |
| Clock | Frozen at 0, so a conversion is reproducible. |
| Randomness | A fixed-seed generator, for the same reason. |
| `proc_exit` | Ends the plugin only, never kevin. |

An import outside that list is simply not provided: the module still loads, and
the plugin traps the moment it calls the missing function, with an error that
names it. Resource limits, enforced by the runtime:

| Limit | Default |
|---|---|
| Memory (module, stack and linear memory together) | 64 MiB |
| WebAssembly instructions executed | 1 000 000 000 |
| Bytes on stdout, and on stderr | 16 MiB each |
| Plugin file size | 8 MiB |

The sandbox protects the *act of converting*. It does not make the Markdown a
plugin produces trustworthy: that Markdown contains scripts kevin will run. Read
what a plugin generated before you run it, the same way you would read a
`maskfile.md` you did not write.

## Try it in two minutes

Build kevin once (Zig 0.17 or newer), then convert with the bundled example,
a plugin that turns `name: command` lines into tasks:

```sh
zig build
printf 'build: zig build\nhello: echo hello from a plugin\n' > todo.txt

./zig-out/bin/kevin --from examples/plugins/lines/lines.wasm -f todo.txt -o todo.md
./zig-out/bin/kevin -f todo.md            # lists the generated commands
./zig-out/bin/kevin -f todo.md hello      # runs one
```

Without `-o` the result goes to stdout. `-o` never overwrites a file.

Lines that are not `name: command` are reported as notes and skipped, and an
input without any task makes the plugin exit with code 1:

```console
$ printf 'broken\n' > bad.txt
$ ./zig-out/bin/kevin --from examples/plugins/lines/lines.wasm -f bad.txt
kevin: plugin 'examples/plugins/lines/lines.wasm' exited with code 1: skipped a line that is not 'name: command'
no 'name: command' line found
```

## Writing a plugin

Start from [`examples/plugins/lines/lines.zig`](examples/plugins/lines/lines.zig):
about a hundred lines, no dependencies. It reads stdin, writes the Markdown and
a note, and uses `proc_exit(1)` for errors. The smallest possible shape is
`src/testdata/echo.zig`.

Build it:

```sh
zig build-exe lines.zig -target wasm32-freestanding -O ReleaseSmall \
    -fno-entry --export=_start -femit-bin=lines.wasm
```

The module must export `_start` and may import only these `wasi_snapshot_preview1`
functions:

`fd_read`, `fd_write`, `fd_close`, `fd_seek`, `fd_fdstat_get`, `fd_prestat_get`,
`fd_prestat_dir_name`, `args_sizes_get`, `args_get`, `environ_sizes_get`,
`environ_get`, `clock_time_get`, `random_get`, `proc_exit`.

Only file descriptors 0 (stdin), 1 (stdout) and 2 (stderr) exist. Compilers
emit `memory.copy` and `memory.fill` for ordinary code, and the runtime
supports them.

### What to produce

A kevin task is a heading and a code block:

````markdown
# Tasks

## > build

```sh
zig build
```
````

See [`README.md`](README.md) for the full syntax (arguments, options,
`Requires`, languages). `kevin --from mask -f examples/maskfile.md` is a
larger example of generated output.

### Other languages

Any language that produces a WASI command works in principle, as long as it
uses only the imports above. **These have not been tried against kevin yet**,
so treat them as starting points, not as instructions:

- **Rust**: `rustup target add wasm32-wasip1`, then `cargo build --release
  --target wasm32-wasip1` on a normal `fn main()` that reads
  `std::io::stdin()` and prints.
- **JavaScript**: bundle with `esbuild` and compile to a WASI module with
  [Javy](https://github.com/bytecodealliance/javy) (QuickJS inside the module).
  There is no Node API in it: no `fs`, no `process`, no `require`; `JSON.parse`
  works.

If a toolchain's standard library calls a function that is not in the list
above, the plugin fails at that call and the error names the function. That is
either a capability the sandbox deliberately withholds or a gap in kevin's
allow-list; ask before working around it in the plugin.

## Testing

**By hand.** Run the plugin and read the result:

```sh
kevin --from ./plugin.wasm -f input.ext               # stdout
kevin --from ./plugin.wasm -f input.ext -o out.md      # file; refuses to overwrite
kevin -f out.md --explain <command>                    # what would run, without running
kevin -f out.md --introspect                           # the generated command tree as JSON
```

Check, in this order: the exit code (`echo $?`), the notes on stderr, that
`kevin -f out.md` lists the commands you expect, and that a harmless one runs.

**As a program, outside kevin.** The contract is plain stdin and stdout, so
the same logic can be exercised natively while you develop: build the same
source for your host and pipe a file through it (`./plugin < input.ext`).
Only the `.wasm` goes through the sandbox, so run the WebAssembly build at
least once before you call a change done.

**As a regression test.** Keep a few inputs next to the plugin with the Markdown
you expect, convert them, and compare:

```sh
for f in tests/*.in; do
  kevin --from ./plugin.wasm -f "$f" | diff -u "${f%.in}.md" - || exit 1
done
```

kevin's own tests do the same for the bundled examples: the `smoke` task in
`build.md` converts with `src/testdata/echo.wasm` and with
`examples/plugins/lines/lines.wasm`, runs the result, and checks that a plugin
exiting with a code makes `--from` fail.

### When something goes wrong

| Message | Cause |
|---|---|
| `cannot read plugin '...'` | The `.wasm` path is wrong, or the file is over 8 MiB. |
| `invalid module: ... unsupported opcode ...` | The module uses a WebAssembly feature the runtime does not have enabled. Report it with the toolchain and flags you used. |
| `Exception: failed to call unlinked import function (module, name)` | The plugin called a function outside the allow-list above. |
| `the module does not export '_start'` | Not a command module: export `_start` (in Zig, `-fno-entry --export=_start`). |
| `plugin '...' exited with code N` | The plugin chose to fail; its stderr follows the code. |
| `the plugin produced too much output` | More than 16 MiB on stdout or stderr. |
| An error naming an exception such as `instruction limit exceeded` | The plugin ran out of its instruction budget, usually an endless loop. |
| `no WebAssembly runtime` | This build of kevin lacks the runtime (see [Not yet](#not-yet)). |

## Registering a plugin

A plugin you use regularly can be registered on this machine and then named
instead of pointed at:

```sh
kevin --plugin-add ./lines.wasm          # copies it in and records its sha256
kevin --plugin-list                      # name and hash prefix of each plugin
kevin --from lines -f todo.txt           # a built-in name wins, then a registered one
kevin --plugin-remove lines
```

The name is the file name without `.wasm` (lowercase letters, digits, `-` and
`_`). Plugins live in `$KEVIN_PLUGIN_DIR`, else `$XDG_CONFIG_HOME/kevin/plugins`,
else `~/.config/kevin/plugins`, next to a `plugins.lock` with one
`<name> <sha256>` per line. Every use re-checks the hash: if the file changed
since you added it, kevin refuses to run it and tells you how to re-add it
deliberately. Adding never downloads anything, and a different file under an
existing name needs `--plugin-remove` first.

The flags are `--plugin-*`, not a `kevin plugin ...` command, so they can never
shadow a task of that name in your Markdown.

## Running straight from the source file

Bind a file to a registered plugin in `.kevinrc` and its tasks run without
converting by hand:

```text
# .kevinrc
todo.txt -> lines
```

```sh
kevin             # lists the commands, including those from todo.txt
kevin hello       # runs it
```

Each run converts in memory (nothing is written), merges the result with your
Markdown files (later files win), and treats notes as warnings. Plugin failure,
or output without a single command, stops kevin with an error. `kevin --explain`
shows `todo.txt` as a source. The same review advice applies: the generated
commands are what runs.

## Publishing

> **Planned, not implemented.** Today, publishing means handing someone the
> `.wasm` file. They run it with `--from ./path/to/plugin.wasm`, after reading
> this page's sandbox section. Nothing is downloaded or installed by kevin.

The intended path, so that plugins can live and evolve without going through
this repository:

1. A plugin is a repository that publishes a `.wasm` file with each release (a
   single file runs on every operating system and CPU).
2. `kevin plugin install <owner>/<repo>[@version]` downloads that file into the
   user's configuration directory and records its sha256 in a lockfile, so a
   later change to the release is noticed.
3. Discovery starts as a GitHub topic (`kevin-converter`). A registry, an index
   file in a repository where adding a plugin is a pull request, comes later if
   there is demand.
4. A manifest the plugin describes itself with (the files it understands, such
   as `package.json`, so `.kevinrc` can map globs like `packages/*/package.json`
   to it, and whether it needs to read sibling files).

Native code is never downloaded: only `.wasm`, which kevin validates and runs
in the sandbox above.

## Not yet

Known gaps, in rough order of when they are likely to be addressed:

- **Windows.** The runtime is built for macOS and Linux (x86-64 and arm64). On
  other targets `--from x.wasm` reports that the build has no runtime.
- **Reading other files.** A plugin only sees its stdin. Formats that include
  other files (`import` in a `justfile`) need a read-only window onto the
  project directory. Anything outside the project root will stay rejected.
- **The manifest, `plugin install` and the lockfile** described under
  Publishing.
- **Validating the output.** kevin does not yet parse a plugin's stdout before
  printing it; a plugin can emit text that is not valid kevin Markdown.
- **Per-run limits are not configurable** from the command line.
- **Many inputs.** One invocation converts one file; combining several (a
  monorepo's `package.json` files) is not designed yet.
