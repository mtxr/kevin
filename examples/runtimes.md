# Runtimes example

Each code block runs in its own process, in the order written. Arguments and
flags reach every block as environment variables, whatever the language.
Variables exported by one block are not visible to the next one.

## > greet (name) [greeting]

> Greet someone from three languages in one command

```js
console.log(`${process.env.greeting || "Hello"} from Node, ${process.env.name}!`);
```

```bash
echo "${greeting:-Hello} from bash, $name!"
```

```python
import os
print(f"{os.environ.get('greeting') or 'Hello'} from Python, {os.environ['name']}!")
```

## > blocks

> Show that blocks do not share variables

```bash
export SHARED=from-the-first-block
echo "first block sets SHARED=$SHARED"
```

```bash
echo "second block sees SHARED=[${SHARED:-}]"
```
