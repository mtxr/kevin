## purchase (price)

> Calculate the total price of something.

**OPTIONS**
* tax
    * flags: -t --tax
    * type: number
    * desc: What's the tax?

```sh
TAX=${tax:-1} # Fallback to 1 if not supplied
echo "Total: $(($price * $TAX))"
```
