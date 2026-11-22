## shell (name)

> An example shell script

Valid lang codes: sh, bash, zsh, fish... any shell that supports -c

```zsh
echo "Hello, $name!"
```

## node (name)

> An example node script

Valid lang codes: js, javascript

```js
const { name } = process.env;
console.log(`Hello, ${name}!`);
```

## python (name)

> An example python script

Valid lang codes: py, python

```python
import os
name = os.getenv("name", "WORLD")
print("Hello, " + name + "!")
```

## lua (name)

> An example lua script

```lua
name = os.getenv("name")
print("Hello, " .. name .. "!")
```

## ruby (name)

> An example ruby script

Valid lang codes: rb, ruby

```ruby
name = ENV["name"] || "WORLD"
puts "Hello, #{name}!"
```

## php (name)

> An example php script

```php
$name = getenv("name") ?: "WORLD";
echo "Hello, " . $name . "!\n";
```

## swift (name)

> An example swift script

```swift
import Foundation
let name = ProcessInfo.processInfo.environment["name"] ?? "WORLD"
print("Hello, \(name)!")
```
