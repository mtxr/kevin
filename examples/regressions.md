# Regression fixtures

Small files used by the smoke test for bugs that were fixed once.

## > heredoc
> A fence-like line indented inside a block must not end the block

```sh
cat <<'DOC'
    ```
    code sample
    ```
DOC
echo after
```

## > derived-flag

**OPTIONS**
* watch_mode
    * desc: Declared without a flags line, so it is --watch-mode

```sh
echo "watch_mode=${watch_mode:-unset}"
```

## > optional-arg [name]
> An absent optional argument is empty, never inherited from the environment

```sh
echo "name=[$name]"
```

## > positional (first) [second]

> Declared arguments also arrive as $1..$n in shell blocks.

```bash
echo "count=$# first=[$1] second=[$2]"
```

## > flagged
> Absent or false flags are unset, never inherited from the environment

**OPTIONS**
* dry_run
    * flags: --dry-run
* port
    * flags: -p --port
    * type: number

```sh
echo "dry_run=[${dry_run-unset}] port=[${port-unset}]"
```

## > examples
> Only the first blocks run; a later block after prose is an example

First, the real script.

```sh
echo real
```

For instance, you could call it like this:

```sh
echo never-runs
```

Opt back in with the `task` keyword:

```sh task
echo opted-in
```
