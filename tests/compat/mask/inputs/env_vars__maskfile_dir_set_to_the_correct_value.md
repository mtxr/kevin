
## run

~~~bash
echo "maskfile_dir = $MASKFILE_DIR"
~~~

~~~powershell
param (
    $var = $env:maskfile_dir
)

Write-Output "maskfile_dir = /$var"
~~~
