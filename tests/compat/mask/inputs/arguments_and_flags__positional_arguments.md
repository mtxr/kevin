
## test (file) (test_case)

> Run tests

~~~bash
echo "Testing $test_case in $file"
~~~

~~~powershell
param (
    $test_case = $env:test_case,
    $file = $env:file
)

Write-Output "Testing $test_case in $file"
~~~
