## link

> Build and link the binary globally

```bash
cargo install --force --path .
```

```powershell
[Diagnostics.Process]::Start("cargo", "install --force --path .").WaitForExit()
```
