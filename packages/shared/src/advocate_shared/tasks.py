"""Celery task names the API enqueues and the workers implement (P1 task 6). Each takes one argument, the job id;
inputs live in `jobs.input`."""

FIND_CASES = "advocate_workers.tasks.find_cases"  # onboarding search → found_cases (spec §11.4)
FETCH_CASES = "advocate_workers.tasks.fetch_cases"  # get_case for newly added matters, then fan-out
REFRESH_CASE = "advocate_workers.tasks.refresh_case"  # on-demand refresh of one matter (§11.5)
SCAN_DOCUMENT = "advocate_workers.tasks.scan_document"  # malware scan after upload (§4.3), then `ready`
