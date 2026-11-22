# kevin tasks

## > test
> Run the unit tests

```sh
zig build test --summary all
```

## > hello (name) [greeting]
> Print a greeting

**OPTIONS**
* shout
    * flags: -s --shout
    * desc: Uppercase the output
* times
    * flags: -t --times
    * type: number
    * desc: Repetitions
* color
    * flags: -c --color
    * type: string
    * choices: red, green
    * desc: Label

```bash
msg="${greeting:-Hello}, $name"
[ -n "$shout" ] && msg=$(echo "$msg" | tr a-z A-Z)
for _ in $(seq "${times:-1}"); do echo "$msg${color:+ ($color)}"; done
```

### > nested
> Chained call through $KEVIN

```sh
$KEVIN hello from-nested -s
echo "dir=$KEVIN_DIR"
```

## Rodar Migrações

```bash task (env)
echo "migrating $env"
```

```python task (env)
import os; print("py sees", os.environ["env"])
```

## > fail

```sh
echo before
exit 7
```

```sh
echo never
```
