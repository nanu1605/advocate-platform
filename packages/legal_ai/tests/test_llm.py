import pytest

from legal_ai.llm import LLMClient, NonIndiaRouteError, TaskConfig

TASKS = {"order_summary": TaskConfig(tier="standard", output_budget=1200, effort="medium", thinking_allowance=4000)}
INDIA = {"fast": "in.anthropic.haiku", "standard": "in.anthropic.sonnet", "deep": "in.anthropic.opus"}


def client(**overrides):
    kwargs = {"region": "ap-south-1", "endpoint": "bedrock-runtime", "profiles": INDIA, "tasks": TASKS} | overrides
    return LLMClient(**kwargs)


def test_accepts_india_profiles():
    assert client().profiles == INDIA


@pytest.mark.parametrize(
    "profiles",
    [
        {**INDIA, "deep": "global.anthropic.opus"},
        {**INDIA, "fast": "us.anthropic.haiku"},
        {**INDIA, "standard": "anthropic.sonnet"},
        {**INDIA, "standard": ""},
    ],
)
def test_refuses_non_india_profiles(profiles):
    with pytest.raises(NonIndiaRouteError):
        client(profiles=profiles)


@pytest.mark.parametrize("override", [{"region": "us-east-1"}, {"endpoint": "bedrock-mantle"}])
def test_refuses_other_region_or_endpoint(override):
    with pytest.raises(NonIndiaRouteError):
        client(**override)


def test_strips_sampling_params_and_sets_budget():
    req = client().request(
        "order_summary", [{"role": "user", "content": "x"}], temperature=0.2, top_p=0.9, top_k=5, system="s"
    )
    assert not {"temperature", "top_p", "top_k"} & req.keys()
    assert req["max_tokens"] == 5200
    assert req["modelId"] == "in.anthropic.sonnet"
    assert req["system"] == "s"
