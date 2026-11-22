
## decimal

**OPTIONS**
* val
    * flags: --val
    * type: number

~~~bash
echo "Value: $val"
~~~

~~~powershell
param (
    [Double]$in = $env:val
)
Write-Output "Value: $in"
~~~
