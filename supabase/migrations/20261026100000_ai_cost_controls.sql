-- Phase 2 AI cost controls (spec §12.14, ADR 0020).

-- An organisation's automatic AI (order summaries and order intelligence) is costed to it up to its plan's
-- automatic_ai_cap_inr a month; on-demand AI is paid in credits (`ai_credit`, quantity = credits).
alter table public.usage_ledger
  drop constraint usage_ledger_kind_check,
  add constraint usage_ledger_kind_check check (kind in (
    'tracked_case_day', 'ai_credit', 'ai_automatic', 'whatsapp', 'ocr_page', 'stt_second', 'provider_call'));

-- Today's platform AI spend, against AI_PLATFORM_DAILY_BUDGET_INR.
create index ai_runs_created_idx on public.ai_runs (created_at);
