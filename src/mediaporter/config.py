"""Configuration file loading and defaults."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

CONFIG_DIR = Path.home() / ".config" / "mediaporter"
CONFIG_FILE = CONFIG_DIR / "config.toml"


@dataclass
class Config:
    """Application configuration."""
    quality: str = "balanced"
    hw_acceleration: bool = True
    keep_files: bool = False
    tmdb_api_key: str | None = None
    subtitle_mode: str = "embed"
    burn_bitmap_subs: bool = False
    preferred_languages: list[str] = field(default_factory=lambda: ["eng"])


def load_config() -> Config:
    """Load configuration from file and environment."""
    config = Config()

    if CONFIG_FILE.exists():
        try:
            import tomllib
        except ImportError:
            try:
                import tomli as tomllib  # type: ignore
            except ImportError:
                return config

        with open(CONFIG_FILE, "rb") as f:
            data = tomllib.load(f)

        general = data.get("general", {})
        config.quality = general.get("quality", config.quality)
        config.hw_acceleration = general.get("hw_acceleration", config.hw_acceleration)
        config.keep_files = general.get("keep_files", config.keep_files)

        metadata = data.get("metadata", {})
        config.tmdb_api_key = metadata.get("tmdb_api_key", config.tmdb_api_key)

        subs = data.get("subtitles", {})
        config.subtitle_mode = subs.get("mode", config.subtitle_mode)
        config.burn_bitmap_subs = subs.get("burn_bitmap", config.burn_bitmap_subs)
        config.preferred_languages = subs.get("preferred_languages", config.preferred_languages)

    # Load .env file from project directory (walk up to find it)
    _load_dotenv()

    if env_key := os.environ.get("TMDB_API_KEY"):
        config.tmdb_api_key = env_key

    return config


def _load_dotenv() -> None:
    """Load .env file from current or parent directories into os.environ."""
    cwd = Path.cwd()
    for directory in [cwd, *cwd.parents]:
        env_file = directory / ".env"
        if env_file.is_file():
            for line in env_file.read_text().splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                key = key.strip()
                value = value.strip().strip("'\"")
                if key and key not in os.environ:
                    os.environ[key] = value
            break
