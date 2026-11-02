# Zrychlení build-review při zachování kvality

Datum: 2026-11-02. Stav: implementační plán, nikoli provedené změny. Cílový repozitář:
`macatocz/makato-oss`, pluginy `makato-build` a `makato-orchestrate`. Sagibeast je zdroj incidentů a
validační korpus; jeho aplikační kód se tímto plánem nemění. Needitovat distribuované plugin cache
ani uživatelské skills. Implementovat v upstream source a vydat verzovaný release.

## 1. Podklady a sjednocená diagnóza

- #1280: ověřený audit v `/opt/sagibeast/specs/modul-sestaveni-financniho-naroku/build.jsonl`, řádky
  779–850. Běh 2026-10-27 07:50:43.390–10:08:01.912 UTC; 2 h 17 min 18,522 s. 82 počátečních / 88
  finálních souborů, čtyři průchody, tři opravná kola, sedm různých blockerů (2 CRITICAL, 5 MAJOR).
  Commit a simplify jsou mimo tento čas.
- #1280: první oprava UI-2 neřešila celý průběh kontroly oprávnění; následovaly problémy souběžných
  probes UI-3 a přepínání projektu UI-4. Poslední dvě opravná/review kola a závěr zabraly 67 min
  3,522 s. Tento interval není změřená dosažitelná úspora.
- #1280: paralelní slices a delta review již existovaly. Finální pass četl tři změněné soubory,
  zdědil 85 citací až po shodě SHA-256 a počtu řádků a kontroloval dopad na volající. Důkaz:
  `/var/tmp/t1280-review-evidence/20261027T093122660083Z/1280-review-final-pass4.json`.
- #1281: přebíráme uživatelův rozbor jako výchozí zjištění, bez opakování hlášených selhání: 104
  souborů, 25,8 tisíce řádků, 12 passů, osm oprav, 39 nálezů, přibližně 66 hodin. Plánování a opravy
  7,4 M tokenů proti 1,9 M tokenů skenerů.
- #1281: uvedené výpadky jsou 21 h po ztrátě kernelu, 8,5 h po prázdné odpovědi a 7,5 h po dosažení
  capu. Součet je **37 h**, ne 35 h, pokud se intervaly nepřekrývají. Před výkonovým srovnáním
  sjednotit intervaly a odečíst jejich sjednocení, nikoli součet překrývajících se čekání. Legitimní
  čekání na rozhodnutí po capu není automaticky technický výpadek.
- #1281: F-039 prošel pěti passy a čtyřmi opravami; auditní invariant zůstal po 28 místech neúplný.
  Chybělo pravidelné vyhodnocení konvergence. Na stejném stromě pass 6 nehlásil problém nalezený
  passem 7: čistý výsledek jednoho stochastického vzorku není důkaz úplnosti.
- Další doložený problém #1281: slučování podle blízkosti řádků ztrácelo odlišné invarianty.
  Kanonická paměť `/opt/sagibeast/.makato/memory/procedural.jsonl`, záznamy 108 a 114. Tuto chybu
  musí plán řešit dříve než optimalizaci počtu agentů.
- Inspirace:
  [How the Claude Code team does code review](https://claude.dev/blog/solving-code-review-at-anthropic/),
  2026-10-15: ověřovat před review, opravovat třídu chyby, nezávisle potvrzovat nálezy, řídit úsilí
  rizikem, omezit nekonvergující kola a měřit recall i noise. Výsledky Anthropic nejsou výkonový
  odhad pro Makato.

Společná příčina není nedostatek skenerů. Jde o kombinaci přerušené orchestrace, drahých opakovaných
oprav stejného mechanismu, ztrátového přenosu nálezů a neúplného pokrytí invariantů. Priorita:
spolehlivé pokračování a bezeztrátový stav, potom konvergence, nakonec dražší sampling.

## 2. Neměnné kvalitativní a bezpečnostní podmínky

1. CRITICAL i MAJOR nadále blokují úspěch. Cap, timeout, neúplné citace, prázdný návrat, chybějící
   R1 ani nesouhlas agentů nikdy neznamenají clean.
2. Zachovat merge-base vůči integrační větvi, tracked i untracked soubory, okolní kód, volající,
   všechny review kategorie a současné hard constraints.
3. Každý constituent nález, jeho invariant, všechna místa a historie zůstávají dohledatelné.
   Deduplikace nesmí vymazat odlišný problém jen proto, že se týká stejného řádku.
4. Coder neopravňuje vlastní změnu k průchodu. Opravu schvaluje nezávislý reviewer. `diff-reviewer`
   zůstává jediným autorem finálních `ac_verdicts[]`; koordinátor je pouze transportuje do
   `build.jsonl`.
5. Citace a ověření platí pro konkrétní vstupní fingerprint: base, bytes souborů včetně untracked,
   relevantní kontext/závislosti, AC/specifikace a verze review kontraktu. Stejný hash samotného
   souboru neopravňuje ignorovat změnu jeho volajícího nebo smlouvy.
6. Zachovat nezávislé real-PG reprodukce, runtime smoke a finální per-AC důkazy. Browser s řízenými
   odpověďmi není důkaz skutečné backend autorizace.
7. HALT, vyčerpaný limit oprav, rozpočet, auth a lidské approval gate se nepřekračují watchdogem.
   Resume smí pokračovat jen v dříve autorizované práci a v platném limitu.
8. Review neprovádí stage, commit, push ani automatické rozdělení uživatelské větve. Inkrementální
   checkpoint není finální schválení ani povolení neúplného produktu.

## 3. Implementační mapa a verze

Lokálně přečtený zdroj `/root/makato-oss-main` a instalovaný skill mají starší kontrakt
`build-review v1.8.0`. Uváděný novější `shared/review_loop.py` v nich není. To není tvrzení, že
chybí v upstreamu nebo v prostředí běhu #1281. První úkol proto připne skutečný moderní source
commit; nerozšiřovat starou implementaci paralelně k již existujícímu novému helperu.

Ověřené source-relative integrační body:

- `plugins/makato-build/skills/build-review/SKILL.md`: dispatch, repair loop, finalizace.
- `plugins/makato-build/skills/build-review/references/review-criteria.md`: severity a evidence.
- `plugins/makato-build/agents/diff-reviewer.md`: read-only review, citace, R1 a per-AC verdikty.
- `plugins/makato-build/agents/coder.md`: review-repair kontrakt.
- `plugins/makato-build/agents/RETURN-CONTRACT.md`, `AUTONOMOUS-MODE.md`: sdílené R1, opravy, cap a
  verzování kontraktů; aktualizovat spolu se všemi producenty a konzumenty.
- `plugins/makato-build/scripts/run-skill.py`: spouštění skillu v samostatném procesu.
- `plugins/makato-build/shared/skill_execution.py`: routing a execution metadata.
- `plugins/makato-orchestrate/scripts/loop-supervisor.sh`, `loop.sh`, `reconcile-before-resume.sh`:
  lifecycle a pokračování; rozšířit existující supervision.
- `plugins/makato-orchestrate/scripts/functions.sh`: vlastní dispatch, watchdog, klasifikace
  neúplného výsledku a bounded stall resume; lifecycle nepatří do role resolveru.
- `plugins/makato-orchestrate/agents/po-agent.md` a `shared/check-session-tail.sh`: single-writer
  orchestrace, vložení checkpointu a interpretace terminal outcome.
- `plugins/makato-orchestrate/scripts/task_schedule.py`: dependency-aware task checkpointy.
- `plugins/makato-orchestrate/shared/workflow-state.sh` a schéma pod
  `plugins/makato-orchestrate/skills/workflow-state/references/`: kontrakt writeru stavu.
- `plugins/makato-build/shared/build-log.sh`: auditní události; zachovat transport AC.

`shared/review_loop.py`, jeho CLI `gate next` a odpovídající testy musí být potvrzeny na připnutém
moderním commitu v úkolu T0; jejich existence vychází z rozboru #1281. Nové moduly přidávat pouze
tam, kde existující helper nelze rozšířit bez druhé konvence.

## 4. Navržený průchod

Manifest a riziko → paralelní read-only review → bezeztrátový ledger → nezávislé potvrzení blockerů
→ mandatory gate → lokální oprava nebo invariantový redesign → normalizace → cílené testy a
nezávislý runtime důkaz → delta re-review → mandatory gate. Před úspěchem: závěrečný full pass,
finální mechanický no-change gate a per-AC certifikace.

Všechny přechody jsou trvale checkpointované. Strojové `next_action` je odvozené z ledgeru na každém
přechodu, i po ručním `fix`, resume a neúplné odpovědi; ne z modelové paměti.

## 5. Úkoly a akceptace

### T0: Připnout baseline, eval korpus a kontrakty

Priorita P0. Závislosti: žádné.

- Zjistit source commit a skutečné verze runneru, review helperu, promptů a modelů pro cílovou
  změnu. Zaznamenat rozdíly proti lokálnímu v1.8.0; použít existující moderní helper, ne vytvořit
  konkurenta.
- Vytvořit expertně adjudikovaný korpus pre-fix snapshotů #1280 a #1281, včetně čistých snapshotů,
  opravami zavedených regresí a odděleného holdoutu. Počet 39 není automaticky 39 potvrzených bugů.
- Oddělit reprodukovatelné orchestration scénáře od nákladných LLM evalů; zachovat původní raw
  nálezy.
- Zavést měření: wall time, aktivní kritická cesta, čekání podle příčiny, tokens/model/role, počet
  repair dispatchů, unikátní invarianty, recurrence, false positives, missed blockers.

Akceptace: každý známý bug má snapshot, konkrétní pravdivostní oracle a původ; každý výkonový údaj
má jednotku, model/prompt verzi a rozlišení měření/odhad. Existující test a smoke příkazy jsou
objevené ze source konfigurace a zapsané před implementací.

### T1: Bezeztrátový ledger a jediný convergence gate

Priorita P0. Závislosti: T0.

- Rozšířit existující review helper a persisted state: `run_id`, `pass_id`, `repair_round`,
  `input_fingerprint`, `finding_id`, `invariant_id`, `constituent_ids`, sites, evidence, původ
  (`initial`, `repair_regression`, `newly_discovered`), disposition a recurrence.
- Zachovat raw lens envelopes. Blízké řádky mohou tvořit zobrazovací skupinu, nikoli důkaz
  totožnosti invariantů. Každý constituent musí mít vlastní doložené uzavření.
- Gate vyhodnotí všechny přechody a trvale vrátí jednu akci: review, confirm, repair-local,
  redesign, certify, complete nebo blocked s důvodem. Konkrétní CLI názvy sladit s T0.
- Druhý neúspěšný návrat téhož invariantu po opravě vynutí redesign před dalším editováním. Počet
  nových míst nesmí recurrence resetovat. Není to automatické navýšení round capu.
- Ruční `fix` prochází stejným gate; ručně provedená oprava se audituje a nezávisle přezkoumá.

Akceptace: dva odlišné invarianty na stejném řádku zůstanou dva; transitive merge je nesmaže. Replay
F-039 přepne do redesignu při stanovené recurrence, i když text/line/finding ID přibude. Chybějící
gate záznam, constituent nebo nevalidní R1 nedovolí complete.

### T2: Durable resume, crash recovery a dohled bez obcházení capu

Priorita P0. Závislosti: T1.

- Trvalý checkpoint před dispatch i po přijetí výsledku: next action, role-scoped kontext,
  fingerprint, ownership epoch, attempt ID, job/process identita a cesta výsledkového artefaktu.
  Velké důkazy ukládat jako artefakty s digestem, ne opakovat v každém promptu.
- Reuse existující checkpoint store moderního helperu. Nemá-li jej, použít worktree-local
  `<git-dir>/makato-review/<key>/state.json` podle existujícího checkpoint vzoru build-fix-ci.
  Adresář 0700, soubory 0600; aktualizace pod OS lockem s epoch kontrolou, fsync a atomic rename.
  Přidání polí do workflow-state není nutné: po-agent zůstává jeho jediným writerem, review
  koordinátor vlastní pouze review checkpoint. Snapshot souboru bez locku není fencing.
- Preferovat novou execution session hydratovanou z ověřeného checkpointu. Historické instrukce jiné
  role se neobnovují jako autorita. Pokud moderní runner podporuje session resume, vázat jej na
  přesný run/roli/autorizaci; neobejít staré pravidlo „never resume another conversation“.
- Runtime dlouhého dítěte nesmí záviset na životě Eval kernelu či 120s čekací buňky. V živé relaci
  použít task/wait; pro obnovu využít existující runner/supervisor a durable receipts. Procesově
  lokální task handle není po restartu automaticky použitelný.
- Rozšířit existující supervision o heartbeat, reconcile a lease/epoch fencing jednoho koordinátora.
  Před opakováním zjistit stav dítěte i doručeného výsledku; dvě instance nesmí současně opravovat
  strom.
- Timeout čekání není cancel. Při skutečném cancel signalizovat pouze vlastněnou procesní skupinu
  ověřenou pomocí PID, start tokenu a run identity; ověřit ukončení potomků. Samotné zabití
  rodičovského PID nestačí a recyklovaný PID se nesmí zasáhnout.
- Ztracenou read-only práci lze obnovit. U nejistého stavu coderu nejdříve adoptovat/reconcile
  skutečné změny a důkazy; neopakovat mutující dispatch naslepo. Nezaručovat exactly-once běh LLM,
  ale idempotentní přijetí výsledků a jediného aktivního writeru.
- Prázdný návrat není success ani čekání na `continue`: validovat, uložit protocol error, provést
  bounded recovery. Použít existující infrastrukturní restart budget, pokud jej moderní source má;
  výchozí tři pokusy pouze když chybí. Nezavádět násobené vnořené restart budgety. Tento limit
  nemění čítač oprav ani autorizaci.
- Při capu/HALT uložit blocked a konkrétní další požadované rozhodnutí. Restart nesmí vynulovat cap.

Akceptace: zabití čekacího kernelu při běžícím dítěti nezpůsobí ztrátu ledgeru ani druhého codera.
Po přerušení návratu se už hotový výsledek přijme jednou. Dva koordinátory zastaví fencing. Obnova
pokračuje do pěti minut od technického výpadku, je-li dostupný runtime a platí autorizace. HALT,
cap, změněný fingerprint nebo nejasné cizí změny automatické pokračování zastaví s důvodem.

### T3: Opravovat invariant, plánovat jen tam, kde je to potřeba

Priorita P1. Závislosti: T1.

- Lokální oprava s jasným dopadem jde přímo coderovi: failing behavioral test/reprodukce, oprava,
  targeted GREEN a nezávislé delta review. Nevytvářet další plánovací cyklus.
- Architekturální/cross-boundary změna nebo recurrence z T1 dostane krátký plán a nezávislé
  posouzení před editováním. Klasifikace vychází z dopadu, nikoli počtu řádků.
- Pro invariant „každé X“ reviewer vytvoří matici vstupů, return/raise a async/cancellation cest,
  volaných helperů, transakčních hranic, požadovaného efektu a existujícího důkazu. U UI doplní
  čekání, souběh, pořadí odpovědí, project/API owner, navigaci a zachování draftu.
- AST/CFG inventář je pomůcka, ne důkaz úplnosti při dynamickém dispatchi. Nezmapované cesty
  zůstanou explicitním gapem. Coder přidá behaviorální důkazy pro invariant, ne pouze další nalezené
  místo.
- Vnější wrapper je možná oprava, ne předepsané univerzální řešení F-039. Musí být na skutečné
  hranici operace, nevynechat pre-router refusal, neztratit audit rollbackem, nezdvojit jej,
  nezachytit chybu se změnou původního výsledku a nepropsat neautorizovaná data. Jeden
  parametrizovaný test lze použít, ale není to strop počtu testů.

Akceptace: scénáře F-039 pro časná odmítnutí, selhání helperu, rollback, cancel a audit failure mají
explicitně určenou smlouvu a testovatelný výsledek. Matice #1280 pokrývá pending refusal, souběžné
probes, pozdní odpovědi, A→B→A, owner replacement a návrat bez claimu. Oprava se neuzavře jen na
základě počtu nalezených sites nebo coder success. Každý potvrzený CRITICAL dostane trvalý
behaviorální regresní test pro plausibilní selhání; nevytvářet source-text ani tautologické testy.
MAJOR musí mít odpovídající reprodukci a ověření.

### T4: Potvrzení nálezů, risk routing a severity

Priorita P1. Závislosti: T0, T1.

- Každý nový CRITICAL/MAJOR dostane nezávislé potvrzení před opravou; nezávislý agent může potvrdit
  celý související batch. Reprodukovaný runtime důkaz se sdílí, neopakuje bez důvodu.
- Verifier kontroluje dosažitelnost, dopad, zavedení změnou, smlouvu a důkaz. Potvrzené vady
  opravit, false positive uzavřít s ověřitelným důvodem. Nesouhlas či nedostupná reprodukce není
  automatické zamítnutí a neznamená clean.
- U nejrizikovějších lensů (error-handling, state/concurrency) zkusit v Deep profilu dva nezávislé
  vzorky v pass 1 a prvním re-review. Nejprve evidence-based pilot; nerozmnožovat všechny agenty ve
  všech passech a nepoužívat většinové hlasování k potlačení pravdivé vady.
- Dlouhý error-handling slice dělit podle samostatných hranic operací/invariantů; sjednotit coverage
  mapu, cross-slice vztahy a resource limit souběhu.
- Severity rozhodovat podle dopadu a dosažitelnosti. Chybějící audit bezpečně odmítnutého uploadu
  může být MAJOR; povinný bezpečnostní/compliance invariant může vyžadovat CRITICAL. Automatické
  zlevnění auditních vad není součástí plánu; obě úrovně nadále blokují.
- Nits a mechanické diagnostiky řešit existujícími senzory, nikoli opakovaným LLM repair loopem.
  Povinné runtime/security checks zůstávají. Zahrnout lint nově přidaných testů, ne jen produkce.

Akceptace: verifier odmítne doložený false positive i při souhlasu více skenerů; pravdivý minority
finding se neztratí. Known-clean eval nezvýší harmful-change false positives. Lokální oprava nemá
planner dispatch; citlivý architektonický nález jej má. Sampling se zapne jen při prokázaném přínosu
recall vzhledem k celkovému času oprav.

### T5: Inkrementální kontrola a kratší kritická cesta

Priorita P1. Závislosti: T1, T2, T3.

- Zachovat již fungující fingerprint-based dědění citací z #1280; delta scope rozšířit o změněné
  závislosti, callers, kontrakty, testy a všechny dotčené/předchozí invarianty. Při nejasném dopadu
  se scope rozšíří, nikoli automaticky zúží.
- Citační/R1 kontrakt předat od prvního dispatch, ne následným broadcastem.
- Ověřený nález lze předat dříve, než skončí všechny slices, jen při izolovaném read-only snapshotu
  reviewerů a disjunktním writer ownership. Bez této izolace nejdříve dokončit batch.
- Nezávislý smoke a statický re-review mohou běžet souběžně nad totožným zmrazeným stromem. Jejich
  výsledky přijmout až oba doběhnou; změna bytes/kontraktu zneplatní dotčené výsledky.
- Normalizaci udělat před freeze a testy. Identický finální testový důkaz lze předat build-verify
  pouze při shodě source, prostředí, nástroje a command scope; nezávislé review tím nezaniká.
- Finální full certifikace přezkoumá celý aktuální branch diff a všechny AC v čerstvém kontextu, ne
  pouze zděděné citace. Cílem je jeden závěrečný full pass; nález nebo pozdější změna vyvolá opravu
  a potřebnou recertifikaci. Počet full passů není limit přebíjející správnost.

Akceptace: změna calleru invaliduje relevantní nezměněný soubor; untracked soubor nelze vynechat.
Mutation během souběžného smoke/review zabrání clean. Finální clean je svázán s kompletním
manifestem, uzavřenými constituents, všemi citacemi, AC a mechanickým no-change výsledkem.

### T6: Průběžné review checkpointy při implementaci

Priorita P2. Závislosti: T2, T5.

- Po zhruba třech dokončených dependency-coherent úkolech naplánovat delta checkpoint; dříve při
  změně auth, peněz, persistence nebo veřejného kontraktu. Jde o počáteční politiku, kterou eval
  může zpřesnit, ne o magický počet tasků.
- Nezastavovat uprostřed nekompatibilního schema/writer/reader cutoveru. Incomplete budoucí task se
  nepředstírá jako dokončený; checkpoint hodnotí dokončený kontrakt a integrační rizika. Finální
  review stále pokrývá všechny původní AC.
- Zachovat po-agent single-task ownership, scheduler dependency pořadí a bounded repair policy.
  Checkpointy bez nového relevantního diffu přeskočit s důvodem; nepřidávat prázdná review kola.
- Nevyžadovat automatické commity ani změnu struktury uživatelovy větve.

Akceptace: scénář 15 tasků vloží checkpointy na platných hranicích a nepřekročí dependency;
nevytvoří průchod nehotových AC, neporuší atomic cutover a na konci provede full certifikaci.

### T7: Párová evaluace, rollout a dokumentace

Priorita P0 pro evaluaci, P2 pro zapnutí optimalizací. Závislosti: T0–T6 pro plný rollout.

- Deterministické testy chrání přechody, lossless merge, fencing, invalidaci a cap. Smoke skutečného
  runneru v disposable worktree spustí dítě, přeruší koordinátora, obnoví jej a prokáže stav i
  absenci druhého writeru. Fake dispatch není důkaz celého runtime.
- LLM varianty porovnat párově nad stejnými snapshoty, modelem a oracly; zaznamenat konfiguraci i
  variabilitu. Nejprve alespoň tři opakování na case pro odhalení nondeterminismu; nejde o
  statistický důkaz non-inferiority. Pro rollout rozšířit holdout i počet běhů.
- Kvalitativní release gate: všechny potvrzené CRITICAL z korpusu zachyceny, žádný známý MAJOR tiše
  neztracen, žádné zvýšení harmful false positives na clean holdoutu, nulové false-clean z
  orchestration failure a úplný constituent/AC transport. Vyhodnocovat i nález objevený až
  final-full, ne jen počet prvních komentářů.
- Výkonový gate: technické dead-time pod pěti minutami na obnovitelný incident, nižší medián
  aktivního end-to-end času i celkových tokenů; nesmí pouze klesnout skenování a vzrůst plánování,
  opravy nebo re-review. p95 sledovat až na dostatečně velkém pilotu, ne prezentovat ze tří běhů
  jako spolehlivou metriku.
- Sledovat rounds-to-pass, recurrence po opravě, nové regrese z oprav a post-merge
  reverts/incidents. Vzniklé incidenty doplňovat do eval korpusu podle článku.
- Vydat source release se sjednoceným kontraktem koordinátoru, reviewerů, coderu a helperů; doplnit
  changelog, dokumentaci resume/gate/risk policy a migration notes. Aktualizace promptů bez runtime
  gate nesplňuje T1/T2.

Akceptace: shadow běh nemění kód ani rozhodnutí produkčního review. Po splnění eval gate následuje
omezený pilot, pak výchozí zapnutí; při zhoršení kvality nebo nestabilitě okamžitý návrat na
poslední ověřenou source release. Downgrade nesmí ztratit neuzavřené nálezy; neslučitelný checkpoint
se zastaví s explicitní migrací, ne restartem od nuly.

## 6. Dodávkové balíčky a pořadí

1. PR-A: T0, T1, T2 a jejich část T7. Nejprve baseline, lossless ledger, povinný gate a recovery.
   Samostatný přínos bez změny intenzity skenování. Nečekat s opravou runtime na sampling.
2. PR-B: T3, základní verifier/severity část T4, T5 a eval část T7. Cílem je méně lokálních záplat a
   kratší kritická cesta, ne méně zachycených vad.
3. PR-C: T6 a experimentální sampling/splitting část T4, zbývající rollout T7. Škálování agentů
   zapnout až po měření; jinak může zvětšit dominantní náklad oprav.

T0 přiřadí každému úkolu přesné source/test soubory moderního checkoutu a existující gate příkazy.
Každý PR má vlastní runtime smoke a kvalitativní gate; žádný není nefunkční scaffold. PR-A/B
zůstávají užitečné i pokud evaluace zamítne sampling v PR-C.

### Existující testovací integrační body

V lokálním starším source byly nalezeny následující cíle; v T0 je porovnat s moderní verzí:

- `plugins/makato-build/shared/test_skill_execution.py`: skutečný launcher a metadata.
- `plugins/makato-orchestrate/scripts/tests/test_task_schedule.py`: dependency a checkpoint hranice.
- `plugins/makato-orchestrate/scripts/tests/loop-smoke-tests.sh`: incomplete výsledek a stall
  resume.
- `plugins/makato-orchestrate/scripts/tests/loop-supervisor-smoke-tests.sh`: restart a HALT.
- `plugins/makato-orchestrate/scripts/tests/reconcile-before-resume-smoke-tests.sh`: review
  reconcile.
- `plugins/makato-orchestrate/shared/check-session-tail-smoke-tests.sh`: terminal evidence.

Testy ledgeru, gate a fingerprint invalidace patří k existujícímu modernímu `review_loop` helperu;
pokud nemá test module, přidat sousední behaviorální testy podle konvencí cílové verze. Nové smoke
scénáře zapojit do existující CI validace. Runtime smoke použije skutečný launcher a trvalý
checkpoint s řízeným disposable dítětem; živé LLM kvalifikační běhy jsou samostatný eval, ne
deterministická unit suite a ne mocková náhražka recall měření.

## 7. Matice povinných akceptačních scénářů

| Scénář                                     | Požadovaný výsledek                                              | Úkol  |
| ------------------------------------------ | ---------------------------------------------------------------- | ----- |
| Eval čekání zanikne, dítě žije             | Checkpoint přežije, žádný duplicitní coder, resume pokračuje     | T2    |
| Návrat dítěte se ztratí                    | Reconcile přijme durable výsledek jednou                         | T2    |
| Dva koordinátory / stará epoch             | Pouze jeden writer, starý výsledek se neuplatní                  | T2    |
| Prázdný či malformed R1                    | Bounded recovery nebo explicitní blocked, nikdy clean            | T1/T2 |
| HALT / repair cap / rozpočet               | Uložený důvod a další požadované rozhodnutí, žádné auto-navýšení | T1/T2 |
| Dva různé invarianty poblíž řádku          | Oba constituents zůstávají otevřené do samostatného ověření      | T1    |
| F-039 se vrací pod novým site/ID           | Recurrence nezmizí, mandatory gate vynutí redesign               | T1/T3 |
| Audit refusal před routerem i po rollbacku | Matice zachová původní odmítnutí i povinný audit bez duplicity   | T3    |
| #1280 pending/concurrent/navigace          | Soukromá data se skryjí, povolený draft se zachová, UI neuvízne  | T3    |
| Dva skenery souhlasí s false positive      | Důkazový verifier jej odmítne; neplatí hlasování místo evidence  | T4    |
| Jeden skener odhalí reálnou vadu           | Minority finding zůstane vyřešitelný a blokující                 | T4    |
| Změna calleru či AC, stejný soubor         | Relevantní evidence se invaliduje                                | T5    |
| Edit během smoke / po clean                | Výsledek neplatí pro nový strom                                  | T5    |
| Checkpoint mezi 15 tasky                   | Pouze platné hranice, zachovaný scope a závěrečné všechny AC     | T6    |
| Final-full najde novou vadu                | Oprava a recertifikace, nikoli úspěch kvůli limitu full passů    | T5/T7 |

## 8. Očekávaný dopad a meze tvrzení

- #1281: 15–20 h místo přibližně 66 h je hypotéza z dodaného rozboru, ne acceptance závazek. Při
  nepřekrývajících se 37 h čekání zbývá přibližně 29 h; cíl 15–20 h by tedy vyžadoval ještě 9–14 h
  úspory aktivní práce. Automatický restart sám takový výsledek nedokazuje.
- Cap wait lze odstranit jen tam, kde má systém předem autorizovanou další akci. Bezpečné zastavení
  kvůli nekonvergenci se nemění na nekonečný autonomní repair loop.
- #1280: 67 minut následných kol není garantovaná úspora. Úspěch je méně regresí z oprav při stejném
  či lepším zachycení původních blockerů; ne uměle nižší počet passů.
- Dva vzorky stejného modelu nezaručují nezávislé chyby ani determinismus. Měřit mezní přínos nad
  holdoutem a náklad celého toku, ne počet spuštěných agentů.
- Automaticky nestanovujeme jeden wrapper, jeden test ani MAJOR pro každý audit gap. Taková pravidla
  by nahrazovala technický důkaz pouhou konvencí.

## 9. Stav implementace a ověření

Implementace proběhla v upstream checkoutu `/root/makato-oss-main` na větvi
`feat/build-review-performance`, nad baseline `b467bac6139f2137e22d4ef17ae3062e9d1bfa36`
(release 0.174.0). Publikace implementace je oddělená od LLM kvalifikace a pilotu;
commit ani push nejsou jejich důkazem.

- **T0 částečně:** baseline a kontrakty jsou připnuté. Skutečný Git export baseline prošel
  validací: 173 inventarizovaných položek včetně 11 interních symlinků; kandidát má 16 kanonických
  kontraktů. Úplný historický eval korpus není dostupný.
- **T1–T6 implementováno:** bezeztrátový ledger, jediný persisted convergence gate, durable native
  resume a worktree-wide writer fencing, potvrzení aktuálních raw blockerů nezávislým agentem,
  opravy invariantů a risk routing, delta review a bezpečné task checkpointy. Final-full, všechny
  AC, citace a mechanický důkaz nezměněného stromu zůstávají povinné.
- **T7 eval infrastruktura implementovaná:** párový full-workflow runner, oddělení assessor/oracle,
  zdrojově vázaná kvalifikace, fail-closed rollout, dokumentace, changelogy a CI. Napojení skutečných
  case-specific LLM adaptérů, kvalifikace a pilot nejsou dokončené; stav po pokračování je v §10.

### Provedené ověření

- Sedm cílených pytest modulů: **247 testů a 12 subtestů prošlo**.
- Native launcher/recovery smoke na systémovém Pythonu 3.10: **18 testů prošlo**, včetně smrti
  workeru s přeživším writerem a přechodu z nefinálního checkpointu na final-full.
- Reconcile, supervisor a session-tail smoke: **10 + 10 + 11 testů prošlo**.
- Ruff check/format nad 14 dotčenými Python soubory, root/plugin struktura, frontmatter
  čtyř měněných skillů, Finding-schema a runtime-path kompatibilita prošly.
- ShellCheck a actionlint prošly. Dokumentační kontrakty prošly markdownlint; dvě historie
  changelogů mají sedm již existujících duplicitních nadpisů mimo tuto změnu.
- Controlled subprocess smoke provedl 18 workflow běhů bez LLM nad dočasnými fixture daty:
  scanner skutečně měnil pracovní kopii, assessor měl oddělený původní snapshot. Ověřeno také
  odmítnutí změněné baseline/adaptéru a „clean retry“ bez opravy. To není měření LLM recall.

### Co zůstává blokované

Chybí úplné původní raw nálezy #1281, expertně adjudikované pre-fix snapshoty, přesné historické
modely/prompty a nezávislý clean/blocker holdout. Bez nich nelze poctivě provést párovou LLM
evaluaci ani potvrdit doménové AC nad původními incidenty #1280/#1281. Experimentální sampling
proto zůstává **vypnutý**; změřené zrychlení ani zachování LLM recall se netvrdí. Odhad 15–20 h
zůstává hypotézou z §8.

## 10. Pokračování po publikaci implementace

Implementace je commitnutá a pushnutá jako
`a57915360dd16894cb7089bd702af297ab86da8f` na `origin/feat/build-review-performance`.
Podrobný index aktuálních důkazů a jejich hashů je v `qualification-readiness.json`.
Soukromé zdroje Sagibeast, vstupy modelů a raw traces zůstávají mimo upstream checkout.

### Obnovená data

- #1280 pass 1: ověřeno **82/82 původních file hashů**. 81 odpovídá Git stromu
  `d6cac18bd65ad1c4dfa4ea795f457648a02db745`; poslední soubor byl přesně rekonstruován přehráním
  archivovaného simplification patche. Není to tvrzení o ověření pozdějších passů.
- Dohledáno sedm distinct blocker ID v raw #1280 reportech. P1 má zachovaný PostgreSQL red/green
  důkaz; historický incident nebyl znovu spouštěn.
- #1281: lokálně není obnoven žádný z 39 raw nálezů se severity a citacemi. F-039 je zachovaný jen
  ve shrnutích. Chybí původní Mac archiv `makato-review-loop` a pre-fix pracovní stromy; jejich
  nahrazení finálním opraveným commitem by nebylo pravdivým replay.

### Skutečný LLM shadow smoke

Přes stávající OMP autentizaci proběhl source-only read-only pár baseline/kandidát nad P1 a
samostatný assessor, model `openai-codex/gpt-6.1-sol`, effort `xhigh`. Oracle nebyl ve vstupech
scannerů. Oba scannery dokončily jeden vzorek bez tool calls; assessor označil baseline za
**exact**, kandidáta za **partial**: kandidát popsal relevantní blokování a příčinu, ale nedovodil
obrácenou závislost, deadlockový cyklus a abort transakce. Baseline naopak nadhodnotila známou MAJOR
severity na CRITICAL. Další nálezy nejsou bez caller/runtime kontextu adjudikované.

První pokusy obou variant skončily po 180 s jako `aborted / Deadline exceeded`. Jsou zachované
v evidenci; jejich nulové provider usage je neznámá spotřeba, nikoli bezplatný běh. Po zvýšení
diagnostického deadlinu na 10 minut byly dokončené nové pokusy se stejnými vstupy a effortem.
Nejde o „clean retry“ po dokončeném nálezu. Časy a tokeny jsou v indexu, ale jeden souběžný
source-only pár bez oprav/final-full/holdoutu není odhadem výkonu ani LLM recall celého workflow.

### Proč zatím není kvalifikace ani pilot

Chybí kompletní #1281 korpus, pozdější #1280 snapshot/oracle mapování a nezávislý clean i
CRITICAL/MAJOR blocker holdout. Dále je nutné napojit skutečné baseline/candidate/assessor adaptéry
celého review–repair–final-full toku s měřením všech modelů, nested-agent tokenů a neúspěšných
pokusů. Stávající controlled adaptéry v testech nejsou takovou integrací.

Nativní launcher v tomto prostředí nerozpoznal `@review`; explicitní současný model fungoval bez
změny autentizace či globálního nastavení. Model routing pro celý tok musí být před evaluací
explicitně vyřešen, nikoli tiše nahrazen jiným modelem.

Žádná source-only odpověď zde není kvalifikací. Skutečný `lenses --profile deep` odmítl readiness
artefakt jako `unsupported or unbound qualification report`: sampling zůstal vypnutý a všech pět
lensů mělo jeden vzorek. Omezený pilot se proto **nespustil**; změřené zrychlení ani zachování
kvality se netvrdí.
