# Project AGENTS for Hermes / Beads / OMP Codex bridge

## Roles

- Root session uses `openai-codex/gpt-6.1-sol` to plan, review and orchestrate.
- File edits go through the OMP `task` agent routed to `opencode-go/kimi-k2.7-code:medium`.
- Fast reads and scout work use `opencode-go/glm-5.3-flash` when spawned explicitly.

## Workflow

1. Read the Beads issue supplied in the prompt and treat it as the durable contract for the whole run.
2. Read `AGENTS.md` and only the files needed to understand the request.
3. Use `bd prime` to refresh workflow context if needed. Use `bd show`, `bd update` and comments to keep the issue current.
4. Produce a concise Russian plan: intended outcome, scope, non-goals, files involved, acceptance evidence, risks and owner decisions.
5. Wait for explicit owner approval before executing.
6. During execution, every file edit or multi-file change goes through `task` with an OpenCode Go executor. Routine implementation fallback is GLM only; Codex fallback is not used for ordinary coding.
7. After the executor returns, inspect the diff and evidence yourself. Send corrections back if needed; keep final acceptance and security review in the root Codex session.
8. Update the Beads issue with relevant findings. Preserve unrelated working-tree changes. Never close the issue.

## Hard boundaries

These are instruction-only policies. They do not create a sandbox.

- No commit, push, merge, branch deletion or force operation.
- No deletion of project files or directories.
- No destructive database operation.
- No production credential change.
- No external message or publication.
- No deployment unless the issue explicitly requests it and project rules permit it.
- Do not run arbitrary curl | bash installers or download untrusted binaries.
- Do not read auth files, `.env` files, logs or private configuration outside the task scope.

## Approval

The root Codex session may plan and review without approval. Execution begins only after a human owner approves the exact issue, plan and configuration. If the issue, plan or config changes, the previous approval becomes invalid and must be renewed.
