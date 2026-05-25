# WORKFLOW.md

## Principles

- All work happens on the `main` branch.
- Each new feature corresponds to a single commit.
- Commits must follow Conventional Commits (see AGENTS.md).
- The workflow only proceeds once the user explicitly validates the feature.

## What counts as a feature

A feature is a coherent change delivered in one step, for example:
- adding a complete screen or component,
- adding an isolated API capability,
- fixing a clearly identified bug.

If a request is too broad, split it into several features, each with its own commit.

## Working cycle

1. Implement one complete feature.
2. Do a quick verification (build / test / lint if relevant).
3. Wait for the user's explicit validation of the feature.
4. Make a single commit that covers only that feature.
5. Move on to the next feature.

## Rules for agents

- Do not group several features into a single commit.
- If a request contains multiple features, propose a breakdown before implementing.
- Do not create a working branch — everything stays on `main`.
- Do not commit until the feature has been explicitly validated.
