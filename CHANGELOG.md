# Changelog

## 0.1.0 (2026-11-23)


### Features

* **ast:** add command tree types and file merging ([3e5c29c](https://github.com/mtxr/kevin/commit/3e5c29c9fdd25bbeb461a926f02e22312c0b941d))
* **cli:** add --from and --output global flags ([d31ec88](https://github.com/mtxr/kevin/commit/d31ec8865f939ba5904d5f6a5e144c85ef732070))
* **cli:** add --introspect, make absent optional args empty ([b32ce5c](https://github.com/mtxr/kevin/commit/b32ce5c77130011c7ff5ce29539bb7c8c7b058a9))
* **cli:** add --version flag ([f797951](https://github.com/mtxr/kevin/commit/f7979511797bb511759985c665772e4bad3e5508))
* **cli:** add argument parsing, validation and help output ([e6f5f39](https://github.com/mtxr/kevin/commit/e6f5f394dbdb2cd9ad8477630ff668a3076a6f6a))
* **deps:** run command dependencies sync or async with a job limit ([228919b](https://github.com/mtxr/kevin/commit/228919bccf6b634016d70bc707c07dc2e914947e))
* **explain:** add --explain dry-run mode ([f9c13b9](https://github.com/mtxr/kevin/commit/f9c13b9304c7fed26a924452afd2c8a6db603cea))
* **migrate:** convert mask and xc files to kevin syntax ([939a48f](https://github.com/mtxr/kevin/commit/939a48fefe76cd2d4e0cf401bd8fcdcf5a0ae9bf))
* **migrate:** translate xc dependencies into native attributes ([cdbf869](https://github.com/mtxr/kevin/commit/cdbf869609bfb970c68b98f4d75af9abbe07c67c))
* **parser:** add line-based FSM Markdown parser ([5e78b31](https://github.com/mtxr/kevin/commit/5e78b315fc1274eaac27df25256bc9fd03a26cef))
* **parser:** parse Requires, RunDeps, Run and Jobs attributes ([cce07ee](https://github.com/mtxr/kevin/commit/cce07ee32c06cefbb467f428e2170c3280e24abf))
* **runner:** add OS-aware block selection and process execution ([bc136b6](https://github.com/mtxr/kevin/commit/bc136b657bf549a05b33487861841ebd588b2360))


### Bug Fixes

* handle indented fences, BOM, derived flags and missing files ([097773f](https://github.com/mtxr/kevin/commit/097773ff45bab6e2aac7e6dfa048ea3bf99ae67f))


### Refactoring

* **parser:** expose heading and fence helpers ([8dda080](https://github.com/mtxr/kevin/commit/8dda08002fa855354f81b8821b6668d0afa7290d))


### Documentation

* add contributing guide and commit message hook ([add32e8](https://github.com/mtxr/kevin/commit/add32e8eb7e69974ce1ebdc7b8df51eac0d6fb40))
* add llms.txt, agent guide, skill and a comparison ([f1ced0f](https://github.com/mtxr/kevin/commit/f1ced0f8a62876aa895fbfad9c5419f874e64cd3))
* add MIT license ([14edfb9](https://github.com/mtxr/kevin/commit/14edfb9dfb180831661a44ce5b078304a8da866f))
* document --explain and cover it in the smoke test ([8de887b](https://github.com/mtxr/kevin/commit/8de887b191aca1f1d339fbffcc1b303e31f85eb3))
* document dependencies and cover them in the smoke test ([ee69e14](https://github.com/mtxr/kevin/commit/ee69e145a16c34af6237bda565139d552b1cbd7f))
* document kevin and add build tasks written as kevin tasks ([8fe4dbc](https://github.com/mtxr/kevin/commit/8fe4dbc7a9b310ffd9e3b6a822a4ccd57ba90783))
* document migration and update the compatibility table ([5de58ba](https://github.com/mtxr/kevin/commit/5de58ba85b31f3970a300da834474cb105ad6277))
* explain how to install from the releases page ([be43df5](https://github.com/mtxr/kevin/commit/be43df5bc671e15f904566b1f463ddece9106b08))
