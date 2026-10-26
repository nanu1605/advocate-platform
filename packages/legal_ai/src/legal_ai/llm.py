"""The one way to call Claude (spec §12.2, §12.3, hard rule 3). Case content reaches Claude only through Bedrock
Runtime in ap-south-1 with India geographic inference profiles, through the Converse API. Every task returns JSON
validated by its contract, retried at most twice with the validation error, and every call is costed for `ai_runs`."""

import asyncio
import json
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal
from typing import Any, Literal

from pydantic import BaseModel

from legal_ai.config import AIConfig, Bedrock, TaskConfig, Tier
from legal_ai.prompts import Source, load_prompt

__all__ = ["AIError", "LLMClient", "NonIndiaRouteError", "Result", "Run", "TaskConfig"]

REQUIRED_REGION = "ap-south-1"
REQUIRED_ENDPOINT = "bedrock-runtime"
REQUIRED_PROFILE_PREFIX = "in."  # confirm in spike 11c
RETRIES = 2  # after the first attempt (§12.3)
RETRY = "Your reply could not be used: {problem}\n\nReply again with only the corrected JSON object."
# Converse errors that mean "try later" (fallbacks.on_unavailable: degrade); anything else is a failure.
UNAVAILABLE = frozenset(
    {
        "ThrottlingException",
        "ServiceUnavailableException",
        "ModelNotReadyException",
        "ModelTimeoutException",
        "InternalServerException",
        "ServiceQuotaExceededException",
    }
)

Status = Literal["ok", "failed", "invalid_output", "unavailable"]
# (task, Converse request) -> Converse response. BedrockTransport in production, legal_ai.fake locally and in CI.
Transport = Callable[[str, dict[str, Any]], dict[str, Any]]


class NonIndiaRouteError(ValueError):
    pass


class Unavailable(Exception):
    """The model can't take the call now (throttled, down, timed out). Raised by transports."""

    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


class CallFailed(Exception):
    """The call was refused (bad request, access denied). Raised by transports."""

    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


@dataclass(frozen=True)
class Run:
    """What `ai_runs` records about one task: tokens and cost over every attempt, never prompt or answer text."""

    task: str
    prompt_version: str
    model_tier: Tier
    model_id: str
    input_tokens: int
    output_tokens: int  # thinking included
    cost_inr: Decimal
    latency_ms: int
    status: Status
    error_code: str | None = None


@dataclass(frozen=True)
class Result[T: BaseModel]:
    output: T
    run: Run


class AIError(Exception):
    """The task produced no usable output. `run` still records what it cost."""

    def __init__(self, run: Run):
        super().__init__(f"{run.task}: {run.status} ({run.error_code})")
        self.run = run


class LLMClient:
    def __init__(self, config: AIConfig, transport: Transport):
        b = config.providers.bedrock_india
        if b.region != REQUIRED_REGION:
            raise NonIndiaRouteError(f"LLM region must be {REQUIRED_REGION}, got {b.region!r}")
        if b.endpoint != REQUIRED_ENDPOINT:
            raise NonIndiaRouteError(f"LLM endpoint must be {REQUIRED_ENDPOINT}, got {b.endpoint!r}")
        if b.required_profile_prefix != REQUIRED_PROFILE_PREFIX:
            raise NonIndiaRouteError(f"profile prefix must be {REQUIRED_PROFILE_PREFIX!r}")
        bad = sorted(tier for tier, p in b.profiles.items() if not p.startswith(REQUIRED_PROFILE_PREFIX))
        if bad or set(b.profiles) != {"fast", "standard", "deep"}:
            raise NonIndiaRouteError(f"Only India geographic inference profiles allowed; refused: {bad or 'missing'}")
        self.config, self.transport = config, transport

    @property
    def bedrock(self) -> Bedrock:
        return self.config.providers.bedrock_india

    def request(self, task: str, system: str, messages: list[dict[str, Any]]) -> dict[str, Any]:
        """The Converse request for a task: the tier's India profile, the task's token budget and effort. Never a
        sampling parameter (temperature, top_p, top_k): Claude 5-class models reject them."""
        cfg = self.config.tasks[task]
        req: dict[str, Any] = {
            "modelId": self.bedrock.profiles[cfg.tier],
            "system": [{"text": system}],
            "messages": messages,
            "inferenceConfig": {"maxTokens": cfg.max_tokens},
        }
        if self.bedrock.effort_supported[cfg.tier]:
            req["outputConfig"] = {"effort": cfg.effort}
        return req

    def cost_inr(self, tier: Tier, input_tokens: int, output_tokens: int) -> Decimal:
        """Token counts (thinking included) x list price x the regional `price_multiplier` (§12.14)."""
        p = self.bedrock.prices_usd_per_mtok[tier]
        usd = (input_tokens * p.input + output_tokens * p.output) / 1_000_000
        return (usd * self.bedrock.usd_inr * self.bedrock.price_multiplier).quantize(Decimal("0.0001"), ROUND_HALF_UP)

    async def structured[T: BaseModel](
        self,
        task: str,
        output: type[T],
        *,
        language: Literal["hi", "en"],
        params: Mapping[str, str] | None = None,
        sources: Sequence[Source] = (),
        data: Mapping[str, str] | None = None,
    ) -> Result[T]:
        """Run `task` and return its validated output. `sources` are numbered S1…Sn in order and every source id in
        the output must be one of them; `data` is other untrusted text (a question, a transcript); `params` are
        trusted values the prompt names (dates), also given to the contract's validators. Raises AIError when there is
        no usable output."""
        prompt = load_prompt(task)
        cfg = self.config.tasks[task]
        system = prompt.system(language, output)
        messages: list[dict[str, Any]] = [{"role": "user", "content": [{"text": prompt.user(params, sources, data)}]}]
        context = {"source_ids": {f"S{i}" for i in range(1, len(sources) + 1)}, "params": dict(params or {})}
        usage = _Usage()

        def run(status: Status, error_code: str | None = None) -> Run:
            return Run(
                task=task,
                prompt_version=prompt.version,
                model_tier=cfg.tier,
                model_id=self.bedrock.profiles[cfg.tier],
                input_tokens=usage.input,
                output_tokens=usage.output,
                cost_inr=self.cost_inr(cfg.tier, usage.input, usage.output),
                latency_ms=usage.ms,
                status=status,
                error_code=error_code,
            )

        for _ in range(1 + RETRIES):
            start = time.monotonic()
            try:
                response = await asyncio.to_thread(self.transport, task, self.request(task, system, messages))
            except (Unavailable, CallFailed) as e:
                usage.ms += round((time.monotonic() - start) * 1000)
                raise AIError(run("unavailable" if isinstance(e, Unavailable) else "failed", e.code)) from e
            usage.ms += round((time.monotonic() - start) * 1000)
            usage.add(response["usage"])
            stop = response["stopReason"]
            if stop not in ("end_turn", "max_tokens"):
                raise AIError(run("failed", f"STOP_{stop.upper()}"))
            text = "".join(b["text"] for b in response["output"]["message"]["content"] if "text" in b)
            try:
                if stop == "max_tokens":
                    raise ValueError("the reply was cut off at its length limit; reply more briefly")
                return Result(output.model_validate(_json(text), context=context), run("ok"))
            except ValueError as e:  # json.JSONDecodeError and pydantic's ValidationError are ValueErrors
                messages += [
                    {"role": "assistant", "content": [{"text": text or "(empty reply)"}]},
                    {"role": "user", "content": [{"text": RETRY.format(problem=str(e)[:2000])}]},
                ]
        raise AIError(run("invalid_output", "INVALID_OUTPUT"))


@dataclass
class _Usage:
    input: int = 0
    output: int = 0
    ms: int = 0

    def add(self, u: Mapping[str, int]) -> None:
        self.input += u["inputTokens"]
        self.output += u["outputTokens"]


def _json(text: str) -> Any:
    """The JSON object in a reply, tolerating a code fence or a sentence around it."""
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end < start:
        raise ValueError("the reply has no JSON object")
    return json.loads(text[start : end + 1])


class BedrockTransport:
    """Converse on Bedrock Runtime through boto3 (credentials from the default chain: the ECS task role). Refuses
    to start if boto3 would send requests anywhere but bedrock-runtime in the configured region, e.g. through an
    AWS_ENDPOINT_URL* override."""

    def __init__(self, bedrock: Bedrock):
        import boto3  # here: slow to import, and not needed while AI_LIVE=0
        from botocore.config import Config

        # Converse answers only when the whole generation is done, so the read timeout covers the largest budget.
        # No SDK retries: a resent call is paid again, and the caller degrades or queues (§12.2 fallbacks).
        self.client = boto3.client(
            "bedrock-runtime",
            region_name=bedrock.region,
            config=Config(retries={"total_max_attempts": 1, "mode": "standard"}, connect_timeout=5, read_timeout=900),
        )
        expected = f"https://{bedrock.endpoint}.{bedrock.region}.amazonaws.com"
        if self.client.meta.endpoint_url != expected or self.client.meta.region_name != bedrock.region:
            raise NonIndiaRouteError(f"Bedrock client points at {self.client.meta.endpoint_url}, not {expected}")

    def __call__(self, task: str, request: dict[str, Any]) -> dict[str, Any]:
        from botocore.exceptions import BotoCoreError, ClientError, HTTPClientError
        from botocore.exceptions import ConnectionError as BotoConnectionError

        try:
            return self.client.converse(**request)
        except ClientError as e:
            code = e.response.get("Error", {}).get("Code", "ClientError")
            raise (Unavailable if code in UNAVAILABLE else CallFailed)(code) from e
        except (BotoConnectionError, HTTPClientError) as e:  # can't connect, or timed out: try later
            raise Unavailable(type(e).__name__) from e
        except BotoCoreError as e:  # no credentials, a bad parameter: retrying won't help
            raise CallFailed(type(e).__name__) from e
