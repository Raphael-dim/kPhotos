# Contributing to kPhotos

Thanks for considering a contribution. kPhotos is an independent open source iOS client for kDrive and welcomes pull requests, bug reports, and feedback.

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By participating you agree to abide by it.

## Reporting bugs and requesting features

- Search [open issues](../../issues) first.
- For bugs, use the **Bug report** template and include reproduction steps, the iOS version, and the failing behavior versus the expected one.
- For features, use the **Feature request** template and describe the user problem before any solution.
- **Do not open a public issue for a security vulnerability.** Read [SECURITY.md](SECURITY.md) instead.

## Development setup

You need macOS, Xcode 27, and [Mise](https://mise.jdx.dev/) to pin tool versions.

```bash
make setup      # install pinned build, quality and secret-scanning tools
make generate   # tuist install + tuist generate
make open       # opens kPhotos.xcworkspace
```

Run the test suite before pushing:

```bash
make test
make check-secrets # publishable files and Git history
make check-headers # canonical GPL headers and attribution
make format-check  # formatting, without modifying files
make lint-ci       # strict CI rules
```

Keep real account identifiers, logs, databases and photo manifests out of commits. Use synthetic fixtures and review screenshots.

Useful day-to-day commands live in [COMMANDS.md](COMMANDS.md). Project conventions and architectural rules live in [AGENTS.md](AGENTS.md) — read it before touching code.

## Branching and commits

- For public contributions, branch off `main`. Name your branch `feat/<short-slug>`, `fix/<short-slug>`, or `docs/<short-slug>`.
- Local agent work follows [WORKFLOW.md](WORKFLOW.md), including work on `main` and validation before committing.
- Use [Conventional Commits](https://www.conventionalcommits.org/) for commit messages. Common prefixes: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`.
- Keep commits small and focused. Don't bundle unrelated changes.
- Every source file must start with the GPL-3.0 header from [`file-header-template.txt`](file-header-template.txt). Use `Copyright (C) 2026 Raphaël Dimeck`. `make check-headers` validates the complete header, including scripts and Tuist manifests; shebangs and SwiftPM tools directives stay first.

## Pull requests

Before opening a PR:

1. Rebase on the latest `main`.
2. Run `make check-headers format-check lint-ci check-secrets`, `make test`, and review `make dead-code`.
3. Update or add tests for behavior you changed.
4. Update the relevant section of `AGENTS.md` if you introduce a new pattern, a new manager, or a new API surface.
5. For persistence, sync or transport changes, validate scope/revision safety, cancellation and migration/resumption as appropriate.
6. Fill in the PR template — keep the summary focused on the *why*, not the *what*.

PRs are reviewed for correctness, scope, and adherence to the conventions described in `AGENTS.md`. Drive-by refactors unrelated to the PR's stated goal will be asked to move to a separate PR.

## Style

- SwiftFormat and SwiftLint are the source of truth. Passing lint does not replace review of correctness, responsibilities or test coverage.
- 130 columns max per line, 4-space indentation, LF line endings.
- User-facing strings always go through `kPhotosResources` (`L10n.*`), never inline.
- No `try!` / `as!` / force-unwraps in production code.

Design choices follow the detailed SOLID, KISS, DRY, YAGNI, composition, Demeter and error-boundary rules in
[AGENTS.md](AGENTS.md#code-conventions-and-design-principles). Keep those rules when updating documentation;
remove obsolete claims and session narratives rather than the project's engineering guidance.

## Tests

- Unit tests mirror the source layout under `kPhotosTests/`.
- Realm objects never cross `async` boundaries — see the rule on snapshot value types in `AGENTS.md`.
- Avoid mocking out the layer you are testing. Prefer fake collaborators with the same protocol surface as the real one.

## License

By contributing you agree that your contributions are licensed under the [GNU General Public License v3.0](LICENSE), the same license as the project.
