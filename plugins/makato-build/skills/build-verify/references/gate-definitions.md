# Gate Definitions

## Discovering Project Commands

Before running any gate, identify the project's toolchain from its config files.
Check in this order — stop at the first match for each command type.

### Python package-manager prefix

Before extracting any Python command, detect the lockfile-backed runner. A lockfile means
dependencies live in a project-local venv that bare invocations cannot see:

| Lockfile | Prefix every Python command with |
|---|---|
| `uv.lock` | `uv run` |
| `poetry.lock` | `poetry run` |
| `pdm.lock` | `pdm run` |
| `Pipfile.lock` | `pipenv run` |

E.g. `uv run pytest -m "not integration"`, `uv run ruff check .`, `uv run pyright`. The prefix
applies to Python commands only. Gate-scout's command strings are authoritative and must be
executed verbatim; never strip a prefix, prepend it a second time, or fall back to a bare
system-Python command when a lockfile is present.

### Build / Compile Commands

| Config file present | Command to try | Pre-commit hook ID |
|---|---|---|
| `package.json` with `"build"` script | `npm run build` (or `yarn build` / `pnpm build`) | — |
| `tsconfig.json` (no build script) | `npx tsc --noEmit` | — |
| `pom.xml` | `mvn compile -q` | — |
| `build.gradle` / `build.gradle.kts` | `./gradlew compileJava` (or `compileKotlin`) | — |
| `Cargo.toml` | `cargo build` | — |
| `go.mod` | `go build ./...` | — |
| `pyrightconfig.json` or `[tool.pyright]` | `pyright` (type-check is the Python build gate) | `pyright` (when hook present: `pre-commit run --hook-stage manual pyright --all-files`) |
| `pyproject.toml` / `setup.py` (mypy configured) | `mypy .` | — |
| `pyproject.toml` / `setup.py` (no type-checker) | `python -m py_compile` on changed files | — |
| `Makefile` with `build` target | `make build` | — |

If none match: attempt `npm run build`, `mvn compile`, or `./gradlew build` and let the
error output identify the correct tool.

### Lint Commands

| Config file present | Command to try | Pre-commit hook ID |
|---|---|---|
| `.eslintrc*` / `eslint.config.*` | `npx eslint .` (or project's npm lint script) | — |
| `checkstyle*.xml` | `mvn checkstyle:check` or `./gradlew checkstyleMain` | — |
| `.golangci.yml` | `golangci-lint run` | — |
| `pyproject.toml` with `[tool.ruff]` **or** standalone `ruff.toml` | `ruff check .` | `ruff` (when hook present: `pre-commit run --hook-stage manual ruff --all-files`) |
| `.flake8` / `setup.cfg [flake8]` | `flake8 .` | `flake8` (when hook present: `pre-commit run --hook-stage manual flake8 --all-files`) |
| `clippy` (Rust) | `cargo clippy -- -D warnings` | — |
| `Makefile` with `lint` target | `make lint` | — |
| `package.json` with `"lint"` script | `npm run lint` | — |
| `biome.json` / `biome.jsonc` (standalone JS/TS) | `biome check .` (extra lint command) | — |
| `.sqlfluff` | `sqlfluff lint --dialect <dialect>` (extra lint command) | — |

If no lint tool is configured: skip Gate 2 and log it as skipped, not failed. `biome` and
`sqlfluff` run **in addition to** the primary linter, not instead of it — a repo can lint
Python (ruff), JS/TS (biome), and SQL (sqlfluff) in the same LINT gate.

### Test Commands and Unit/Integration Split

Most projects separate unit from integration tests by convention. Identify the split:

**By directory:**
- `src/test/java/…/unit/` vs `…/integration/` — Maven/Gradle convention
- `tests/unit/` vs `tests/integration/` — Python/JS convention
- `*_test.go` in package vs `test/integration/` — Go convention

**By naming:**
- `*Test.java` (unit) vs `*IT.java` or `*IntegrationTest.java` (integration) — Maven failsafe
- `*.spec.ts` (unit) vs `*.e2e-spec.ts` / `*.it.ts` (integration) — Angular/NestJS convention
- `test_*.py` with `@pytest.mark.integration` marker — Pytest

**By runner flag:**
| Toolchain | Unit only | Integration only |
|---|---|---|
| Maven | `mvn test` (Surefire) | `mvn verify -Psurefire-skip` or `mvn failsafe:integration-test` |
| Gradle | `./gradlew test` | `./gradlew integrationTest` (if task exists) |
| Jest | `jest --testPathIgnorePatterns=integration` | `jest --testPathPattern=integration` |
| Pytest | `pytest -m "not integration"` | `pytest -m integration` |
| Go | `go test ./... -short` | `go test ./... -run Integration` |

If the project has no separation, run all tests as a single suite in Gate 3 and skip
Gate 4, logging it as not-applicable.

### Coverage Commands

| Toolchain | Legacy all-in-one fallback (runs tests) |
|---|---|
| Jest | `jest --coverage --coverageReporters=json-summary` |
| Maven + JaCoCo | `mvn verify` (JaCoCo report in `target/site/jacoco/`) |
| Gradle + JaCoCo | `./gradlew jacocoTestReport` |
| Pytest + coverage | `pytest --cov=src --cov-report=term-missing` |
| Go | `go test ./... -coverprofile=coverage.out -covermode=atomic` then `go tool cover -func=coverage.out` |
| Rust | `cargo tarpaulin --engine llvm --out Stdout` |

These are fallback commands and may execute tests. When gate-scout reports
`unit_coverage`, `integration_coverage`, and `coverage_report`, build-verify
collects fresh unit data, appends local integration data when applicable, and
runs only the report command at Gate 5. The report command MUST NOT re-run tests.
A coverage-raise round appends only its new test files with `coverage_append`.
Use the exact gate-scout commands when present instead of constructing a fallback.

## What Counts as a Gate Failure vs. a Warning

### BUILD
- **Failure**: any compilation error, type error, or unresolved symbol
- **Warning**: deprecation warnings, unused variable warnings — noted but not blocking

### LINT
- **Failure**: any rule violation the linter classifies as `error`
- **Warning**: rules classified as `warn` — noted but not blocking
- If the project has no lint configuration, the gate is skipped (not failed)

### UNIT / INTEGRATION
- **Failure**: any test that was passing before this session and is now failing (new
  failure vs. pre-session baseline)
- **Pre-existing failures**: tests already failing before this session started do not
  count as gate failures — they are noted in the log but do not block
- **Skipped tests**: tests marked skip/ignore are noted; a sudden increase in skipped
  tests (tests that were running before) is treated as a failure

### COVERAGE
- **Failure**: the report's total is below the declared threshold and Gate 5 enforces it (the data
  covers every locally owned lane; see the Gate 5 ownership matrix). It starts coverage-raise rounds:
  edge-case tests for the lowest-covered files (`shared/coverage-raise-guide.md`)
- **Warning**: no threshold declared, or the threshold is CI-owned / measured over the unit lane
  only — the local figure is advisory and selects no files
- A line no input can reach is reported as unreachable, never suppressed or covered by a
  manufactured test

## Pre-commit Hook Commands

When `.pre-commit-config.yaml` defines hooks for a tool, Gate 0 runs the sensor
scope selected from gate-scout: `branch` for CI's changed-file scope, otherwise
`all`. On the first pass Gates 1 and 2 derive hook results from Gate 0's final
run log rather than invoking those hooks again. After a coder repair, or when a
hook ID is missing from that log, rerun the hook at the same scope:

```bash
pre-commit run --hook-stage manual <hook-id> --all-files
```

For `branch`, replace `--all-files` with `--files <branch file set>` from the
same merge-base-plus-untracked scope used by Gate 0. This preserves CI sensor
scope while checking the repair; do not substitute a narrower staged subset.

**Requirements:**

- The hook must declare `stages: [manual]` (or include `manual` in its `stages` list).
- Missing `manual` stage produces a silent skip: `pre-commit run --hook-stage manual` exits 0
  with no stdout when no hooks match the stage. This is a worse false-negative than running
  the raw tool — Gates 1 and 2 include a pre-flight guard that detects this condition (empty
  stdout + exit 0) and records the gate as `skipped` rather than `passed`.

**Raw tool invocations are non-authoritative** when a pre-commit hook exists for the tool.
The hook environment (pinned rev, isolated venv, hook-specific args) differs from what `uv run
pyright` or bare `ruff check .` resolves, which is how false-negative passes arise.

**`gate-scout` fields** (v1.2.0+):
- `build_hook_cmd` — the pre-commit hook command for the type-check gate, or `null`
- `lint_hook_cmd` — the pre-commit hook command for the lint gate, or `null`
- `pyright_env` — `"hook"` when `build_hook_cmd` is set; `"raw"` otherwise
- `build_hook_missing` / `lint_hook_missing` — `true` when no matching hook was found

**Deprecation note**: `lint_ci_command` (gate-scout R1 field) is deprecated — use
`lint_hook_cmd` instead. `lint_ci_command` will be removed in the next major version.
