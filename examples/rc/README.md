# kevin `.kevinrc` fixture

Tasks are spread over several files chosen by `.kevinrc`. The smoke test in
`build.md` runs from this directory.

## > from-readme
> A task declared in the default README.md

```sh
echo readme
```

## > via-kevin
> Calls a task declared in another file through $KEVIN

```sh
$KEVIN from-ops
```
