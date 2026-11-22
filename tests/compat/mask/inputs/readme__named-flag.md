## serve

> Serve this directory

<!-- You must define OPTIONS right before your list of flags -->
**OPTIONS**
* port
    * flags: -p --port
    * type: string
    * desc: Which port to serve on

```sh
PORT=${port:-8080} # Set a fallback port if not supplied

if [[ "$verbose" == "true" ]]; then
    echo "Starting an http server on PORT: $PORT"
fi
python -m SimpleHTTPServer $PORT
```
