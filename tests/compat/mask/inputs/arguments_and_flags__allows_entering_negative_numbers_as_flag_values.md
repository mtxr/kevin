
## add

**OPTIONS**
* a
    * flags: --a
    * type: string
* b
    * flags: --b
    * type: string

~~~bash
echo $(($a + $b))
~~~

~~~powershell
param (
    [int]$a = $env:a,
    [int]$b = $env:b
)
$sum = "$($a + $b)"

Write-Output $sum
~~~
