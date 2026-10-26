import json
import time
from decimal import Decimal

import pytest
from botocore.exceptions import EndpointConnectionError, NoCredentialsError, ParamValidationError, ReadTimeoutError
from botocore.stub import Stubber

from legal_ai.config import AIConfig, load_config
from legal_ai.contracts import OUTPUTS, AskAnswer, ClientUpdate, VoiceParse
from legal_ai.fake import Scripted, local_transport, response
from legal_ai.llm import AIError, BedrockTransport, CallFailed, LLMClient, NonIndiaRouteError, Unavailable
from legal_ai.prompts import Source

INDIA = {"BEDROCK_PROFILE_FAST": "in.anthropic.haiku", "BEDROCK_PROFILE_STANDARD": "in.anthropic.sonnet"}
INDIA |= {"BEDROCK_PROFILE_DEEP": "in.anthropic.opus"}
ANSWER = {"found": True, "answer": [{"text": "Reply was filed on 12.03.2026.", "sources": ["S1"]}]}
PAGE = [Source("case_doc", "Reply filed on 12.03.2026.", page=4)]


def config(**bedrock: object) -> AIConfig:
    raw = load_config(env=INDIA).model_dump()
    raw["providers"]["bedrock_india"] |= bedrock
    return AIConfig.model_validate(raw)


def client(transport=local_transport, **bedrock: object) -> LLMClient:
    return LLMClient(config(**bedrock), transport)


# ---------------------------------------------------------------- config and the India guard


def test_config_matches_the_spec_budgets():
    cfg = load_config(env=INDIA)
    assert cfg.providers.bedrock_india.profiles == {"fast": "in.anthropic.haiku", "standard": "in.anthropic.sonnet",
                                                    "deep": "in.anthropic.opus"}  # fmt: skip
    t = cfg.tasks["order_summary"]
    assert (t.tier, t.output_budget, t.effort, t.thinking_allowance, t.max_tokens) == ("standard", 1200, "medium",
                                                                                        4000, 5200)  # fmt: skip
    assert cfg.tasks["strategy"].max_tokens == 20000
    assert cfg.providers.bedrock_india.price_multiplier == Decimal("1.10")
    assert set(OUTPUTS) <= set(cfg.tasks)


def test_unset_profiles_load_empty_and_are_refused():
    with pytest.raises(NonIndiaRouteError):
        LLMClient(load_config(env={}), local_transport)


@pytest.mark.parametrize(
    "profiles",
    [
        {"deep": "global.anthropic.opus"},
        {"fast": "us.anthropic.haiku"},
        {"standard": "anthropic.sonnet"},
        {"standard": ""},
        {"standard": "apac.anthropic.sonnet"},
    ],
)
def test_refuses_non_india_profiles(profiles):
    with pytest.raises(NonIndiaRouteError):
        client(profiles={**config().providers.bedrock_india.profiles, **profiles})


@pytest.mark.parametrize(
    "override",
    [{"region": "us-east-1"}, {"endpoint": "bedrock-mantle"}, {"required_profile_prefix": ""}],
)
def test_refuses_other_region_endpoint_or_prefix(override):
    with pytest.raises(NonIndiaRouteError):
        client(**override)


def test_the_fallback_never_reroutes():
    raw = load_config(env=INDIA).model_dump()
    raw["fallbacks"]["on_unavailable"] = "reroute"
    with pytest.raises(ValueError, match="degrade"):
        AIConfig.model_validate(raw)


# ---------------------------------------------------------------- requests and cost


def test_request_has_budget_effort_and_no_sampling_params():
    req = client().request("ask_case", "system", [{"role": "user", "content": [{"text": "q"}]}])
    assert req["modelId"] == "in.anthropic.sonnet"
    assert req["inferenceConfig"] == {"maxTokens": 5200}
    assert req["outputConfig"] == {"effort": "medium"}
    assert not {"temperature", "topP", "top_p", "top_k", "additionalModelRequestFields"} & (
        req.keys() | req["inferenceConfig"].keys()
    )


def test_effort_is_left_out_where_the_tier_rejects_it():
    assert "outputConfig" not in client().request("voice_parse", "s", [])  # fast tier: Haiku 4.5
    assert client(effort_supported={"fast": True, "standard": True, "deep": True}).request("voice_parse", "s", [])[
        "outputConfig"
    ] == {"effort": "low"}


def test_cost_counts_thinking_at_list_price_times_the_multiplier():
    # Sonnet-class $2 / $10 per million: (10,000 x 2 + 5,000 x 10) / 1e6 = $0.07 → x ₹88 x 1.10 = ₹6.776
    assert client().cost_inr("standard", 10_000, 5_000) == Decimal("6.7760")
    assert client().cost_inr("fast", 0, 0) == 0


# ---------------------------------------------------------------- structured outputs


async def test_valid_reply_returns_output_and_run():
    t = Scripted([response(json.dumps(ANSWER), input_tokens=2000, output_tokens=300)])
    r = await client(t).structured("ask_case", AskAnswer, language="en", sources=PAGE, data={"question": "q?"})
    assert r.output.answer[0].sources == ["S1"]
    run = r.run
    assert (run.status, run.task, run.prompt_version) == ("ok", "ask_case", "v1")
    assert (run.model_tier, run.model_id) == ("standard", "in.anthropic.sonnet")
    assert (run.input_tokens, run.output_tokens, run.cost_inr) == (2000, 300, client().cost_inr("standard", 2000, 300))
    [(task, req)] = t.requests
    assert task == "ask_case" and "Output language: English." in req["system"][0]["text"]
    assert '<source id="S1" kind="case_doc" page="4">' in req["messages"][0]["content"][0]["text"]


async def test_reply_in_a_code_fence_is_accepted():
    t = Scripted(["```json\n" + json.dumps(ANSWER) + "\n```"])
    assert (
        await client(t).structured("ask_case", AskAnswer, language="en", sources=PAGE, data={"question": "q"})
    ).output.found


@pytest.mark.parametrize(
    "bad",
    [
        "not json at all",
        json.dumps({"found": True, "answer": [{"text": "x", "sources": ["S9"]}]}),  # a source it wasn't given
        json.dumps({"found": True, "answer": [{"text": "x", "sources": []}]}),  # an unsourced point
        json.dumps({"found": True, "answer": []}),  # "found" with no answer
        json.dumps({**ANSWER, "extra": 1}),
    ],
)
async def test_invalid_reply_is_retried_with_the_error(bad):
    t = Scripted([bad, json.dumps(ANSWER)])
    r = await client(t).structured("ask_case", AskAnswer, language="en", sources=PAGE, data={"question": "q"})
    assert r.run.status == "ok" and r.run.input_tokens == 2000  # both attempts are costed
    msgs = t.requests[1][1]["messages"]
    assert [m["role"] for m in msgs] == ["user", "assistant", "user"]
    assert msgs[1]["content"][0]["text"] == bad
    assert msgs[2]["content"][0]["text"].startswith("Your reply could not be used:")


async def test_three_invalid_replies_fail_gracefully_with_their_cost():
    t = Scripted(["nope"] * 3)
    with pytest.raises(AIError) as e:
        await client(t).structured("ask_case", AskAnswer, language="en", sources=PAGE, data={"question": "q"})
    run = e.value.run
    assert (run.status, run.error_code, run.input_tokens) == ("invalid_output", "INVALID_OUTPUT", 3000)
    assert len(t.requests) == 3


async def test_a_cut_off_reply_is_retried():
    t = Scripted([response('{"found": true, "answ', stop="max_tokens"), json.dumps(ANSWER)])
    r = await client(t).structured("ask_case", AskAnswer, language="en", sources=PAGE, data={"question": "q"})
    assert r.run.status == "ok"
    assert "cut off" in t.requests[1][1]["messages"][2]["content"][0]["text"]


async def test_an_empty_reply_is_retried_without_an_empty_message():
    t = Scripted([response(""), json.dumps(ANSWER)])
    await client(t).structured("ask_case", AskAnswer, language="en", sources=PAGE, data={"question": "q"})
    assert t.requests[1][1]["messages"][1]["content"][0]["text"] == "(empty reply)"


@pytest.mark.parametrize(
    ("error", "status", "code"),
    [
        (Unavailable("ThrottlingException"), "unavailable", "ThrottlingException"),
        (CallFailed("ValidationException"), "failed", "ValidationException"),
        (response("{}", stop="content_filtered"), "failed", "STOP_CONTENT_FILTERED"),
    ],
)
async def test_call_errors_are_not_retried_and_never_rerouted(error, status, code):
    t = Scripted([error, json.dumps(ANSWER)])
    with pytest.raises(AIError) as e:
        await client(t).structured("ask_case", AskAnswer, language="en", sources=PAGE, data={"question": "q"})
    assert (e.value.run.status, e.value.run.error_code) == (status, code)
    assert len(t.requests) == 1


async def test_a_failed_call_records_its_time():
    def slow(task, request):
        time.sleep(0.05)
        raise Unavailable("ThrottlingException")

    with pytest.raises(AIError) as e:
        await client(slow).structured("ask_case", AskAnswer, language="en", sources=PAGE, data={"question": "q"})
    assert e.value.run.latency_ms >= 40


async def test_params_reach_the_validators():
    """A spoken date resolved into the past ("12 November" said on 26 November) goes back to the model."""
    parse = {"matter": None, "matter_confidence": "low", "next_date_confidence": "high", "purpose": None,
             "outcome": None, "tasks": [], "note": None}  # fmt: skip
    t = Scripted([json.dumps({**parse, "next_date": "2026-11-12"}), json.dumps({**parse, "next_date": "2027-11-12"})])
    r = await client(t).structured("voice_parse", VoiceParse, language="hi", params={"today": "2026-11-26"},
                                   data={"transcript": "agli tareekh 12 November"})  # fmt: skip
    assert str(r.output.next_date) == "2027-11-12" and len(t.requests) == 2
    assert "before today" in t.requests[1][1]["messages"][2]["content"][0]["text"]


async def test_a_source_id_is_refused_when_no_sources_were_given():
    t = Scripted([json.dumps({"found": True, "answer": [{"text": "x", "sources": ["S1"]}]})] * 3)
    with pytest.raises(AIError):
        await client(t).structured("ask_case", AskAnswer, language="en", data={"question": "q"})


async def test_hindi_output_sends_the_hindi_rules():
    t = Scripted([json.dumps({"message": "नमस्ते रमेश जी"})])
    await client(t).structured("client_update", ClientUpdate, language="hi", data={"client": "Ramesh", "facts": "f"})
    system = t.requests[0][1]["system"][0]["text"]
    assert "Output language: Hindi." in system and "अगली तारीख" in system


@pytest.mark.parametrize("task", sorted(OUTPUTS))
async def test_the_local_stand_in_answers_every_task(task):
    params = {"order_date": "2026-10-01", "today": "2026-10-26", "hearing_date": "2026-10-27"}
    data = {"question": "q", "transcript": "t", "client": "c", "facts": "f"}
    r = await client().structured(task, OUTPUTS[task], language="en", params=params, sources=PAGE, data=data)
    assert r.run.status == "ok" and r.run.cost_inr > 0


# ---------------------------------------------------------------- Bedrock transport


@pytest.fixture
def aws(monkeypatch):
    for k, v in {
        "AWS_ACCESS_KEY_ID": "test",
        "AWS_SECRET_ACCESS_KEY": "test",
        "AWS_EC2_METADATA_DISABLED": "true",
    }.items():
        monkeypatch.setenv(k, v)
    for k in ("AWS_ENDPOINT_URL", "AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "AWS_PROFILE"):
        monkeypatch.delenv(k, raising=False)


def test_transport_talks_to_bedrock_runtime_in_mumbai(aws):
    t = BedrockTransport(config().providers.bedrock_india)
    assert t.client.meta.endpoint_url == "https://bedrock-runtime.ap-south-1.amazonaws.com"


@pytest.mark.parametrize("var", ["AWS_ENDPOINT_URL", "AWS_ENDPOINT_URL_BEDROCK_RUNTIME"])
def test_transport_refuses_an_endpoint_override(aws, monkeypatch, var):
    monkeypatch.setenv(var, "https://bedrock-mantle.ap-south-1.api.aws")
    with pytest.raises(NonIndiaRouteError):
        BedrockTransport(config().providers.bedrock_india)


async def test_converse_request_is_valid_for_the_bedrock_api(aws):
    """botocore checks the request against the Converse service model: names, types and nesting."""
    t = BedrockTransport(config().providers.bedrock_india)
    c = LLMClient(config(), t)
    with Stubber(t.client) as stub:
        stub.add_response("converse", response(json.dumps(ANSWER)))
        r = await c.structured("ask_case", AskAnswer, language="en", sources=PAGE, data={"question": "q"})
        stub.assert_no_pending_responses()
    assert r.run.status == "ok"


def test_transport_never_resends_a_paid_call_and_waits_for_long_answers(aws):
    t = BedrockTransport(config().providers.bedrock_india)
    assert t.client.meta.config.retries["total_max_attempts"] == 1 and t.client.meta.config.read_timeout == 900


@pytest.mark.parametrize(
    ("raised", "error"),
    [
        (EndpointConnectionError(endpoint_url="https://bedrock-runtime.ap-south-1.amazonaws.com"), Unavailable),
        (ReadTimeoutError(endpoint_url="https://bedrock-runtime.ap-south-1.amazonaws.com"), Unavailable),
        (NoCredentialsError(), CallFailed),
        (ParamValidationError(report="Unknown parameter in input"), CallFailed),
    ],
)
def test_botocore_errors_are_unavailable_only_when_a_retry_can_help(aws, monkeypatch, raised, error):
    t = BedrockTransport(config().providers.bedrock_india)

    def converse(**_):
        raise raised

    monkeypatch.setattr(t.client, "converse", converse)
    with pytest.raises(error) as e:
        t("ask_case", {})
    assert e.value.code == type(raised).__name__


@pytest.mark.parametrize(
    ("code", "error"),
    [
        ("ThrottlingException", Unavailable),
        ("ServiceUnavailableException", Unavailable),
        ("ModelNotReadyException", Unavailable),
        ("ModelTimeoutException", Unavailable),
        ("ValidationException", CallFailed),
        ("AccessDeniedException", CallFailed),
    ],
)
def test_converse_errors_map_to_unavailable_or_failed(aws, code, error):
    t = BedrockTransport(config().providers.bedrock_india)
    with Stubber(t.client) as stub:
        stub.add_client_error("converse", service_error_code=code, http_status_code=400)
        with pytest.raises(error) as e:
            t("ask_case", {"modelId": "in.x", "messages": []})
    assert e.value.code == code
