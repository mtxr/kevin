# Example maskfile

Fixture for `kevin --from mask`.

## greet (name)

> Say hello

**OPTIONS**
* shout
    * flags: -s --shout
    * desc: Uppercase the greeting

```bash
msg="Hello, $name"
[ -n "$shout" ] && msg=$(echo "$msg" | tr a-z A-Z)
echo "$msg"
```

## services

### services up

```sh
echo "services are up"
```

## both

> Chains two commands through $MASK

```sh
$MASK greet Mask
mask services up
```
