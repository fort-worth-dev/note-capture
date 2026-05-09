from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Loads `.env` from the backend working directory (e.g. `notes/backend`)."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    database_url: str = Field(description="Supabase Postgres connection string")
    cors_origins: str = Field(
        default="http://localhost:3000",
        description="Comma-separated browser origins for CORS",
    )


@lru_cache
def get_settings() -> Settings:
    return Settings()
