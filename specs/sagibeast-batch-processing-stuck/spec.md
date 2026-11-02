# Dávka dokladů visí ve „zpracovává se“ — analýza a plán opravy

## Řetěz po `start-batch` (ověřeno ve zdrojích)

1. `commands._start_batch` → `repository.start_batch`: sloty s dokladem → `batch_slot.state='processing'`,
   `batch.started_at` se nastaví, v téže transakci vznikne audit `batch_started` + šifrovaný outbox intent.
2. `dispatcher.run_dispatcher` (smyčka v `temporal-platform-worker`, `platform_worker.run_platform_workers`)
   intent ověří a spustí Temporal workflow `claims_batch` na frontě `claims-batch-tq`.
3. Worker téhož procesu: `claims_batch_documents` → `claims_advance_document` (OCR + návrh dělení, ONNX, pool 4 vlákna).
4. Úspěšný první průchod nastaví slot na `awaiting_review` (dělení čeká na potvrzení člověkem); po potvrzení
   `completed` → `awaiting_review`/`classified`.
5. `GET /operation` → `repository.get_batch_operation`: **status = `processing`, dokud má jakýkoli slot stav `processing`**.
   UI (`InvoiceIntake.refreshOperation`) jen ukazuje tento status.

## Příčiny (od nejpravděpodobnější)

### P1 — selhání dokladu nikdy nepřepíše slot (kód, jisté)
`ClaimsBatchWorkflow._advance` při `ActivityError` jen nastaví `attention` v paměti workflow.
`ClaimsActivities.claims_advance_document` při `_REFUSED` (ValueError/DekError) vrací `ClaimsDocumentOutcome("attention")`.
V DB slot zůstává `processing` navždy. Nic v `src/body/modules/financial_claim_preparation` nenastavuje
`batch_slot.state='failed'` kromě odmítnutého uploadu (`fail_batch_slot`, jen ze `reserved`).
Důsledek: jakákoli chyba zpracování (chybějící OCR modely, DEK/OpenBao, odebraná autorita, MinIO, ztracená
membership, `require_open`, překročených 180 stran) = „zpracovává se“ věčně, bez diagnostiky pro uživatele.
Do kategorie „zasekává se“ spadá i vyčerpaný retry (`schedule_to_close` = 3 × 60 min).

### P2 — dispatcher nedoručí intent (kód, pravděpodobné)
- `run_dispatcher` nemá try/except; `dispatch_pending` záměrně propaguje „ostatní chyby“. Výjimka z jednoho
  intentu ukončí `TaskGroup` → celý `platform_worker` skončí (exit 1, `restart: unless-stopped`).
  Intent zůstává `pending` a `_candidates` řadí podle `updated_at`, který se při pádu nemění → **poison intent je
  po restartu znovu první** a blokuje všechny ostatní (crash-loop).
- Healthcheck (`--check-readiness --role platform`) hlídá jen pollery, ne dispatcher ani frontu pending intentů.
- `require_local_ocr()` při startu: bez modelů worker nenastartuje vůbec (nepoběží ani dispatcher, ani poller).

### P3 — provozní (nutno ověřit na živém serveru, nemám přístup)
`temporal-platform-worker` nezdravý/v restart loopu, chybí `CLAIMS_RAPIDOCR_MODEL_DIR`/modely, `BODY_CUSTOMER_PROJECT_ID`,
OpenBao zapečetěný po restartu (`vast-openbao-autounseal.sh` restartuje jen `fastapi-body` a `temporal-worker`,
**ne `temporal-platform-worker`** → ten drží starý token/DEKy).

### P4 — není chyba, ale mate uživatele
Po úspěšném průchodu doklad skončí `awaiting_review` (čeká na potvrzení dělení). Hotový doklad v přehledu
se objeví až po potvrzení; UI to musí odlišit od „zpracovává se“.

## Diagnostika (krok 0, bez změny kódu; na Vast hostu, `docs/development/vast-ai-access.md`)
1. `docker ps`/`inspect` health + `RestartCount` u `sagibeast-temporal-platform-worker-1`; `docker logs --tail=200`
   (hledat „Platform Temporal workers stopped unexpectedly“, „Claims activity failed (<třída>, retryable=…)“,
   „Claims intent permanently rejected“, „delivery temporarily unavailable“).
2. Body-PG: `effects_outbox` — `status='pending'` u `batch_started` a jejich `updated_at`; `batch_slot.state` dávky;
   `claim_split_processing`/`claim_split_revision` pro doklad.
3. Temporal: `claims-batch-<batch_id>` — existuje? stav? pending activity + počet pokusů; poller na `claims-batch-tq`.
4. Rozhodnutí: pending intent → P2/P3; workflow neexistuje a worker zdravý → dispatcher; workflow existuje a activity
   retry → P1 + konkrétní příčina z logu; `awaiting_review` → P4.

## Plán opravy (TDD, po jednotlivých tascích)

### T1 — persistovat selhání dokladu (P1, jádro opravy)
- `ClaimsProcessingService`: nová metoda `mark_attention(operation, document)` — krátká transakce, `_hold` + `UPDATE batch_slot
  SET state='failed' WHERE state='processing'` (idempotentní, nepřepisuje `awaiting_review`/`classified`) + audit událost
  (`record_event`, např. `split_attention`) bez zákaznických dat.
- Volat ji: (a) v `claims_advance_document` větvi `_REFUSED` a u ošetřených „attention“ výsledků, (b) nová activity
  `claims_mark_attention`, kterou workflow zavolá v `except ActivityError` (vyčerpané retry, timeout, ztracený worker).
  Activity bude mít vlastní retry; workflow změna je verzovaná (`workflow.patched`), aby se nerozbily běžící dávky.
- `get_batch_operation`: `failed` už dnes nepatří do `processing`; status mapovat explicitně
  (`processing` / `attention` / `incomplete` / `ready`) a přidat do `BatchSlotStatus` strojový důvod (`readiness_reason`
  = `processing_failed`, nikdy text výjimky).
- Testy: unit `ClaimsProcessingService` (refused → slot `failed`, `awaiting_review` zůstane), workflow test
  (ActivityError → volá `claims_mark_attention`), `get_batch_operation` (failed slot → `attention`, ne `processing`).

### T2 — dispatcher odolný vůči poison intentu (P2)
- `run_dispatcher`: obalit `dispatch_pending` per-intent (v `dispatch_pending` při neočekávané výjimce zalogovat třídu,
  `_settle(..., "deferred")` pro bump `updated_at` a pokračovat; počítat selhání a po N po sobě jdoucích pokusech
  intent označit `failed` s `detail`). Zachovat propagaci pro `CancelledError`.
- Test: intent vyvolávající `CheckViolationError` neblokuje druhý intent; po prahu skončí `failed`.
  Upravit existující integrační test `test_claims_batch_temporal.py:163` (dnes očekává propagaci a `pending`).

### T3 — provozní viditelnost (P3)
- Healthcheck/readiness: přidat počet `pending` claims intentů starších než N minut (a/nebo heartbeat dispatcheru)
  → unhealthy/alarm; log s počtem pending při každém cyklu na úrovni DEBUG→WARNING při stagnaci.
- `vast-openbao-autounseal.sh`/`vast-body-openbao.sh`: do restartu přidat `temporal-platform-worker` (po ověření, že drží token).
- Dokumentovat v `docs/development/vast-ai-access.md` diagnostiku z kroku 0.

### T4 — UI (P4 + T1)
- `InvoiceIntake`: stav `awaiting_review` zobrazit jako „Čeká na potvrzení rozdělení“ s odkazem do review;
  `attention` jako chybu s akcí (opětovné zpracování = nová dávka / kontaktovat podporu). Polling zastavit při
  terminálním stavu a po časovém limitu ukázat „zpracování trvá neobvykle dlouho“, ne nekonečný spinner.
- Aktualizovat `InvoiceIntake.test.tsx`, `claimsApi.test.ts` (mapování `status`).

### T5 — ověření
- `pytest tests/unit/body -q --no-header` + integrační `test_claims_batch_temporal.py`, `test_claims_split_lineage.py`.
- Smoke na živém serveru po nasazení: nahrát dobré PDF → `awaiting_review`; nahrát PDF, které procesor odmítne → `attention`
  místo věčného `processing`; ověřit na `sagibeast-app.macato.io` skutečným QA účtem (`context/operations/qa-identities.md`).
- CHANGELOG/docs; `write-lessons.sh` s poučením „terminální stav dokladu musí být persistován, ne jen ve workflow paměti“.

## Otevřené (potřebuje rozhodnutí/přístup)
- Přístup na Vast host (SSH klíč `~/.ssh/vast_makato`) pro krok 0 — nepoužil jsem ho bez vyžádání.
- Chování po `attention`: znovu zpracovat stejnou dávku (nový intent) vs. jen nová dávka. Doporučuji nová dávka (immutable `started_at`).
