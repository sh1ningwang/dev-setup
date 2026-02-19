# Critical Rules

These rules are non-negotiable and must always be respected.

## Model Usage

- **Never downgrade model or use cheaper/smaller models.** Always use the latest Opus model for all work.
- **Never self-decide to downgrade from agent teams to subagents.** That is not your concern.

## Agent Teams vs Subagents

- For **simple tasks**: Automatically invoke the relevant skill directly without spawning agents.
- For **complex tasks**: Always use the **real agent team workflow**, never ad-hoc subagents (bare `Task` tool calls without a team). The workflow is:
  1. **Create the team** using `TeamCreate` with a descriptive `team_name`.
  2. **Create tasks** using `TaskCreate` for each piece of work.
  3. **Spawn teammates** using the `Task` tool with both `team_name` and `name` parameters so they join the team.
  4. **Assign tasks** using `TaskUpdate` with `owner` set to the teammate's name.
  5. **Coordinate** via `SendMessage` — never assume teammates can hear plain text output.
  6. **Tear down** when complete: send `shutdown_request` to all teammates via `SendMessage`, then call `TeamDelete`.
  - The team lead must analyze what types of agent roles are needed and how many agents per role.
  - Upon spawning, the team lead must inject the corresponding skill instructions (matching each agent's role) into each agent's prompt.
  - All spawned agents must strictly respect their assigned roles and injected skills. They must NOT perform actions outside their role.
  - **NEVER** fall back to spawning bare `Task` subagents for complex tasks. If `TeamCreate` is available, use it.

## Write Access Restrictions

Only the following skills have write access to the project directory:

| Skill | Write Access Scope |
|-------|-------------------|
| implement-backend | Backend code files |
| implement-frontend | Frontend code files |
| write-documentation | Documentation files and code comments |

All other skills are **read-only**:
- analyze-functional-requirements
- architect-technical-implementation
- architect-technical-testing
- debug
- review-code-quality
- review-security-risk
- review-performance
- review-secrets-leaks
- review-functional-requirements

Read-only agents must output to the console only. If they need to persist output to files, they must delegate to the **write-documentation** skill.

## Auto-Invocation

- Always try to automatically invoke the appropriate skill for tasks without requiring the user to explicitly name the skill.
- Match the user's intent to the closest skill and invoke it proactively.
