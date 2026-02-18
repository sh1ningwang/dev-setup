# Critical Rules

These rules are non-negotiable and must always be respected.

## Model Usage

- **Never downgrade model or use cheaper/smaller models.** Always use the latest Opus model for all work.
- **Never self-decide to downgrade from agent teams to subagents.** That is not your concern.

## Agent Teams vs Subagents

- For **simple tasks**: Automatically invoke the relevant skill directly without spawning agents.
- For **complex tasks**: Always spawn an **agent team** using the Task tool, not ad-hoc subagents.
  - The team lead must analyze what types of agent roles are needed and how many agents per role.
  - Upon spawning, the team lead must inject the corresponding skill instructions (matching each agent's role) into each agent's prompt.
  - All spawned agents must strictly respect their assigned roles and injected skills. They must NOT perform actions outside their role.
  - Once the task is completed, the entire agent team is automatically torn down.

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
