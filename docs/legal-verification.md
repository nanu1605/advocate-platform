# Legal reference data awaiting advocate verification

Hard rule 2: any legal reference data that is not verified ships as `DRAFT – VERIFY` and is listed here.
Production builds hide DRAFT entries.

| Item | File | Status | Notes |
|---|---|---|---|
| Official case-status portal URLs by court level (eCourts services, HC services, Supreme Court) | `services/api/src/advocate_api/routes/matters.py` | DRAFT – VERIFY | Confirm each URL and whether a CNR can be passed in the link; the app only opens them (ADR 0011) |
