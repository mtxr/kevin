
## negative

**OPTIONS**
* val
    * flags: --val
    * type: number

~~~bash
echo "Value: $val"
~~~

~~~powershell
param (
    [int]$in = $env:val
)

Write-Output "Value: $in"
~~~
