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
applies to Python commands only.

### Build / Compile Commands

| Config file present | Command to try |
|---|---|
| `package.json` with `"build"` script | `npm run build` (or `yarn build` / `pnpm build`) |
| `tsconfig.json` (no build script) | `npx tsc --noEmit` |
| `pom.xml` | `mvn compile -q` |
| `build.gradle` / `build.gradle.kts` | `./gradlew compileJava` (or `compileKotlin`) |
| `Cargo.toml` | `cargo build` |
| `go.mod` | `go build ./...` |
| `pyrightconfig.json` or `[tool.pyright]` | `pyright` (type-check is the Python build gate) |
| `pyproject.toml` / `setup.py` (mypy configured) | `mypy .` |
| `pyproject.toml` / `setup.py` (no type-checker) | `python -m py_compile` on changed files |
| `Makefile` with `build` target | `make build` |

If none match: attempt `npm run build`, `mvn compile`, or `./gradlew build` and let the
error output identify the correct tool.

### Lint Commands

| Config file present | Command to try |
|---|---|
| `.eslintrc*` / `eslint.config.*` | `npx eslint .` (or project's npm lint script) |
| `checkstyle*.xml` | `mvn checkstyle:check` or `./gradlew checkstyleMain` |
| `.golangci.yml` | `golangci-lint run` |
| `pyproject.toml` with `[tool.ruff]` **or** standalone `ruff.toml` | `ruff check .` |
| `.flake8` / `setup.cfg [flake8]` | `flake8 .` |
| `clippy` (Rust) | `cargo clippy -- -D warnings` |
| `Makefile` with `lint` target | `make lint` |
| `package.json` with `"lint"` script | `npm run lint` |
| `biome.json` / `biome.jsonc` (standalone JS/TS) | `biome check .` (extra lint command) |
| `.sqlfluff` | `sqlfluff lint --dialect <dialect>` (extra lint command) |

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

| Toolchain | Coverage command |
|---|---|
| Jest | `jest --coverage --coverageReporters=json-summary` |
| Maven + JaCoCo | `mvn verify` (JaCoCo report in `target/site/jacoco/`) |
| Gradle + JaCoCo | `./gradlew jacocoTestReport` |
| Pytest + coverage | `pytest --cov=src --cov-branch --cov-report=term-missing` |
| Go | `go test ./... -coverprofile=coverage.out -covermode=atomic` then `go tool cover -func=coverage.out` |
| Rust | `cargo tarpaulin --engine llvm --out Stdout` |

Always use **branch coverage** flags where available (`--cov-branch` in pytest,
`-covermode=atomic` in Go, branch coverage in JaCoCo config). Line coverage alone
does not satisfy the conditional coverage requirement.

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
- **Failure**: measured conditional coverage is below the declared threshold in `design.md`
- **Warning**: no threshold declared — any coverage figure is advisory only
- A branch that is genuinely unreachable (documented as such in the code) may be excluded
  from the denominator — do not manufacture tests to reach dead code
