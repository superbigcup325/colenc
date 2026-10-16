# Git hooks

## Pre-commit

Runs the non-mutating half of the pre-commit gate:

- `moon check --deny-warn`
- `moon fmt --check` (skipped automatically while the module has no packages —
  the toolchain errors out on an empty module)

Enable it once per clone:

```bash
git config core.hooksPath .githooks
```

The full gate — `moon info && moon fmt && moon check --deny-warn && moon test` —
is documented in `AGENTS.md` and mirrored in `.github/workflows/ci.yml`.
