# Analýza: Nezávislost makato na Claude Code harness a na OS

**Datum:** 2026-07-24
**Stav:** Draft k diskusi
**Rozsah:** Celý autonomní pipeline (makato-orchestrate, makato-build, makato-change, makato-plan)
**Cíl:** Zjistit, co je nutné změnit, aby makato běželo (a) nezávisle na Claude Code harness — např. na open-source LLM jako Qwen — a (b) na čistém Linuxu bez macOS-ismů.

---

## 0. Shrnutí v bodech (executive summary)

- **makato NENÍ jeden program — jsou to dvě oddělené vrstvy.** Deterministická „skeletální" vrstva (bash/python, ~20 000 řádků) řídí *frontu, stav, zámky, worktree, watchdog*. Inteligentní vrstva (~30 000 řádků přirozeného jazyka v `SKILL.md` + `agents/*.md`) řídí *rozhodování a psaní kódu*. Toto rozdělení je klíčové — určuje, co je snadné přenést a co ne.

- **Skeletální vrstva je z 80–90 % přenositelná už dnes.** Stav (`workflow-state-*.json`), paměť (`.makato/memory/*.jsonl`), audit (`*.jsonl`) — vše je lokální filesystem + `jq` + stdlib Python. OS-specifické idiomy (`date -j`, `stat -f`, `readlink`) jsou už dnes obalené GNU-first/BSD-fallback větvením. **Na čistém Linuxu tato vrstva poběží prakticky beze změny.**

- **Skutečné zablokování je proces-boundary na `claude` binárku.** Loop volá `claude --dangerously-skip-permissions -p "<prompt>" --output-format stream-json --resume <KEY>`. Čtyři mechanismy tohoto rozhraní nemají v open-source světě přímý ekvivalent: **(1) tool-call smyčka**, **(2) `Skill`/`Task` nástroje** (dispatch skillů a subagentů), **(3) `--resume` perzistence konverzace**, **(4) `permissionMode: bypassPermissions`** bezobslužný režim.

- **„Inteligence" je v promptech, ne v kódu — to je zároveň výhoda i riziko.** Výhoda: prompty jsou model-agnostické texty, nejsou vázané na Anthropic API. Riziko: prompty *předpokládají* kvalitu Claude Sonnet/Opus v instruction-followingu, tool-callingu a dodržování 350řádkových procedur. Qwen (zvláště <72B) tyto předpoklady spolehlivě nesplní bez přepracování promptů a přísnějšího strojového vynucování.

- **GitHub je strukturálně nosný, ne jen integrace.** Fronta práce = GitHub Projects v2 board. Jednotka práce = Issue + labely. Doručení = PR. `loop.sh` volá `gh` 132× a `jq` 185×. Nahrazení GitHubu je vysoké úsilí — ale precedent už existuje (`makato-plan` je „provider-agnostic": `specs/` = source of truth, GitHub = volitelný sync target).

- **MCP servery a Langfuse NEJSOU v nosné cestě.** GitHub MCP je jen volitelný fallback (primární je `gh` CLI). Langfuse je opt-in observabilita čtoucí Claude Code transcript. penpot/figma/playwright slouží jen makato-ux. Autonomní smyčka je bez nich plně funkční.

- **Odhad úsilí:** Linuxová nezávislost = **nízké** úsilí (týdny). Harness-nezávislost (vlastní runtime + Qwen) = **vysoké** úsilí (měsíce), přičemž ~60 % práce je napsání náhradního runtime za `claude` binárku (tool-call smyčka + dispatch skillů/agentů + perzistence sezení) a ~30 % je zpřísnění promptů a strojová validace výstupů kvůli slabšímu modelu.

- **⚠️ Bezpečnostní nález (mimo zadání, ale kritický):** `.mcp.json` obsahuje **plaintext GitHub PAT** (`ghp_…`) a penpot userToken commitnuté v repozitáři. Tyto tokeny je nutné okamžitě odvolat a nahradit env-var referencí. Detail v §9.

---

## 1. Jak makato funguje dnes (architektura)

### 1.1 Dvouvrstvý model

```
┌─────────────────────────────────────────────────────────────┐
│  DETERMINISTICKÁ VRSTVA (bash + python, ~20k LOC)             │
│  loop.sh (5186 řádků) · workflow-state.sh · context-handoff  │
│  ─ poll boardu → claim (CAS lock) → dispatch → watchdog       │
│  ─ worktree lifecycle · run-mutex · HALT kill-switch          │
│  ─ stav v JSON · paměť v JSONL · audit v JSONL                │
└───────────────────────────┬─────────────────────────────────┘
                            │  spawnuje proces:
                            │  claude --dangerously-skip-permissions
                            │    -p "<prompt>" --output-format stream-json
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  INTELIGENTNÍ VRSTVA (přirozený jazyk, ~30k LOC)             │
│  74× SKILL.md · 25× agents/*.md                               │
│  ─ po-agent (outer loop) → dispatch build skillů              │
│  ─ coder (TDD) · diff-reviewer · plan-analyst · …             │
│  ─ rozhodování: který task, jak opravit, fix-vs-escalate      │
│  ─ návrat: R1 JSON envelope jako poslední ```json blok        │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Řídicí smyčka (`loop.sh`)

Jednovláknová, sériová z konstrukce. Pět vrstev vynucuje serialitu (`loop/SKILL.md:425`): run-mutex pidfile (`.claude/state/loop.pid`), board jako sdílený zámek, per-issue claim (CAS přes `gh project item-edit`), workflow-state guard, worktree existence. Cyklus:

1. **Poll** — `gh api graphql` čte Projects v2 board (fallback `gh project item-list`).
2. **Gate + claim** — čte labely (`gh issue view --json labels,title`), atomicky claimne issue Ready→In-progress.
3. **Dispatch** — spawnuje `claude -p "<prompt>"` na pozadí, prompt říká *„Use the Task tool to dispatch makato-orchestrate:po-agent…"*.
4. **Watchdog** — sleduje `mtime` logu (stream-json emituje řádek na každý tool-call); při stagnaci → `_stall_resume` přes `--resume`.
5. **Parse výsledku** — `_parse_dispatch_result` (`loop.sh:1722`) hledá terminální řádek `{"type":"result","is_error":…}`.

### 1.3 Stav a paměť (přenositelné)

- **Workflow-state:** `specs/<key>-<slug>/workflow-state-<N>.json`, spravováno výhradně přes `workflow-state.sh` (9 subcommandů), validováno JSON Schema draft-07. Stavový automat: `refine → implement → verify → pr → done`. Jediná GitHub-specifická pole: `repo` a `github_pr_number`.
- **Paměť:** `.makato/memory/{procedural,semantic}.jsonl`. Zápis přes `promote-lessons.sh` (jen `scope=="generalizable"`), čtení přes `workflow-state.sh recall-lessons`. Deduplikace přes `hash(text+tags)`.
- **Audit:** `build.jsonl`, `orchestrate.jsonl`, `change.jsonl` — vše lokální JSONL.

### 1.4 R1 návratový kontrakt

Každý agent emituje jako **poslední** ` ```json ` blok validní R1 envelope (`RETURN-CONTRACT.md`): `{schema:"r1", agent, status, summary, files_changed, tests_written, errors, tool_calls_used, data}`. Volající parsuje posledním-blok pravidlem — žádné parsování prózy. **Toto je čistě textová konvence, model-agnostická v principu**, ale závislá na spolehlivosti modelu ji emitovat bez chyb.

---

## 2. Mapa závislostí na Claude Code — po vrstvách

### 2.1 Proces-boundary (`claude` binárka) — NEJHLUBŠÍ COUPLING

| Místo | Přesný příkaz | Účel |
|---|---|---|
| `loop.sh:264` | `CLAUDE_BIN="${MAKATO_CLAUDE_BIN:-claude}"` | Resolboru binárky |
| `loop.sh:4169` | `… MAKATO_HEADLESS=1 "$CLAUDE_BIN" --dangerously-skip-permissions --output-format stream-json --verbose -p "$prompt" &` | Hlavní dispatch (po-agent / change:orchestrate) |
| `loop.sh:1893` | `… --output-format stream-json --verbose --resume "${key}" -p "$resume_prompt"` | Stall-resume (#531) |
| `loop.sh:2625` | `… --dangerously-skip-permissions -p "$prompt"` | Auto-seed dispatch (light-tier) |
| `loop.sh:3703` | `… -p "$refine_prompt"` | Pre-dispatch plan guard (build-refine) |
| `loop.sh:4573/4582` | `… -p "$decompose_prompt"` / `-p "$to_issues_prompt"` | Reshape pass (decompose + to-issues) |
| `context-handoff.sh:188/211` | `exec env … "$CLAUDE_BIN" --dangerously-skip-permissions --resume "$KEY" -p "…"` | HALT-007B resume po context-ceiling handoff |

**Použité flagy:** `--dangerously-skip-permissions` (vždy), `-p "<prompt>"` (7 míst), `--output-format stream-json --verbose` (3 místa), `--resume <KEY>` (2 místa). `--model` se nepoužívá — model je řízen frontmatterem agenta a env proměnnými.

**Claude Code env proměnné exportované do subprocessu:** `CLAUDE_CODE_RETRY_WATCHDOG=1`, `API_TIMEOUT_MS=1200000`, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` (nutné, aby top-level `-p` sezení nezabilo background subagenta po 600 s).

### 2.2 Tool namespace (`Skill`, `Task`, `Read/Edit/Write/Bash`, `AskUserQuestion`)

- **`Skill` tool** — načte `SKILL.md` a vloží obsah jako prompt sekci. Prompty explicitně říkají *„Use the Skill tool to invoke makato-change:orchestrate"* (`orchestrate/SKILL.md:294`, `context-handoff.sh:188`).
- **`Task` tool** — spawnuje subagenta z `.md` frontmatteru s vlastním `permissionMode`, `maxTurns`, `disallowedTools`, izolovaným kontextem (`po-agent.md:258,313`, `seed-issue/SKILL.md:443`).
- **Vestavěné nástroje** — `SKILL.md` frontmatter deklaruje `allowed-tools: Read Write Glob Bash(...)`; agent frontmatter `disallowedTools: Write, Edit, …`. Jména nástrojů jsou natvrdo Claude Code identifikátory.
- **`AskUserQuestion`** — interaktivní rozhodovací brány; celá `AUTONOMOUS-MODE.md` konvence existuje proto, aby je v headless režimu nahradila deterministickými defaulty (guard `MAKATO_HEADLESS=1`).

### 2.3 Perzistence sezení (`--resume <KEY>`)

Claude Code ukládá celou historii konverzace pod `~/.claude/projects/<hash>/sessions/`, klíčováno projektem odvozeným z `cwd`. `_stall_resume` proto `cd`ne do worktree issue *před* voláním `--resume` (`loop.sh:1892`). **Žádný soubor v `specs/` neobsahuje historii konverzace** — jen aplikační stav (fáze, halt_audit). Toto je nejtěžší mechanismus k náhradě, pokud se má zachovat mid-flow resume.

### 2.4 Hooks (Stop / SessionStart / PreToolUse)

- **Stop** (`settings.json:315`): dva `node -e` skripty (auto-continuation na `/build-simplify`, push-without-verify varování) + `langfuse_hook.py` (čte `sessionId`/`transcriptPath` z payloadu — Claude-Code-specifické).
- **SessionStart** (`settings.local.json`): `regenerate-agents.sh` (používá `CLAUDE_PROJECT_DIR`), worktree reaper.
- **PreToolUse**: `Bash(git commit*)` → `pre-commit` (blocking), `Bash(git push*)` → `pre-commit --hook-stage pre-push`.

**Bez hooků:** ztratí se auto-continuation a auto-tracing, ale nosná smyčka běží dál (loop.sh hooky nevolá).

### 2.5 Plugin systém a distribuce

`.claude-plugin/plugin.json` + `marketplace.json` + `settings.json → enabledPlugins/extraKnownMarketplaces` — celý formát je Claude-Code-proprietární. Instalace přes `claude plugin install`, cache v `~/.claude/plugins/cache/`. `settings.json` obsahuje ~20 Claude-Code-specifických polí (`defaultMode: bypassPermissions`, `effortLevel`, `alwaysThinkingEnabled`, `ANTHROPIC_*_MODEL`, `CLAUDE_CODE_*`).

### 2.6 OS coupling (macOS vs Linux)

**Dobrá zpráva — nulové neošetřené BSD idiomy.** Všechny nalezené vzory jsou obalené:

| Soubor:řádek | macOS idiom | Stav |
|---|---|---|
| `loop.sh:1485–1490` | `stat -f %m` | GNU-first (`stat -c '%Y'`) → BSD fallback — Linux OK |
| `session-status.sh:137`, `loop-supervisor.sh:157`, `rotate-skill-log.sh:40` | `date -j -f` | GNU-first (`date -d`) → BSD → python3 fallback — Linux OK |
| `loop.sh:4352`, `workflow-state.sh:322` | `readlink -f` chybí na macOS | Používá `python3 os.path.realpath` — cross-platform |
| `com.makato.loop-supervisor.plist` | launchd (macOS-only) | Cron alternativa už zdokumentovaná v šabloně |

Externí binárky v nosné cestě: `claude` (CRITICAL), `gh` (CRITICAL), `jq` (185×), `git` (27×), `python3` (12×, jen stdlib), `node` (Stop hooky). Všechny dostupné na Linuxu. `autossh` se v kódu makato *nepoužívá* (jen v poznámce o Langfuse tunelu).

### 2.7 GitHub jako source-of-truth

~15 tříd `gh` operací, nosné: `gh api graphql` (board poll), `gh project item-edit` (CAS claim lock), `gh issue view --json labels` (dispatch routing), `gh issue edit --add-label` (HALT signály), `gh pr checks/view/create` (build cyklus). Konfigurace boardu cachována v `.claude/config.json → github_project` (option IDs pro todo/ready/in_progress/done/blocked). `GH_HOST` znamená, že GHES funguje bez změny kódu.

---

## 3. Co se musí změnit — po komponentách

### 3.1 Náhrada `claude` binárky → „makato-runtime" (VYSOKÉ úsilí, ~60 % práce)

Je potřeba napsat CLI/wrapper kolem Qwen (přes vLLM/Ollama/llama.cpp s OpenAI-compatible API), který implementuje minimálně:

1. **`-p "<prompt>"` headless režim** — jednorázový prompt → tool-call smyčka → terminální výsledek.
2. **Tool-call smyčka** — model volá nástroje, runtime je vykoná, výsledky vloží zpět, opakuje do terminálu. Qwen podporuje function-calling přes OpenAI-compatible schéma; potřeba mapovat na makato tool namespace.
3. **`--output-format stream-json`** — jeden JSON řádek na každý tool-event + terminální `{"type":"result","is_error":<bool>}`. *Alternativa:* upravit `_parse_dispatch_result` na formát nového runtime (jednodušší než napodobovat Claude wire-format).
4. **`--dangerously-skip-permissions` ekvivalent** — bezobslužný režim bez interaktivních promptů (governed no-prompt execution).
5. **`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` ekvivalent** — neomezené čekání na background subagenta, NEBO přejít na inline dispatch (subagent běží synchronně, ne na pozadí) — tím tato závislost odpadne.

### 3.2 Dispatch skillů a agentů (VYSOKÉ úsilí)

- **`Skill` loader** — komponenta, která přijme `Skill(name, args)`, najde příslušný `SKILL.md`, vloží jeho obsah jako system-prompt sekci a spustí novou LLM otočku. Náhrada `@reference` include: pre-processing krok, který inlinuje odkazované soubory.
- **`Task` dispatcher** — spawnuje subagenta z `.md` frontmatteru s vlastním kontextovým oknem, respektuje `maxTurns`, `disallowedTools`, `permissionMode`. Vrací výstup subagenta jako string do rodiče. *Zjednodušení:* místo natvrdo „Use the Task/Skill tool" v promptech zavést jednotné dispatch primitivum runtime.

### 3.3 Perzistence sezení (`--resume`) (VYSOKÉ, nebo obejít)

Dvě cesty:
- **(a) Implementovat vlastní historii konverzace** klíčovanou projektem/worktree — plná parita s `--resume`.
- **(b) Zrušit `--resume` a startovat na čisto** — resume prompty už dnes nesou `ISSUE_NUMBER`, `KEY`, `REPO_ROOT`; workflow-state.json drží aplikační kontinuitu. Přijatelné, pokud runtime umí rekonstruovat dostatečný kontext z workflow-state + spec artefaktů. **Doporučená cesta** — výrazně levnější a workflow-state už je navržený jako resumovatelný.

### 3.4 Permissions & sandbox model (STŘEDNÍ úsilí)

`permissionMode: bypassPermissions`, allow/deny/ask listy v `settings.json` jsou Claude-Code-specifické. Nový runtime potřebuje vlastní model přístupu k nástrojům — minimálně allow/deny listu pro Bash a governed režim zápisu souborů (bezpečnostní hranice, ne jen UX).

### 3.5 Zpřísnění promptů pro slabší model (STŘEDNÍ–VYSOKÉ, ~30 % práce)

Viz §5 (Qwen rizika). Klíčové změny:
- **R1 envelope** — přidat strojovou validaci + auto-retry na malformed JSON (dnes fatální). Zvážit strukturovaný output / grammar-constrained decoding (GBNF/JSON schema) místo spoléhání na volný text.
- **Dlouhé procedury** (350ř `build-implement-tdd`) — rozsekat na menší kroky s explicitními checkpointy, nebo přesunout víc do deterministického kódu.
- **Fix-vs-escalate heuristiky** — kde model rozhoduje sémanticky, zvážit doplnění deterministických guardrailů.

### 3.6 OS nezávislost (NÍZKÉ úsilí)

- Přepsat `com.makato.loop-supervisor.plist.template` → systemd `.timer` unit (nebo použít už zdokumentovanou cron variantu). Supervisor logika je čistě přenositelný bash.
- Nahradit `~/.claude/` a `~/Library/LaunchAgents/` cesty konfigurovatelnými (většina už jde přes `MAKATO_*` env — `MAKATO_HALT_FILE`, `MAKATO_LOOP_STATE_DIR`).
- Nahradit `CLAUDE_PROJECT_DIR` v hoocích za `$PWD`/`REPO_ROOT`.
- BSD idiomy netřeba měnit — už jsou ošetřené.

### 3.7 GitHub abstrakce (VYSOKÉ, ale precedent existuje)

Nejde-li o GitHub, potřeba:
- **Queue abstrakce** — nahradit board poll + CAS claim lock (`gh project item-edit`) za lokální JSONL frontu + filesystem zámky, NEBO GitLab/jiný adaptér.
- **`gh`-kompatibilní wrapper** pro ~15 tříd operací.
- **Label taxonomie** → tagy/custom fieldy (routing labely `plan-tier:light`, `needs-human-review`, `needs-reshape`, `claude-halt` jsou natvrdo string konstanty na ~20 místech).
- **PR model** → branch-ready signály, pokud cíl nemá PR koncept.

Precedent: `docs/governance/2026-06-10-remove-jira-provider-agnostic-pipeline-design.md` — `makato-plan` už je provider-agnostic (`specs/` = source of truth, GitHub = volitelný sync). Stejný princip rozšířit na orchestraci.

### 3.8 Co se měnit NEMUSÍ (přenositelné dnes)

- Stav (`workflow-state-*.json`) — jen přejmenovat `github_pr_number`→`pr_number`, `repo`→`source_repo`.
- Paměť (`.makato/memory/*.jsonl`) — jen změnit resolver repo-slugu.
- Audit JSONL, python3 one-linery (stdlib), R1 kontrakt (textová konvence).
- MCP servery — nejsou v nosné cestě, lze vypnout.
- Langfuse — opt-in, mimo smyčku.

---

## 4. Cílová architektura (harness-agnostic)

```
┌──────────────────────────────────────────────────────────────┐
│  QUEUE ADAPTER (pluggable)                                     │
│  GitHub Projects v2  │  GitLab  │  lokální JSONL fronta        │
└───────────────────────────┬──────────────────────────────────┘
                            │  (nezměněná skeletální vrstva)
┌───────────────────────────▼──────────────────────────────────┐
│  loop.sh / workflow-state.sh / paměť / worktree / HALT         │
│  ─ volá MAKATO_CLAUDE_BIN (dnes) → makato-runtime (cíl)         │
└───────────────────────────┬──────────────────────────────────┘
                            │  jednotné dispatch rozhraní:
                            │  runtime -p "<prompt>" --stream-json --resume
┌───────────────────────────▼──────────────────────────────────┐
│  MAKATO-RUNTIME (nový, nahrazuje `claude`)                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐ │
│  │ LLM adapter  │  │ tool-call    │  │ Skill/Task dispatcher │ │
│  │ Qwen/GPT/…   │  │ smyčka       │  │ (SKILL.md/agent .md)  │ │
│  │ (OpenAI API) │  │ + no-prompt  │  │ + maxTurns/perms      │ │
│  └──────────────┘  └──────────────┘  └──────────────────────┘ │
│  session store (volitelný, pro --resume paritu)                │
└────────────────────────────────────────────────────────────────┘
```

Klíčová vlastnost: **`MAKATO_CLAUDE_BIN` už dnes existuje jako abstrakční bod.** Celá skeletální vrstva volá `$CLAUDE_BIN` — stačí, aby `makato-runtime` implementoval stejné CLI rozhraní (nebo se `_parse_dispatch_result` a dispatch prompty upravily na nové rozhraní). To je nejpřímější migrační páka.

---

## 5. Qwen-specifická rizika (kde slabší model selže)

| Riziko | Závažnost | Proč | Mitigace |
|---|---|---|---|
| **R1 envelope compliance** | VYSOKÁ | Celá smyčka parsuje poslední ```json blok. Trailing comma / useknutý JSON / próza po bloku = fatální „R1 contract violation" → HALT-STRUCTURAL. Malé Qwen (7–14B) produkují „skoro správný" JSON. | Grammar-constrained decoding (GBNF/JSON schema), strojová validace + auto-retry, tolerantnější parser |
| **Dodržení vícekrokových procedur** | VYSOKÁ | `build-implement-tdd` = 350ř přirozeného programu; model musí projít kroky 1–8 v pořadí, držet session-local stav. Qwen <72B ztrácí přehled o číslovaných krocích. | Rozsekat na menší dispatche, checkpointy, víc do deterministického kódu |
| **Spolehlivost tool-callingu** | VYSOKÁ | Volání jako `workflow-state.sh patch <KEY> <N> .sub_tasks[3].status '"complete"'` — Qwen má výrazně slabší přesnost u složitých shell/jq argumentů. Jeden špatný path korumpuje stav. | Wrapper validující argumenty, jednodušší tool API, schema-constrained tool calls |
| **Autonomní rozhodování** | VYSOKÁ | fix-vs-escalate, CI failure klasifikace, conflict resolution — sémantické heuristiky laděné na Sonnet. Qwen 14–32B eskaluje buď příliš (zbytečné HALTy) nebo příliš málo (přijme rozbitý test). | Deterministické guardraily, konzervativnější defaulty, human-in-the-loop na hranicích |
| **Délka kontextu** | STŘEDNÍ | po-agent `maxTurns:100`; kumulativní kontext běhu > 128K tokenů. Menší Qwen varianty 32–64K. context-handoff vyžaduje `--resume` (nepřenositelné). | Přenést context-handoff na workflow-state-based resume (§3.3b) |
| **Dlouhé instrukce** | STŘEDNÍ | `loop/SKILL.md` 1000+ ř, `po-agent.md` 1350+ ř. Menší modely front-loadují pozornost, míjejí pozdější pravidla. | Zkrátit/strukturovat prompty, klíčová pravidla nahoru |

**Doporučení modelu:** pro rozumnou spolehlivost cílit minimálně Qwen 72B (nebo Qwen3-32B s reasoning), ne menší varianty. Read-only scouti (dnes `haiku`) mohou běžet na menším modelu; psací/reasoning agenti (dnes `sonnet`) potřebují největší dostupný.

---

## 6. Migrační plán ve fázích

### Fáze 0 — Bezpečnost + Linux (NÍZKÉ, dny–týden)
- Odvolat a rotovat tokeny v `.mcp.json` (§9), přejít na env-var reference.
- systemd `.timer` unit místo launchd plistu (nebo cron).
- Zkonfigurovatelnit `~/.claude/` cesty (většina už přes `MAKATO_*`).
- Ověřit na čistém Linuxu — BSD idiomy jsou už ošetřené, hlavní práce je test `claude` binárky na Linuxu (Anthropic distribuuje Linux buildy).
- **Výsledek:** makato + Claude Code na čistém Linuxu.

### Fáze 1 — Runtime abstrakce (VYSOKÉ, měsíce)
- Napsat `makato-runtime`: LLM adapter (OpenAI-compatible → Qwen), tool-call smyčka, no-prompt režim.
- Implementovat `Skill` loader + `Task` dispatcher.
- Upravit `_parse_dispatch_result` + dispatch prompty na nové rozhraní.
- Přenést context-handoff na workflow-state-based resume (zrušit `--resume` závislost).
- **Výsledek:** makato běží na Qwen, jeden issue → PR.

### Fáze 2 — Zpřísnění promptů (STŘEDNÍ–VYSOKÉ, měsíce, paralelně s F1)
- Grammar-constrained R1 output + validace/retry.
- Rozsekat dlouhé procedury, přidat deterministické guardraily.
- Ladit na reálných issue, měřit HALT rate vs Claude baseline.
- **Výsledek:** srovnatelná spolehlivost s Claude na daném issue mixu.

### Fáze 3 — GitHub abstrakce (VYSOKÉ, volitelné)
- Queue adapter (lokální JSONL + filesystem locks, nebo GitLab).
- `gh`-kompatibilní wrapper, label→tag mapování.
- **Výsledek:** makato bez GitHubu (lokální fronta / jiný forge).

---

## 7. Souhrn úsilí podle komponent

| Komponenta | Přenositelnost dnes | Úsilí na dekaplink |
|---|---|---|
| Stav (workflow-state.json) | Vysoká | Nízké (2 pole) |
| Paměť (.makato/memory) | Vysoká | Minimální |
| Python (nosná cesta) | Vysoká (stdlib) | Triviální |
| Observabilita (JSONL) | Vysoká | Žádné |
| OS idiomy (date/stat/readlink) | Už ošetřeno | Žádné |
| launchd → systemd/cron | — | Nízké |
| MCP servery | Mimo nosnou cestu | Žádné (vypnout) |
| Langfuse | Opt-in, mimo smyčku | Žádné |
| Label taxonomie | Střední | Střední (~20 míst) |
| **`claude` binárka → runtime** | **Nízká** | **VYSOKÉ (~60 %)** |
| **Skill/Task dispatch** | **Nízká** | **VYSOKÉ** |
| **`--resume` perzistence** | **Nízká** | **Vysoké / nebo obejít** |
| **permissionMode/sandbox** | Nízká | Střední |
| **Prompty pro Qwen** | Střední | **STŘEDNÍ–VYSOKÉ (~30 %)** |
| GitHub jako fronta | Nízká | Vysoké |

---

## 8. Klíčové architektonické závěry

1. **Nejlepší páka je `MAKATO_CLAUDE_BIN`.** Skeletální vrstva je čistě oddělená a už dnes volá abstrahovanou binárku. Napsat `makato-runtime` se stejným (nebo mírně upraveným) CLI rozhraním je nejpřímější cesta — nemusíš sahat do loop.sh logiky.

2. **Obejdi `--resume`, nepřepisuj ho.** workflow-state.json je navržený jako resumovatelný; přenes context-handoff na state-based resume místo napodobování Claude session store. Ušetří to největší kus F1.

3. **„Inteligence v promptech" je dvousečná.** Prompty jsou model-agnostické texty (výhoda), ale předpokládají Claude-úroveň instruction-followingu (riziko). ~30 % migrace je jejich zpřísnění pro slabší model.

4. **GitHub je hlubší než runtime.** Nahradit harness je těžké, ale nahradit GitHub jako frontu/doručení je ještě strukturálnější — nech to na F3 a jen pokud je to skutečný požadavek.

5. **Linux je skoro zadarmo.** BSD idiomy jsou ošetřené, závislosti jsou na Linuxu dostupné, supervisor má cron variantu. Reálná práce F0 je test `claude` na Linuxu + bezpečnost.

---

## 9. ⚠️ Bezpečnostní nález (mimo zadání)

`.mcp.json` v kořeni repozitáře obsahuje **plaintext credentials commitnuté v gitu**:
- GitHub PAT: `ghp_…` (v `Authorization: Bearer` hlavičce github MCP serveru).
- penpot `userToken` (JWT v URL query).

**Doporučení (urgentní):**
1. **Okamžitě odvolat** oba tokeny (GitHub: Settings → Developer settings → PAT → Revoke; penpot: obdobně).
2. Nahradit env-var referencí (`${GITHUB_MCP_TOKEN}`) místo literálu.
3. Zvážit `git filter-repo` / BFG na odstranění z historie (token je v historii i po smazání ze souboru).
4. Přidat `.mcp.json` do `.gitignore` nebo držet jen šablonu `.mcp.json.example` bez tokenů.

Tento nález nesouvisí přímo se zadáním, ale je kritický — commitnuté tokeny umožňují neoprávněný přístup k repozitáři a designům.
