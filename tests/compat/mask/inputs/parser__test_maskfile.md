# Document Title

This is an example maskfile for the tests below.

## serve (port)

> Serve the app on the `port`

~~~bash
echo "Serving on port $port"
~~~

## node (name)

> An example node script

Valid lang codes: js, javascript

```js
const { name } = process.env;
console.log(`Hello, ${name}!`);
```

## parent
### parent subcommand
> This is a subcommand

~~~bash
echo hey
~~~

## no_script

This command has no source/script.

## multi (required) [optional]

> Example with optional args

~~~bash
if ! [ -z "$optional" ]; then
 echo "This is optional - $optional"
fi

echo "This is required - $required"
~~~

# This is an invalid H1, so it will be ignored

## invalid_cmd

Everything below an invalid H1 will also be ignored.

~~~bash
echo hey
~~~
