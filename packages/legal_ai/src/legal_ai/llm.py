"""LLM access guard (spec §12.2, hard rule 3). Case content may reach Claude only through Bedrock Runtime in
ap-south-1 with India geographic inference profiles. The real Bedrock call lands after spike 11c; these checks
are the part that must hold from day one."""

from dataclasses import dataclass
from typing import Any

REQUIRED_REGION = "ap-south-1"
REQUIRED_ENDPOINT = "bedrock-runtime"
REQUIRED_PROFILE_PREFIX = "in."  # confirm in spike 11c
SAMPLING_PARAMS = frozenset({"temperature", "top_p", "top_k"})  # Claude 5-class models reject these


class NonIndiaRouteError(ValueError):
    pass


@dataclass(frozen=True)
class TaskConfig:
    tier: str
    output_budget: int
    effort: str
    thinking_allowance: int

    @property
    def max_tokens(self) -> int:
        return self.output_budget + self.thinking_allowance  # thinking is billed as output


class LLMClient:
    def __init__(self, *, region: str, endpoint: str, profiles: dict[str, str], tasks: dict[str, TaskConfig]):
        if region != REQUIRED_REGION:
            raise NonIndiaRouteError(f"LLM region must be {REQUIRED_REGION}, got {region!r}")
        if endpoint != REQUIRED_ENDPOINT:
            raise NonIndiaRouteError(f"LLM endpoint must be {REQUIRED_ENDPOINT}, got {endpoint!r}")
        bad = {tier: p for tier, p in profiles.items() if not (p or "").startswith(REQUIRED_PROFILE_PREFIX)}
        if bad:
            raise NonIndiaRouteError(f"Only India geographic inference profiles allowed; refused: {sorted(bad)}")
        self.profiles, self.tasks = profiles, tasks

    def request(self, task: str, messages: list[dict[str, Any]], **params: Any) -> dict[str, Any]:
        """Build the request body for a task: model from its tier, token budget from config, no sampling params."""
        cfg = self.tasks[task]
        clean = {k: v for k, v in params.items() if k not in SAMPLING_PARAMS}
        return {
            "modelId": self.profiles[cfg.tier],
            "messages": messages,
            "max_tokens": cfg.max_tokens,
            "effort": cfg.effort,
            **clean,
        }
