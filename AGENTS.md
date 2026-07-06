# Project Rules

## Scope

This repository contains unattended recovery/install scripts for fresh Debian VPS instances.

## User profile and communication

- Communicate in Chinese by default.
- Assume the operator has no programming or command-line background.
- Installation and recovery commands must be complete and directly copyable.

## Engineering rules

- Target only fresh Debian 12 and 13 servers unless a task explicitly changes that scope.
- Keep installers fail-fast and idempotence-safe: never overwrite an existing proxy deployment silently.
- Pin downloaded binary versions and verify SHA-256 checksums.
- Never print or persist secrets with permissions broader than `0600`.
- Do not hide failures or weaken validation to make an installation appear successful.
- Keep changes surgical; do not modify unrelated scripts or formatting.
- Any generated configuration must be validated before services start.
- After changes, run Bash syntax checks, ShellCheck when available, and available configuration/tests.
- Documentation must match the actual node count, prerequisites, and recovery procedure.

## High-risk operations

Obtain explicit approval before deleting files/history, changing secrets or CI/CD, database migration, destructive Git operations, installing global/system dependencies on the user's machine, pushing Git changes, or publishing/deploying. Approval may be granted in the active request.

## Git

- Do not stage unrelated untracked or modified files.
- Use focused commits with an explanatory message.
