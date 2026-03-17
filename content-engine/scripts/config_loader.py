#!/usr/bin/env python3
"""
Shared configuration loader for SEO-GEO Blog Writer

Loads credentials and settings from ~/.seo-geo-skill/config.json with fallback to environment variables.

Priority order (highest to lowest):
1. CLI arguments (passed directly to scripts)
2. Environment variables
3. Config file (~/.seo-geo-skill/config.json in user's home directory)

Security: Config file is stored in home directory (outside skill directory) to prevent
accidental exposure when zipping/uploading the skill to Claude.
"""

import json
import os
from pathlib import Path
from typing import Optional, Dict, Any


class ConfigLoader:
    """Load configuration from multiple sources with priority handling"""

    def __init__(self, config_path: Optional[Path] = None):
        """
        Initialize config loader

        Args:
            config_path: Path to config file (default: auto-detect .seo-geo-config.json)
        """
        if config_path is None:
            # Auto-detect: first check project root, then fallback to home directory
            project_config = Path.cwd() / '.seo-geo-config.json'
            if project_config.exists():
                config_path = project_config
            else:
                # Fallback to legacy location
                config_path = Path.home() / '.seo-geo-skill' / 'config.json'

        self.config_path = config_path
        self._config_cache: Optional[Dict[str, Any]] = None

    def _load_config_file(self) -> Dict[str, Any]:
        """
        Load config from JSON file

        Returns:
            Config dictionary or empty dict if file doesn't exist
        """
        if self._config_cache is not None:
            return self._config_cache

        if not self.config_path.exists():
            self._config_cache = {}
            return self._config_cache

        try:
            with open(self.config_path, 'r', encoding='utf-8') as f:
                self._config_cache = json.load(f)
            return self._config_cache
        except (json.JSONDecodeError, IOError) as e:
            print(f"Warning: Could not load config file {self.config_path}: {e}")
            self._config_cache = {}
            return self._config_cache

    def get(self, section: str, key: str,
            env_var: Optional[str] = None,
            cli_value: Any = None,
            default: Any = None) -> Any:
        """
        Get configuration value with priority handling

        Priority: CLI arg > Environment variable > Config file > Default

        Args:
            section: Config section (e.g., 'sanity', 'image_generation')
            key: Config key within section (e.g., 'project_id', 'api_key')
            env_var: Environment variable name to check
            cli_value: Value from CLI argument (highest priority)
            default: Default value if not found anywhere

        Returns:
            Configuration value from highest priority source
        """
        # Priority 1: CLI argument
        if cli_value is not None:
            return cli_value

        # Priority 2: Environment variable
        if env_var and os.getenv(env_var):
            return os.getenv(env_var)

        # Priority 3: Config file
        config = self._load_config_file()
        if section in config and key in config[section]:
            value = config[section][key]
            # Don't return null/None values from config
            if value is not None:
                return value

        # Priority 4: Default
        return default

    def get_sanity_config(self,
                         project_id: Optional[str] = None,
                         dataset: Optional[str] = None,
                         token: Optional[str] = None) -> Dict[str, Optional[str]]:
        """
        Get Sanity CMS configuration (DEPRECATED — kept for backward compatibility)

        This project uses local markdown files in ../website/src/content/blog/
        as the primary content source. Sanity CMS is no longer used.

        Args:
            project_id: CLI-provided project ID (highest priority)
            dataset: CLI-provided dataset
            token: CLI-provided token

        Returns:
            Dict with keys: project_id, dataset, api_version, token
        """
        return {
            'project_id': self.get('sanity', 'project_id', 'SANITY_PROJECT_ID', project_id),
            'dataset': self.get('sanity', 'dataset', 'SANITY_DATASET', dataset, 'production'),
            'api_version': self.get('sanity', 'api_version', None, None, '2023-05-03'),
            'token': self.get('sanity', 'token', 'SANITY_TOKEN', token)
        }

    def get_google_imagen_config(self,
                                 api_key: Optional[str] = None,
                                 project_id: Optional[str] = None) -> Dict[str, Optional[str]]:
        """
        Get Google Imagen configuration

        Args:
            api_key: Path to service account JSON file (optional, CLI override)
                    If not provided, uses gcloud application-default credentials
            project_id: Google Cloud project ID (required, CLI override)

        Returns:
            Dict with keys: api_key (service account path), project_id
        """
        return {
            'api_key': self.get('image_generation', 'google_api_key', 'GOOGLE_API_KEY', api_key),
            'project_id': self.get('image_generation', 'google_project_id', 'GOOGLE_PROJECT_ID', project_id)
        }

    def get_openai_config(self, api_key: Optional[str] = None) -> Dict[str, Optional[str]]:
        """
        Get OpenAI DALL-E configuration

        Args:
            api_key: CLI-provided API key (highest priority)

        Returns:
            Dict with key: api_key
        """
        return {
            'api_key': self.get('image_generation', 'openai_api_key', 'OPENAI_API_KEY', api_key)
        }

    def get_internal_linking_config(self) -> Dict[str, Any]:
        """
        Get internal linking configuration

        Returns:
            Dict with settings for internal linking
        """
        return {
            'min_confidence_auto_insert': self.get('internal_linking', 'min_confidence_auto_insert', None, None, 90),
            'max_links_per_post': self.get('internal_linking', 'max_links_per_post', None, None, 5),
            'cache_ttl_hours': self.get('internal_linking', 'cache_ttl_hours', None, None, 24),
            'sitemap_url': self.get('content_sources', 'sitemap_url', 'SITEMAP_URL', None),
            'local_markdown_dir': self.get('content_sources', 'local_markdown_dir', 'LOCAL_MARKDOWN_DIR', None)
        }

    def get_validation_config(self) -> Dict[str, Any]:
        """
        Get validation configuration

        Returns:
            Dict with validation settings
        """
        return {
            'target_score': self.get('validation', 'target_score', None, None, 80),
            'max_iterations': self.get('validation', 'max_iterations', None, None, 3)
        }

    def get_image_generation_config(self) -> Dict[str, Any]:
        """
        Get image generation configuration

        Returns:
            Dict with image generation settings
        """
        return {
            'enabled': self.get('image_generation', 'enabled', None, None, False),
            'max_images_per_post': self.get('image_generation', 'max_images_per_post', None, None, 5),
            'output_dir': self.get('image_generation', 'output_dir', None, None, './generated_images')
        }


# Convenience function for quick access
def load_config(config_path: Optional[Path] = None) -> ConfigLoader:
    """
    Create a ConfigLoader instance

    Args:
        config_path: Optional path to config file

    Returns:
        ConfigLoader instance
    """
    return ConfigLoader(config_path)


# Example usage:
if __name__ == "__main__":
    # Test config loading
    config = load_config()

    print("Testing configuration loading...")
    print("\nSanity Config:")
    print(config.get_sanity_config())

    print("\nGoogle Imagen Config:")
    print(config.get_google_imagen_config())

    print("\nOpenAI Config:")
    print(config.get_openai_config())

    print("\nInternal Linking Config:")
    print(config.get_internal_linking_config())

    print("\nImage Generation Config:")
    print(config.get_image_generation_config())
