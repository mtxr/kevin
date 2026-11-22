
## color

**OPTIONS**
* val
    * flags: --val
    * type: string
    * choices: RED, BLUE, GREEN

```bash
echo "Value: $val"
```

```powershell
param (
    $in = $env:val
)
Write-Output "Value: $in"
```
