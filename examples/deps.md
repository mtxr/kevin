# Dependency examples

Fixture for `Requires:`, `RunDeps:`, `Run:` and `Jobs:`.

## > setup

Run: once

```sh
echo setup
```

## > step (name)

Requires: setup

```sh
echo "step $name"
```

## > ordered
> Dependencies run one after the other (sync is the default)

Requires: step 1, step 2

```sh
echo ordered
```

## > parallel
> Dependencies run at the same time, at most two at once

Requires: step a, step b, step c
RunDeps: async
Jobs: 2

```sh
echo parallel
```

## > forward (who)
> Arguments are expanded in Requires entries

Requires: step $who

```sh
echo "forward $who"
```

## > boom

```sh
echo boom
exit 9
```

## > fails

Requires: boom, setup

```sh
echo "never printed"
```

## > loop-a

Requires: loop-b

```sh
true
```

## > loop-b

Requires: loop-a

```sh
true
```
