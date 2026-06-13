<!--
TITLE FORMAT (required): type(scope): summary (#N)
  e.g.  feat(seed): add TODO scanner (#42)
This PR MUST target develop-auto. CI on develop-auto is byte-identical to develop.
Do NOT add Co-Authored-By trailers to any commit (hard project rule).
-->

Closes #<!-- N -->

## Summary
<!-- One paragraph: what changed and why. -->

## What changed
<!-- Concrete changes, grouped by area. -->
-

## Testing done
<!-- Commands run + result. Paste the green run or describe coverage. -->
- [ ] Full test suite green locally
- [ ] New/updated tests cover the change

## Risk
<!-- Blast radius, rollback story, anything reviewers should scrutinize. -->
- Risk level: low | medium | high
- Rollback:

## Review checklist
- [ ] Title is `type(scope): summary (#N)` and body has `Closes #N`
- [ ] Targets **develop-auto** (hard requirement; never main/develop/feature)
- [ ] Conventional commits; each commit builds independently (buildable-per-commit)
- [ ] gitleaks scan clean
- [ ] **No** `Co-Authored-By` lines in any commit
- [ ] All acceptance criteria from the issue are satisfied
- [ ] Docs updated if behavior/API changed
- [ ] Diff is small and scoped to a single issue
