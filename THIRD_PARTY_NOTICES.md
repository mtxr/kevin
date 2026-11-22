# Third-party notices

The compatibility suite in `tests/compat` contains files copied or derived
from the projects below. They are used only as test data. Each project is
distributed under the MIT License; the full license texts, with their
copyright notices, are kept next to the files that derive from them.

## mask

- Source: https://github.com/jacobdeichert/mask
- Fetched: commit `708b4fd548ab554f357724c4ff9fa00fa9ca6e5a` (after tag v0.11.3)
- License: MIT, Copyright (c) 2019 Jacob Deichert. See
  `tests/compat/mask/LICENSE-mask`.
- Derived material (`tests/compat/mask/`):
  - `inputs/arguments_and_flags__*.md`, `env_vars__*.md`, `integration__*.md`,
    `introspect__*.md`, `subcommands__*.md`, `supported_runtimes__*.md`: the
    maskfiles embedded in `mask/tests/*_test.rs`, copied verbatim.
  - `inputs/parser__test_maskfile.md`: `TEST_MASKFILE` from
    `mask-parser/src/parser.rs`.
  - `inputs/maskfile.md`: mask's own `maskfile.md`; `expected/maskfile.md` is
    its kevin migration.
  - `inputs/readme__*.md`: the example maskfiles from `README.md`.
  - `inputs/derived__*.md`: small files written for this suite that exercise
    mask behaviour described in `mask/src/executor.rs` and the README.
  - `cases/*.case`: expectations derived from the assertions of the tests
    above.

## xc

- Source: https://github.com/joerdav/xc
- Fetched: commit `3748e1c70a26fb1f71c62cd447dca19c100c0369` (after tag v0.9.0)
- License: MIT, Copyright (c) 2021 Joe Davidson. See
  `tests/compat/xc/LICENSE-xc`.
- Derived material (`tests/compat/xc/`):
  - `inputs/parsemd__example.md`, `parsemd__marked-heading-next-line.md`,
    `parsemd__notasks.md`, `parsemd__till-eof.md`: copied verbatim from
    `parser/parsemd/testdata/`.
  - `inputs/parsemd__commandless.md`, `parsemd__requires-only.md`,
    `parsemd__heading-case.md`, `parsemd__unterminated.md`,
    `parsemd__attributes.md`: inputs from `parser/parsemd/parsemd_test.go`.
  - `inputs/readme.md`: xc's `README.md`; `inputs/examples_long.md`:
    `examples/long/README.md`.
  - `inputs/docs__*.md`: examples from `doc/content/task-syntax/*.md`
    (`docs__run-deps.md` and `docs__interactive.md` add a Tasks heading and
    scripts so they run).
  - `inputs/semantics__*.md`: small files written for this suite that exercise
    xc runtime behaviour described in `run/run.go` and the docs.
  - `cases/*.case`: expectations derived from the tests and docs above.
