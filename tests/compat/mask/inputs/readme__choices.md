## color

**OPTIONS**
* color
    * flags: -c --color
    * type: string
    * choices: RED, BLUE, GREEN

```bash
COLOR=${color:-RED} # Fallback to RED if not supplied
echo "Color selected = '$COLOR'"
```
