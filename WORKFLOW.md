# Local agent workflow

This policy governs local agent work in the existing checkout. External contributors use
[CONTRIBUTING.md](CONTRIBUTING.md) to submit a branch/PR.

## Principles

- Work on the existing `main` checkout. Do not create a working branch unless the user requests one.
- Preserve unrelated modifications, staged changes and untracked work.
- Each feature corresponds to one coherent commit, using Conventional Commits.
- The user explicitly validates the implemented feature before the agent commits it.
- Do not push or rewrite published history without explicit authorization.

## What counts as a feature

A feature is one reviewable outcome: a complete screen/component, an isolated API capability,
a clearly identified bug fix, or a coherent documentation update.
Do not bundle unrelated behavior or drive-by refactors into that outcome.
If a request spans independent features, explain the breakdown before implementing and validate them separately.
Do not split a cohesive implementation into artificial steps that cannot be reviewed on their own.

## Working cycle

1. Read `AGENTS.md`, inspect the working tree and identify the feature's scope and existing changes.
2. Implement the authorized feature completely, including relevant tests, localization and documentation.
3. Run appropriate verification and review the diff. Preserve failures and limitations in the report;
   do not weaken checks or erase user data to obtain a green result.
4. Present the concrete result and validation evidence for the user's explicit review.
5. After validation, make the single feature commit; include only that feature's changes.
6. Continue to the next feature after the preceding one has been validated and committed.

Implementation authorization does not automatically authorize committing or publishing.
Do useful authorized preparation before requesting review; do not repeatedly ask permission for routine reversible work.
If checks fail, distinguish a regression from existing debt and explain what remains unresolved.

## Keeping documentation useful

Retain design principles, business invariants, technical constraints, workflows and reusable diagnostic procedures.
Remove session narratives, device-specific observations, personal-library examples and obsolete implementation claims.
When a problem reveals a lasting rule, document its rationale and regression coverage instead of its chronology.
