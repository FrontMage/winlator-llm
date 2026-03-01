# AGENTS

## Scope
This file defines repository-level agent rules for `winlator-mod`.

## General Working Rules
- Keep changes minimal and focused on the requested task.
- Prefer reproducible scripts in `scripts/` over ad-hoc commands.
- Before large refactors, confirm scope and rollback path.
- Validate outputs with concrete checks (hash, file presence, runtime logs).

## No Beads
- Do not depend on Beads workflow or `.beads` state.
- Do not add Beads-specific instructions, commands, or automation in this repo.

## Context7 Constraints
- Use Context7 for library/framework documentation queries when implementation details are uncertain.
- Always call `context7 resolve-library-id` before `context7 query-docs` unless a valid Context7 library ID is already provided.
- Limit Context7 doc queries to **at most 3 calls per user question**.
- Prefer official/primary documentation sources and match the target version when possible.
- If the library/version is ambiguous, ask for clarification or state the chosen assumption explicitly.
- If 3 Context7 queries are insufficient, stop querying and report what was found plus what is missing.
- Never include secrets, tokens, or private credentials in Context7 queries.

