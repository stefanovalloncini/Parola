# Adding a feature to Parola

When you add a user-visible feature, follow these steps. CI enforces every one.

## 1. AppModel method

Add to `AppModel.swift` or an extension. Make it `internal` (or `public` if another module needs it). Mark `// @AutomationSkip` on the method if it's intentionally not exposed to the agent — for example an internal helper exposed only for testing.

## 2. UI element

Add the `Button` / `Toggle` / `MenuItem` / `TextField` / `Picker` / `Slider` / `Menu`. Apply `.axLeaf("Screen.Group.Component.Element")` next to it, using the four-part naming convention.

## 3. Automation command

Scaffold the command from a terminal:

```
scripts/gen-command.sh --name <method> --area <area> --args <list>
```

The script appends a fresh `AutomationCommand` value to `ParolaApp/ParolaApp/Bridge/Commands/<Area>Commands.swift` with a TODO inside the handler. Fill in the TODO so the handler calls the AppModel method.

Use `--dry-run` to print the block to stdout without touching files.

## 4. Coverage doc

Add a row to `docs/agent-coverage.md`:

```
| <axLeaf id> | <command name> | <notes> |
```

CI fails if a leaf has no row, or if a row references a command the catalog doesn't expose.

## 5. Snapshot state (if you added an `@Observable` property)

If you added a new stored property on `AppModel`, regenerate the snapshot schema:

```
scripts/gen-state-schema.sh
```

That refreshes `AppModel+StateSnapshot.swift`. The pre-commit hook catches drift.

## 6. Mock (if your feature has an engine seam)

If the feature plugs into `Transcriber`, `LanguageModel`, or `AudioSource`, the mock plumbing from v7-B already handles it. Drop a fixture into `ParolaAppTests/Fixtures/Mocks/` when a test needs canned data.

## 7. Tests

- AppModel method — unit test in `AppModel<Area>Tests.swift`.
- Automation command — integration test in `AutomationCommand<Area>Tests.swift` that dispatches the command through a test-mode bridge and verifies the resulting state slice.

## CI guards

- `scripts/check-feature-coverage.sh` — UI elements vs `.axLeaf` vs coverage doc vs catalog.
- `scripts/gen-state-schema.sh --check` — the generated snapshot file is up to date.

`scripts/audit-automation-surface.swift` is a planned guardrail (SwiftSyntax walker over `AppModel`'s public methods). Not wired yet. Once it lands it will fail CI when an AppModel method ships without a matching catalog command or a `// @AutomationSkip` marker.

## Coverage check modes

`scripts/check-feature-coverage.sh` runs strict by default and exits non-zero on any miss. Pass `--soft` to log warnings without failing — use that during the `.axLeaf` rollout and inside the optional `.githooks/pre-commit` invocation.
