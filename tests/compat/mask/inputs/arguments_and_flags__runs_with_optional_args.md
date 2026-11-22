
## with_opt (required) [optional]

~~~bash
echo "$required" "$optional"
~~~

~~~powershell
param(
    $req = $env:required,
    $opt = $env:optional
)

Write-Output "$req $opt"
~~~
