import pytest

from advocate_shared import ai
from advocate_shared.settings import get_settings
from legal_ai.fake import local_transport
from legal_ai.llm import BedrockTransport, NonIndiaRouteError


@pytest.fixture(autouse=True)
def fresh(monkeypatch):
    monkeypatch.setenv("AWS_EC2_METADATA_DISABLED", "true")
    for k in ("AWS_ENDPOINT_URL", "AWS_ENDPOINT_URL_BEDROCK_RUNTIME"):
        monkeypatch.delenv(k, raising=False)
    ai.configured_llm.cache_clear()
    yield
    ai.configured_llm.cache_clear()


def test_ai_off_answers_locally(monkeypatch):
    monkeypatch.setattr(get_settings(), "ai_live", False)
    c = ai.configured_llm()
    assert c.transport is local_transport and c.bedrock.profiles["standard"] == "in.local.standard"


def test_ai_on_needs_india_profiles(monkeypatch):
    s = get_settings()
    monkeypatch.setattr(s, "ai_live", True)
    for tier in ("fast", "standard", "deep"):
        monkeypatch.setattr(s, f"bedrock_profile_{tier}", "")
    with pytest.raises(NonIndiaRouteError):
        ai.configured_llm()
    monkeypatch.setattr(s, "bedrock_profile_deep", "global.anthropic.opus")
    for tier in ("fast", "standard"):
        monkeypatch.setattr(s, f"bedrock_profile_{tier}", f"in.anthropic.{tier}")
    with pytest.raises(NonIndiaRouteError):
        ai.configured_llm()
    monkeypatch.setattr(s, "bedrock_profile_deep", "in.anthropic.opus")
    c = ai.configured_llm()
    assert isinstance(c.transport, BedrockTransport)
    assert c.transport.client.meta.endpoint_url == "https://bedrock-runtime.ap-south-1.amazonaws.com"
