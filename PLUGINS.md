# Converter plugins

kevin reads Markdown. Everything else (a `package.json`, a `justfile`, a
`Makefile`, ...) is turned into Markdown by a **converter**. `mask` and `xc`
are built in; for any other format a converter can be a **WebAssembly plugin**
that anyone can write, in any language that compiles to WebAssembly, and run
with `kevin --from ./plugin.wasm -f <input>`.

> **Status: experimental.** Everything described below exists and is tested,
> except what is under [Planned](#planned) and [Not yet](#not-yet), which are
> labelled as plans or known gaps.

**Where to start**

| You want to | Read |
|---|---|
| Use a plugin someone published | [Installing a plugin](#installing-a-plugin), then [Running straight from the source file](#running-straight-from-the-source-file) |
| Write a plugin | [How it works](#how-it-works), [Writing a plugin](#writing-a-plugin), [Testing](#testing) |
| Publish your plugin for others | [Offering your plugin](#offering-your-plugin) |

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
uses only the imports above. **Rust has not been tried against kevin yet**,
so treat it as a starting point, not as instructions; JavaScript has:

- **Rust**: `rustup target add wasm32-wasip1`, then `cargo build --release
  --target wasm32-wasip1` on a normal `fn main()` that reads
  `std::io::stdin()` and prints.
- **JavaScript**: compile with [Javy](https://github.com/bytecodealliance/javy)
  (QuickJS inside the module). It works, and
  [`kevin-plugin-node`](https://github.com/mtxr/kevin-plugin-node) is a complete
  example. What to know:
  - Build with `javy build -J javy-stream-io=y -J text-encoding=y -o plugin.wasm plugin.js`
    and read stdin and write stdout with `Javy.IO.readSync(fd, bytes)` and
    `Javy.IO.writeSync(fd, bytes)`. `console.log` goes to stdout and
    `console.error` to stderr.
  - There is no Node API: no `fs`, no `process`, no `require`; `JSON.parse` works.
  - A JavaScript plugin cannot choose an exit code: an uncaught exception ends
    the module with a trap. Write the reason on stderr first; kevin shows it
    (`plugin '...' failed: <stderr> (Exception: unreachable)`).
  - The module uses WebAssembly SIMD, which kevin's runtime supports.

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

## Installing a plugin

```sh
kevin --plugin-install mtxr/kevin-plugin-node            # the latest release
kevin --plugin-install mtxr/kevin-plugin-node@v0.1.0     # a specific one
kevin --plugin-list                                      # name, hash and where it came from
```

`--plugin-install owner/repo[@tag]` downloads the release's `<name>.wasm` and
`<name>.wasm.sha256` (the repository must be named `kevin-plugin-<name>`),
checks the hash, and registers the plugin as `--plugin-add` would, remembering
the repository it came from. Then use it once with `kevin --from node -f
package.json`, or bind it to the file in a `.kevinrc` so its tasks are always
there:

```sh
echo 'package.json -> node' >> .kevinrc
kevin
```

How it is kept safe:

- Only those two files are fetched, from `github.com` over https (GitHub serves
  release files from its own CDN, so https redirects are followed), at most 5
  redirects, 60 seconds and 8 MiB. It needs `curl`.
- A release **without** a `.sha256` is refused, and so is a download that does
  not match it. Nothing is installed in either case.
- The checksum guards the transfer. What you trust is the repository that
  published the release, as with any download, so install plugins from authors
  you would trust with a script.
- A plugin is sandboxed (see [The sandbox](#the-sandbox)): it cannot touch your
  network, files or processes. But the commands it generates are what kevin
  runs, so read `kevin --from node -f package.json` once, the way you would read
  a `maskfile.md` you did not write. `kevin --explain <task>` shows what a task
  would run without running it.
- Plugins that use WebAssembly SIMD (every JavaScript plugin built with Javy)
  need kevin 0.3.0 or newer. An older one says `v128 value type requires simd
  feature`.
- A `.kevinrc` that names a plugin only works on machines where it is
  registered: a teammate who clones the repository runs `--plugin-install` too
  (a shared lockfile is [planned](#planned)).

### By hand

Without `--plugin-install` (no `curl`, a plugin that is not on GitHub, or you
want to check the provenance first), the same thing takes three steps:

```sh
curl -LO https://github.com/mtxr/kevin-plugin-node/releases/latest/download/node.wasm
curl -LO https://github.com/mtxr/kevin-plugin-node/releases/latest/download/node.wasm.sha256
shasum -a 256 -c node.wasm.sha256            # sha256sum -c on most Linux
gh attestation verify node.wasm --repo mtxr/kevin-plugin-node   # if the author signs builds
kevin --plugin-add node.wasm
```

## Registering a plugin

A plugin you have as a file (one you built, or downloaded by hand) is registered
with `--plugin-add`; `--plugin-install` ends up in the same registry. Registered
plugins are named instead of pointed at:

```sh
kevin --plugin-add ./lines.wasm          # copies it in and records its sha256
kevin --plugin-list                      # name and hash prefix of each plugin
kevin --from lines -f todo.txt           # a built-in name wins, then a registered one
kevin --plugin-remove lines
```

The name is the file name without `.wasm` (lowercase letters, digits, `-` and
`_`). Plugins live in `$KEVIN_PLUGIN_DIR`, else `$XDG_CONFIG_HOME/kevin/plugins`,
else `~/.config/kevin/plugins`, next to a `plugins.lock` with one
`<name> <sha256> [<source>]` per line (the source, `owner/repo[@tag]`, is only
there for plugins installed from GitHub). Every use re-checks the hash: if the file changed
since you added it, kevin refuses to run it and tells you how to re-add it
deliberately. `--plugin-add` never downloads anything, and a different file
under an existing name needs `--plugin-remove` first, for both commands.

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

## Offering your plugin

Publishing a plugin is publishing a GitHub release with a `.wasm` file in it.
Nothing needs to go through this repository.

### What a release contains

| Asset | Why |
|---|---|
| `<name>.wasm` | The plugin. The file name, without `.wasm`, is the name users register and put in `.kevinrc`: lowercase letters, digits, `-` and `_`. Keep it the same in every release, so `releases/latest/download/<name>.wasm` always works. **Required** by `--plugin-install`. |
| `<name>.wasm.sha256` | `shasum -a 256 <name>.wasm > <name>.wasm.sha256`. **Required**: `--plugin-install` refuses a release without it. |
| A build provenance attestation (recommended) | `actions/attest-build-provenance` on the file, so `gh attestation verify` can tie it to your repository and workflow. |

One `.wasm` runs on every operating system and CPU kevin supports, so there are
no per-platform files. It must be at most 8 MiB.

### Conventions

- Name the repository `kevin-plugin-<name>` (`--plugin-install` derives the
  asset name from it) and give it **both** GitHub topics,
  `kevin-plugin` and `kevin-runner` (`gh repo edit --add-topic kevin-plugin
  --add-topic kevin-runner`). Today those topics are the only way plugins are
  found: <https://github.com/topics/kevin-plugin>. A repository with only one
  of them is not listed as a kevin plugin.
- Version with tags (`v0.1.0`), ideally created by a release tool such as
  release-please from Conventional Commits, as `kevin-plugin-node` does. Say in the README which kevin version is the
  minimum (a plugin built with Javy needs the SIMD support that came after
  0.2.0).
- The README says: what the plugin converts, the install command
  (`kevin --plugin-install owner/repo`), and what it does with input it
  does not understand (notes on stderr, an exit code, a message on stderr
  before a trap).

### Checklist before a release

1. It builds to a module that exports `_start` and imports only the functions
   in [Writing a plugin](#writing-a-plugin).
2. `kevin --from ./<name>.wasm -f <input>` prints Markdown that `kevin -f out.md`
   lists and runs. Run the `.wasm`, not only the native build.
3. A bad input fails visibly: a non-zero exit code with the reason on stderr
   (a language that cannot choose an exit code writes the reason first, then
   fails; kevin shows it).
4. The same input gives the same output (the clock is frozen and randomness is
   fixed, so a plugin that depends on either will not behave).
5. Tests run the module in a real kevin, not only under your language's runtime.

### A release workflow to copy

[`kevin-plugin-node`](https://github.com/mtxr/kevin-plugin-node) is a complete
example, in JavaScript:

- `ci.yml` runs the unit tests, builds the module and runs it in a kevin built
  from source (`scripts/e2e.sh`: convert, register, run a task from the source
  file through `.kevinrc`, check that a failure explains itself).
- `release.yml` runs on a `v*` tag: it checks the tag against `package.json`,
  repeats the tests, writes the checksum, attests the build and creates the
  release with `gh release create`.

Replace the build step (`scripts/build.sh`) with your toolchain; the rest is
independent of the language.

## Planned

> **Not implemented.** These are the next steps, in the order they are likely
> to land.

1. A project lockfile: `package.json -> node@0.1.0` in `.kevinrc` plus a
   committed file with the repository and sha256, so `kevin --plugin-install`
   with no arguments gives every teammate the same plugin.
2. A manifest the release carries (a `kevin-plugin.json`: name, version, the
   files it understands, the minimum kevin version), so kevin can suggest the
   `.kevinrc` line after installing and refuse a plugin that needs a newer
   kevin.
3. A curated index (a file in this repository where adding a plugin is a pull
   request) and, if there is demand, `--plugin-search`.

Native code is never downloaded: only `.wasm`, which kevin validates and runs
in the sandbox above.

## Not yet

Known gaps, in rough order of when they are likely to be addressed:

- **Windows.** The runtime is built for macOS and Linux (x86-64 and arm64). On
  other targets `--from x.wasm` reports that the build has no runtime.
- **Reading other files.** A plugin only sees its stdin. Formats that include
  other files (`import` in a `justfile`) need a read-only window onto the
  project directory. Anything outside the project root will stay rejected.
- **The manifest and the project lockfile** described under
  [Planned](#planned).
- **Validating the output.** kevin does not yet parse a plugin's stdout before
  printing it; a plugin can emit text that is not valid kevin Markdown.
- **Per-run limits are not configurable** from the command line.
- **Many inputs.** One invocation converts one file; combining several (a
  monorepo's `package.json` files) is not designed yet.
