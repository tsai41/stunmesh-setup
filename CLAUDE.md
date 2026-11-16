# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

## Running one test

`make test` runs every `tests/*_test.sh` through `tests/run.sh`. Each test file is self-contained (fake `HOME`, copied scripts, stubbed `ssh`/`nc`/`fzf`/`open`), so run a single one directly:

```bash
bash tests/ssh_forward_test.sh
```

New `scripts/ssh.sh` subcommands follow the same shape: a `case "$ACTION"` branch, a `--flag` in the argument loop, a Makefile target passing the flag, and a test that stubs the external tools.
