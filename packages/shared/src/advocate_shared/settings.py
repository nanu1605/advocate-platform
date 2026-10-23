from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Server settings read from the environment (see .env.example)."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_env: str = "local"
    database_url: str = "postgresql+asyncpg://postgres:postgres@127.0.0.1:55322/postgres"
    redis_url: str = "redis://localhost:6379/0"
    supabase_url: str = "http://127.0.0.1:55321"
    supabase_jwks_url: str = ""  # defaults to {supabase_url}/auth/v1/.well-known/jwks.json
    auth_hook_secret: str = ""  # "v1,whsec_..." shared with the Supabase Send-SMS hook

    @property
    def jwks_url(self) -> str:
        return self.supabase_jwks_url or f"{self.supabase_url}/auth/v1/.well-known/jwks.json"

    @property
    def jwt_issuer(self) -> str:
        return f"{self.supabase_url}/auth/v1"


@lru_cache
def get_settings() -> Settings:
    return Settings()
