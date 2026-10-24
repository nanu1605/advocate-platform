# Legal reference data awaiting advocate verification

Hard rule 2: any legal reference data that is not verified ships as `DRAFT – VERIFY` and is listed here.
Production builds hide DRAFT entries.

| Item | File | Status | Notes |
|---|---|---|---|
| Official case-status portal URLs by court level (eCourts services, HC services, Supreme Court) | `services/api/src/advocate_api/routes/matters.py` | DRAFT – VERIFY | Confirm each URL and whether a CNR can be passed in the link; the app only opens them (ADR 0011) |
| Board sitting times used for expected slots: Supreme Court from 10:30, about 3 min per item, lunch 13:00–14:00, rises 16:00 | `services/workers/src/advocate_workers/board.py` (`SITTINGS`) | DRAFT – VERIFY | Estimates for Tomorrow's Board clash flags (§4.2), not published timings. Confirm start, lunch and rising times and a realistic pace per item |
| Board sitting times: High Courts (MPHC Jabalpur, Indore, Gwalior) from 10:30, about 4 min per item, lunch 13:30–14:30, rises 16:30 | `services/workers/src/advocate_workers/board.py` (`SITTINGS`) | DRAFT – VERIFY | As above; benches may differ |
| Board sitting times: District Courts from 11:00, about 5 min per item, lunch 14:00–14:30, rises 17:00 | `services/workers/src/advocate_workers/board.py` (`SITTINGS`) | DRAFT – VERIFY | As above; the MP district court timetable decides |
| Board sitting times: tribunals from 10:30, about 5 min per item, lunch 13:30–14:30, rises 16:30 | `services/workers/src/advocate_workers/board.py` (`SITTINGS`) | DRAFT – VERIFY | No tribunal courts are seeded yet |
| Clash window: two matters in different court complexes clash when their expected times are under 60 minutes apart | `services/workers/src/advocate_workers/board.py` (`CLASH_WINDOW_MIN`), `apps/client/lib/data/clash.dart` (`clashWindowMinutes`) | DRAFT – VERIFY | Covers a short hearing plus travel between complexes (e.g. MPHC Indore and the District Court); fixtures in `config/fixtures/board_clash.yaml` |
