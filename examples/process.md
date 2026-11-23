# Process examples

Fixture for the smoke test: stdin, signals, fail-fast, recursion and `--jobs`.

## > read-stdin
> A block reads the stdin of kevin itself (scripts are files, never stdin)

```bash
read -r line
echo "got=$line"
```

## > script-path
> $0 is the temporary script file; the declared arguments still arrive as $1..$n

```sh
case "$0" in */kevin-*) echo "file" ;; *) echo "not a file: $0" ;; esac
```

## > hang (dir)
> Starts a background child, records its pid and waits (for the signal test)

```sh
sleep 30 &
echo $! > "$dir/hang.pid"
wait
```

## > slow (dir)

```sh
sleep 2
echo finished > "$dir/slow-finished"
```

## > quick-fail

```sh
sleep 0.3
exit 9
```

## > late (dir)

```sh
echo started > "$dir/late-started"
```

## > failfast (dir)
> A failing async dependency stops its running siblings and starts no pending ones

Requires: slow $dir, quick-fail, late $dir
RunDeps: async
Jobs: 2

```sh
echo "never printed"
```

## > recurse
> Calls itself through $KEVIN: stops at the nesting limit instead of forking forever

```sh
$KEVIN recurse
```

## > probe (dir) (i)
> Records how many probes were running when this one finished its second

```sh
touch "$dir/active.$i"
sleep 1
ls "$dir" | grep -c '^active\.' >> "$dir/peaks"
rm "$dir/active.$i"
```

## > probes-12 (dir)
> Twelve one-second probes at once: more than any CPU count of a CI runner

Requires: probe $dir 1, probe $dir 2, probe $dir 3, probe $dir 4, probe $dir 5, probe $dir 6, probe $dir 7, probe $dir 8, probe $dir 9, probe $dir 10, probe $dir 11, probe $dir 12
RunDeps: async

```sh
true
```

## > probes-4 (dir)
> Four probes; with --jobs 2 at most two overlap

Requires: probe $dir 1, probe $dir 2, probe $dir 3, probe $dir 4
RunDeps: async

```sh
true
```
