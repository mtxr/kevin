# Structured dependencies

Fixtures for the smoke test: a value expanded into a `Requires:` entry is data,
never a command, `--help`, `-v`, `--` or a flag.

## > build (target)
> Print the target it received

**OPTIONS**
* dry_run
    * flags: -n --dry-run

```sh
echo "build target=[$target] dry_run=[${dry_run-unset}]"
```

### > docs
> A subcommand named like a possible target value

```sh
echo "docs subcommand ran"
```

## > deploy (target)
> Passes its argument to build as data

Requires: build $target

```sh
echo "deploy done"
```

## > serve
> Literal flags in a Requires line stay flags

Requires: build prod --dry-run

```sh
echo "serve done"
```
