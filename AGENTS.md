# Working on Vieweroo

Write code, comments, UI text, documentation, examples, test names, branch names, commits, pull requests, CI output authored by the project, and release notes in English.

## Scope and planning

Read the relevant sections of [VISION.md](VISION.md) and [ARCHITECTURE.md](ARCHITECTURE.md) before making changes. Use the vision to determine MVP scope and the architecture to find accepted decisions and acceptance checks. Resolve routine implementation choices independently. Ask when a choice would change agreed product behavior. Record an agreed change in the relevant document alongside the implementation. Moving an item from the post-MVP list into the MVP requires an explicit scope decision.

During early development, start work directly and track outstanding tasks as Markdown checkboxes in `.local/TODO.md`. The `.local/` directory is ignored by Git. GitHub Issues will take over task tracking when the maintainers switch the project to that workflow.

## Build and verification

With the initial app scaffold, document three commands in the README that work from a fresh checkout on a supported Mac: build the app, run the tests, and package the release ZIP. Use the same commands locally and in CI. For app changes, build the app, run the relevant checks, and exercise the changed behavior. For documentation-only changes, check the wording, links, and any commands affected by the edit.

Use a temporary SQLite database, isolated preferences, a Keychain substitute, generated synthetic media, and local PRDB responses in automated tests. Exercise destructive operations and migrations against disposable test data. Verify OSHash against PRDB's published test vectors. For behavior that requires hardware, such as AirPlay to a video receiver, report the actual hardware result or identify the check as outstanding.

## Privacy and public artifacts

Use the project's pseudonymous identity for commits and releases. Before the first public push from a checkout, verify the author, committer, email addresses, and any signing identity on the outgoing commits. Check screenshots, fixtures, logs, and release archives for personal identifiers, private paths, real library content, API keys, and PINs. Use synthetic examples that are safe to publish.

## Git and releases

Direct commits to `main` are welcome during early development. Keep commits focused, use English Conventional Commit subjects such as `feat:`, `fix:`, or `docs:`, and run the applicable checks before pushing. Preserve published history and never force-push `main`.

Branches and pull requests are also available during this phase. An agent may merge a pull request once required checks pass and review requirements are met. As the user base and GitHub interest grow, the maintainers will switch to a pull-request workflow and update this file.

An agent may prepare the Apple Silicon app ZIP, test it, and draft release notes. Creating a release tag or publishing a release requires an explicit maintainer request.
