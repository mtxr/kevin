## bootstrap

> Installs deps, builds, links, migrates the db and then starts the app

```sh
mask install
mask build
mask link
# $MASK also works. It's an alias variable for `mask --maskfile <path_to_maskfile>`
# which guarantees your scripts will still work even if they are called from
# another directory.
$MASK db migrate
$MASK start
```
