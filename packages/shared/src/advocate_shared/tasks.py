"""Celery task names the API enqueues and the workers implement (P1 task 6). Each takes one argument, the job id;
inputs live in `jobs.input`."""

FIND_CASES = "advocate_workers.find.find_cases"  # onboarding search → found_cases (spec §11.4)
FETCH_CASES = "advocate_workers.refresh.fetch_cases"  # get_case for newly added matters, then fan-out
REFRESH_CASE = "advocate_workers.refresh.refresh_case"  # on-demand refresh of one matter (§11.5)
SCAN_DOCUMENT = "advocate_workers.scan.scan_document"  # malware scan after upload (§4.3), then `ready`
# Internal, args (kind, id) with kind "document" or "court_order": text, OCR and chunks (§12.4), after a scan passes
# or a court order's PDF is stored.
EXTRACT_TEXT = "advocate_workers.text.extract_text"
# On-demand order AI (§10.2, paid in credits unless cached): input {order_id | document_id, language, credits}.
SUMMARISE_ORDER = "advocate_workers.summaries.summarise_order"  # job kind order_summary
SUMMARISE_DOCUMENT = "advocate_workers.summaries.summarise_document"  # job kind document_summary (an uploaded order)
ORDER_INTEL = "advocate_workers.summaries.order_intel"  # job kind order_intel: proposed tasks and deadlines

# Celery routes on the sending side, so the API's app and the workers' share these. Reading text, OCR above all, can
# take minutes per file: its own worker (infra/docker/compose.yml), so it delays neither user jobs nor the board.
# Model calls wait on Bedrock for up to minutes, so AI has its own worker too.
ROUTES = {EXTRACT_TEXT: {"queue": "text"}} | {
    name: {"queue": "ai"} for name in (SUMMARISE_ORDER, SUMMARISE_DOCUMENT, ORDER_INTEL)
}
