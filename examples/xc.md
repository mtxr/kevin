# Example xc file

Fixture for `kevin --from xc`.

## Tasks

### hello

Print a greeting.

```
echo hi
```

### greet

Greet someone.

Inputs: NAME
Env: PUNCT=.

```
echo "Hello, $NAME$PUNCT"
```

### both

Runs hello first.

Requires: hello

```
echo both
```

## Other section

Not a task.
