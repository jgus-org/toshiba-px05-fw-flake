# AGENTS.md

This file provides shared guidance to agents working in this repository. `CLAUDE.md` is a compatibility symlink to this file.

This flake follows the fleet flake standard: [jgus-org/flake-lib `AGENTS.md`](https://github.com/jgus-org/flake-lib/blob/v1/AGENTS.md). It owns what belongs in `flake.nix`, `pin.nix`, and `flake.lock`, how to author a producer, the update workflows, the build gate, and every rule a flake in this fleet follows. Read it before changing this flake, and read the library at the revision this flake's `flake.lock` names for anything a caller passes to it.

Anything specific to this repository belongs here. Anything the standard states belongs to the standard, which this file links rather than restating.
