from decimal import Decimal
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Server settings read from the environment (see .env.example)."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore", env_ignore_empty=True)

    app_env: str = "local"
    database_url: str = "postgresql+asyncpg://postgres:postgres@127.0.0.1:55322/postgres"
    redis_url: str = "redis://localhost:6379/0"
    supabase_url: str = "http://127.0.0.1:55321"
    supabase_jwks_url: str = ""  # defaults to {supabase_url}/auth/v1/.well-known/jwks.json
    supabase_internal_url: str = ""  # how the server reaches Supabase (Docker); defaults to supabase_url
    supabase_service_role_key: str = ""  # server only: signs Storage URLs after the API has checked access
    auth_hook_secret: str = ""  # "v1,whsec_..." shared with the Supabase Send-SMS hook
    app_link_base: str = ""  # e.g. https://pairavi.in; invite links are {app_link_base}/join/{code}

    courtdata_live: bool = False  # False: the synthetic stand-in API (court_data.fake), never a real provider
    courtdata_rate_multiplier: int = 3
    ecourtsindia_api_base: str = "https://webapi.ecourtsindia.com/api/partner"
    ecourtsindia_api_key: str = ""
    courtdata_global_daily_cap_inr: Decimal | None = None
    courtdata_org_monthly_default_inr: Decimal | None = None
    ai_live: bool = False  # False: legal_ai.fake answers locally, never a real model
    bedrock_profile_fast: str = ""  # India geographic inference profiles (config/ai_models.yaml)
    bedrock_profile_standard: str = ""
    bedrock_profile_deep: str = ""
    ai_platform_daily_budget_inr: Decimal | None = None  # past it, automatic AI waits for the next day
    clamav_url: str = ""  # clamd for upload scans, e.g. tcp://127.0.0.1:3310; empty: uploads stay pending (fail closed)

    @property
    def jwks_url(self) -> str:
        return self.supabase_jwks_url or f"{self.supabase_url}/auth/v1/.well-known/jwks.json"

    @property
    def supabase_server_url(self) -> str:
        return self.supabase_internal_url or self.supabase_url

    @property
    def jwt_issuer(self) -> str:
        return f"{self.supabase_url}/auth/v1"


@lru_cache
def get_settings() -> Settings:
    return Settings()
