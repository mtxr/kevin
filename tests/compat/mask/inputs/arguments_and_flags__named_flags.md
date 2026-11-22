
## serve

> Serve this directory

<!-- You must define OPTIONS right before your list of flags -->
**OPTIONS**
* port
    * flags: -p --port
    * type: string
    * desc: Which port to serve on

```bash
# Set a fallback port
PORT=${port:-8080}

if [[ "$verbose" == "true" ]]; then
    echo "Starting an http server on PORT: $PORT"
else
    echo $PORT
fi
```

```powershell
param (
    [string]
    [Parameter(Mandatory = $false)]
    $port = $env:port
)

if ($env:verbose) {
    Write-Output "Starting an http server on PORT: $port"
} else {
    Write-Output $port
}
```
