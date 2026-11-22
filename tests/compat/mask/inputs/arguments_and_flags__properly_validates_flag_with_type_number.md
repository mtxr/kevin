
## integer

**OPTIONS**
* val
    * flags: --val
    * type: number

~~~bash
echo "Value: $val"
~~~

~~~powershell
param (
    $in = $env:val
)
Write-Output "Value: $in"
~~~
