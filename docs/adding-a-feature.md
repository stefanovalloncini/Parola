# Adding a feature to Parola

When you add a user-visible feature, follow these steps.

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

## 4. Snapshot state (if you added an `@Observable` property)

If a new stored property on `AppModel` belongs in the bridge's state snapshot, add it to `AppModel+StateSnapshot.swift` by hand.

## 5. Mock (if your feature has an engine seam)

If the feature plugs into `Transcriber`, `LanguageModel`, or `AudioSource`, the mock registries already handle it. Drop a fixture into `ParolaAppTests/Fixtures/Mocks/` when a test needs canned data.

## 6. Tests

- AppModel method — unit test in `AppModel<Area>Tests.swift`.
- Automation command — integration test in `AutomationCommand<Area>Tests.swift` that dispatches the command through a test-mode bridge and verifies the resulting state slice.
- Logging — capture with a `CapturingDiagnosticsSink` inside `ParolaLog.withSink(sink) { }`, not `ParolaLog.install`. The scope follows the task tree, so a record emitted from a `Task.detached` or a GCD hop goes to the installed sink instead: a test that asserts on one of those installs the sink itself and takes `.logFacade`.

## Coverage check

`scripts/check-feature-coverage.sh` compares UI elements, `.axLeaf` identifiers, and the command catalog. It also expects a `docs/agent-coverage.md` table mapping leaf ids to commands; that file doesn't exist yet, so strict mode currently fails on it. It runs strict by default and exits non-zero on any miss; pass `--soft` to log warnings without failing (the optional `.githooks/pre-commit` invocation uses that).
