
## ci

~~~bash
$MASK test
~~~

~~~powershell
$path = $env:MASK.replace("\\?\", "")
$pos = $path.IndexOf(" ");
$arglist = $path.Substring($pos + 1);

Start-Process mask.exe -ArgumentList "$arglist test" -wait -NoNewWindow -PassThru
~~~

## test

~~~bash
echo "tests passed"
~~~

~~~powershell
Write-Output "tests passed"
~~~
