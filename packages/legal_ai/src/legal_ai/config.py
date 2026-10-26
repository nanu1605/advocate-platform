"""`config/ai_models.yaml` (spec §12.2, §12.14): tiers, task budgets, prices and credit prices."""

import json
import math
import os
import re
from collections.abc import Mapping
from decimal import Decimal
from pathlib import Path
from typing import Literal

import yaml
from pydantic import BaseModel, ConfigDict

DEFAULT_PATH = Path(__file__).resolve().parents[4] / "config" / "ai_models.yaml"
Tier = Literal["fast", "standard", "deep"]
Effort = Literal["low", "medium", "high", "xhigh", "max"]


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class Price(_Strict):
    input: Decimal
    output: Decimal


class Bedrock(_Strict):
    region: str
    endpoint: str
    required_profile_prefix: str
    profiles: dict[Tier, str]
    price_multiplier: Decimal
    usd_inr: Decimal
    prices_usd_per_mtok: dict[Tier, Price]
    effort_supported: dict[Tier, bool]


class Providers(_Strict):
    bedrock_india: Bedrock
    sarvam: dict[str, str] | None = None


class TaskConfig(_Strict):
    tier: Tier
    output_budget: int
    effort: Effort
    thinking_allowance: int

    @property
    def max_tokens(self) -> int:
        return self.output_budget + self.thinking_allowance  # thinking is billed as output


class Fallbacks(_Strict):
    on_unavailable: Literal["degrade"]  # never re-route outside India


class SummaryCredits(_Strict):
    per_5_pages: int
    max: int


class Credits(_Strict):
    inr_per_credit: Decimal
    actions: dict[str, int]
    order_summary: SummaryCredits


class AIConfig(_Strict):
    providers: Providers
    tasks: dict[str, TaskConfig]
    fallbacks: Fallbacks
    credits: Credits

    def credits_for(self, task: str, pages: int = 1) -> int:
        """What an on-demand action costs in credits (§14.2)."""
        if task == "order_summary":
            c = self.credits.order_summary
            return min(c.max, c.per_5_pages * math.ceil(max(pages, 1) / 5))
        return self.credits.actions[task]


def load_config(path: Path = DEFAULT_PATH, env: Mapping[str, str] = os.environ) -> AIConfig:
    """Parse the file with every `${VAR}` replaced from `env` (unset: empty, which the India guard then refuses)."""
    text = re.sub(r"\$\{(\w+)\}", lambda m: json.dumps(env.get(m[1], "")), path.read_text(encoding="utf-8"))
    return AIConfig.model_validate(yaml.safe_load(text))
