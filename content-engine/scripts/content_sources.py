#!/usr/bin/env python3
"""
Multi-Source Content Discovery for Internal Linking

Supports (in priority order):
1. Sitemap XML (works in Claude Code containers)
2. Local Markdown files (works in all environments) — default: ../website/src/content/blog/
3. Sanity CMS API (legacy, deprecated — kept for backward compatibility)
4. Fallback to empty list

Implements 24hr caching to minimize API calls and improve performance.
"""

import json
import os
import sys
import requests
import xml.etree.ElementTree as ET
from abc import ABC, abstractmethod
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import List, Optional, Dict
from datetime import datetime, timedelta
from collections import Counter
import hashlib

# Import config loader
try:
    from config_loader import ConfigLoader
except ImportError:
    # Fallback if not in same directory
    sys.path.insert(0, str(Path(__file__).parent))
    from config_loader import ConfigLoader


@dataclass
class ContentItem:
    """Unified content representation across all sources"""
    url: str
    title: str
    excerpt: str
    keywords: List[str]
    published_date: Optional[str]
    source: str  # 'sanity', 'local', 'sitemap', 'gsc'

    def to_dict(self) -> Dict:
        """Convert to dictionary for JSON serialization"""
        return asdict(self)

    @classmethod
    def from_dict(cls, data: Dict) -> 'ContentItem':
        """Create ContentItem from dictionary"""
        return cls(**data)


class ContentSource(ABC):
    """Abstract base class for content sources"""

    @abstractmethod
    def fetch_content(self) -> List[ContentItem]:
        """Fetch all content items from source"""
        pass

    @abstractmethod
    def is_available(self) -> bool:
        """Check if source is configured and accessible"""
        pass


class SanitySource(ContentSource):
    """
    Sanity CMS content source (DEPRECATED — kept for backward compatibility)

    Uses GROQ (Graph-Relational Object Queries) to fetch published posts
    from Sanity headless CMS. This project uses local markdown files
    in ../website/src/content/blog/ as the primary content source.
    """

    def __init__(self,
                 project_id: str = None,
                 dataset: str = None,
                 api_version: str = None,
                 token: str = None,
                 config_path: Path = None):
        """
        Initialize Sanity source

        Args:
            project_id: Sanity project ID (CLI override)
            dataset: Dataset name (CLI override, default: production)
            api_version: API version date (CLI override, default: 2023-05-03)
            token: Optional read token for private datasets (CLI override)
            config_path: Path to .seo-geo-config.json (default: ./seo-geo-config.json)
        """
        # Load from config file with fallbacks
        config = ConfigLoader(config_path)
        sanity_config = config.get_sanity_config(project_id, dataset, token)

        self.project_id = sanity_config['project_id']
        self.dataset = sanity_config['dataset']
        self.api_version = api_version or sanity_config['api_version']
        self.token = sanity_config['token']

        if self.project_id:
            self.base_url = f"https://{self.project_id}.api.sanity.io/v{self.api_version}/data/query/{self.dataset}"
        else:
            self.base_url = None

    def is_available(self) -> bool:
        """Check if Sanity credentials are configured"""
        return bool(self.project_id)

    def fetch_content(self) -> List[ContentItem]:
        """
        Query Sanity for all published blog posts

        GROQ Query:
        *[_type == "post" && !(_id in path("drafts.**"))] {
          "url": slug.current,
          title,
          excerpt,
          "keywords": coalesce(categories[]->title, tags),
          "content": pt::text(body),
          publishedAt
        }
        """
        if not self.is_available():
            raise ValueError("Sanity project ID not configured")

        # GROQ query for published posts
        query = """
        *[_type == "post" && !(_id in path("drafts.**"))] | order(publishedAt desc) {
          "url": slug.current,
          title,
          excerpt,
          "keywords": coalesce(categories[]->title, tags),
          "content": pt::text(body),
          publishedAt,
          _updatedAt
        }
        """

        # Build request
        params = {'query': query.strip()}
        headers = {}

        if self.token:
            headers['Authorization'] = f'Bearer {self.token}'

        try:
            response = requests.get(
                self.base_url,
                params=params,
                headers=headers,
                timeout=10
            )
            response.raise_for_status()
        except requests.RequestException as e:
            print(f"Error fetching from Sanity API: {e}", file=sys.stderr)
            raise

        data = response.json()
        items = []

        for post in data.get('result', []):
            # Extract keywords from content if not in metadata
            keywords = post.get('keywords', [])

            # Handle different keyword formats
            if isinstance(keywords, str):
                keywords = [k.strip() for k in keywords.split(',')]
            elif not keywords and post.get('content'):
                keywords = self._extract_keywords_from_text(post['content'])

            # Build URL
            slug = post.get('url', '')
            url = f"/blog/{slug}" if slug else None

            items.append(ContentItem(
                url=url,
                title=post.get('title', 'Untitled'),
                excerpt=post.get('excerpt', '')[:200],
                keywords=keywords[:10] if keywords else [],  # Limit to top 10
                published_date=post.get('publishedAt'),
                source='sanity'
            ))

        return items

    def _extract_keywords_from_text(self, text: str, limit: int = 10) -> List[str]:
        """
        Extract keyword phrases from text

        Strategy:
        - Find 2-word and 3-word phrases
        - Count frequency
        - Return most common phrases
        """
        if not text:
            return []

        # Clean and tokenize
        words = text.lower().split()
        phrases = []

        # 2-word phrases
        for i in range(len(words) - 1):
            phrase = f"{words[i]} {words[i+1]}"
            if len(phrase) > 6:  # Filter very short phrases
                phrases.append(phrase)

        # 3-word phrases (more specific)
        for i in range(len(words) - 2):
            phrase = f"{words[i]} {words[i+1]} {words[i+2]}"
            if len(phrase) > 10:
                phrases.append(phrase)

        # Count frequency and return top phrases
        counter = Counter(phrases)
        return [phrase for phrase, count in counter.most_common(limit) if count >= 2]


class LocalMarkdownSource(ContentSource):
    """
    Local markdown files content source

    Scans directory for .md files and extracts:
    - Frontmatter metadata (YAML between --- markers)
    - H1 title
    - Content excerpt
    - Keywords from tags or content
    """

    def __init__(self, content_dir: Path):
        """
        Initialize local markdown source

        Args:
            content_dir: Directory containing markdown files
        """
        self.content_dir = Path(content_dir)

    def is_available(self) -> bool:
        """Check if content directory exists"""
        return self.content_dir.exists() and self.content_dir.is_dir()

    def fetch_content(self) -> List[ContentItem]:
        """Read all markdown files from directory"""
        if not self.is_available():
            raise ValueError(f"Content directory not found: {self.content_dir}")

        items = []

        # Recursively find all .md files
        for md_file in self.content_dir.rglob('*.md'):
            # Skip README and other meta files
            if md_file.name.upper() in ['README.MD', 'LICENSE.MD', 'CONTRIBUTING.MD']:
                continue

            item = self._parse_markdown_file(md_file)
            if item:
                items.append(item)

        return items

    def _parse_markdown_file(self, file_path: Path) -> Optional[ContentItem]:
        """
        Parse markdown file with frontmatter

        Supports YAML frontmatter format:
        ---
        title: Post Title
        date: 2025-01-15
        tags: tag1, tag2
        description: Brief description
        ---

        # Content starts here
        """
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                content = f.read()

            # Extract frontmatter (YAML between --- markers)
            import re
            frontmatter_match = re.match(r'^---\s*\n(.*?)\n---\s*\n(.*)$', content, re.DOTALL)

            if frontmatter_match:
                frontmatter_text = frontmatter_match.group(1)
                body = frontmatter_match.group(2)

                # Simple YAML parsing (key: value format)
                metadata = {}
                for line in frontmatter_text.split('\n'):
                    if ':' in line:
                        key, value = line.split(':', 1)
                        metadata[key.strip()] = value.strip().strip('"\'')

                title = metadata.get('title', file_path.stem)
                excerpt = metadata.get('description', '') or body[:200]
                published_date = metadata.get('date') or metadata.get('publishedAt')

                # Handle tags
                tags_str = metadata.get('tags', '')
                keywords = [t.strip() for t in tags_str.split(',')] if tags_str else []
            else:
                # No frontmatter, extract from content
                title_match = re.search(r'^# (.+)$', content, re.MULTILINE)
                title = title_match.group(1) if title_match else file_path.stem
                body = content
                excerpt = content[:200]
                published_date = None
                keywords = []

            # Generate URL from filename
            url = f"/blog/{file_path.stem.replace('_', '-')}"

            # Extract keywords if not in frontmatter
            if not keywords:
                keywords = self._extract_keywords_from_content(body)

            return ContentItem(
                url=url,
                title=title,
                excerpt=excerpt,
                keywords=keywords[:10],
                published_date=published_date,
                source='local'
            )

        except Exception as e:
            print(f"Warning: Failed to parse {file_path}: {e}", file=sys.stderr)
            return None

    def _extract_keywords_from_content(self, content: str) -> List[str]:
        """Extract keywords from markdown content"""
        import re

        # Remove markdown formatting
        text = re.sub(r'#{1,6}\s+', '', content)  # Remove headers
        text = re.sub(r'\[.+?\]\(.+?\)', '', text)  # Remove links
        text = re.sub(r'[*_`]', '', text)  # Remove formatting
        text = re.sub(r'```.*?```', '', text, flags=re.DOTALL)  # Remove code blocks

        # Extract 2-word phrases
        words = text.lower().split()
        phrases = []

        for i in range(len(words) - 1):
            phrase = f"{words[i]} {words[i+1]}"
            if len(phrase) > 6:
                phrases.append(phrase)

        # Count frequency and return common phrases
        counter = Counter(phrases)
        return [phrase for phrase, count in counter.most_common(10) if count >= 2]


class SitemapSource(ContentSource):
    """
    Sitemap XML content source

    Fetches and parses XML sitemap to discover published content.
    Works well in containerized environments (Claude Code) since
    sitemaps are typically publicly accessible.
    """

    def __init__(self, sitemap_url: str = None, config_path: Path = None):
        """
        Initialize sitemap source

        Args:
            sitemap_url: URL to sitemap.xml (CLI override)
            config_path: Path to .seo-geo-config.json (default: ./seo-geo-config.json)
        """
        # Load from config file with fallback
        config = ConfigLoader(config_path)
        linking_config = config.get_internal_linking_config()

        self.sitemap_url = sitemap_url or linking_config.get('sitemap_url')

    def is_available(self) -> bool:
        """Check if sitemap URL is configured"""
        return bool(self.sitemap_url)

    def fetch_content(self) -> List[ContentItem]:
        """
        Parse sitemap XML to extract content URLs

        Supports both standard sitemap format and sitemap index.
        Extracts: URL, last modified date
        """
        if not self.is_available():
            raise ValueError("Sitemap URL not configured")

        try:
            response = requests.get(self.sitemap_url, timeout=10)
            response.raise_for_status()
        except requests.RequestException as e:
            print(f"Error fetching sitemap from {self.sitemap_url}: {e}", file=sys.stderr)
            raise

        items = []

        # Parse XML
        try:
            root = ET.fromstring(response.content)
        except ET.ParseError as e:
            print(f"Error parsing sitemap XML: {e}", file=sys.stderr)
            raise

        # Handle both sitemap and sitemapindex formats
        # Namespace handling for sitemap.org schema
        ns = {'ns': 'http://www.sitemaps.org/schemas/sitemap/0.9'}

        # Check if this is a sitemap index
        sitemaps = root.findall('ns:sitemap', ns)
        if sitemaps:
            # This is a sitemap index, recursively fetch child sitemaps
            for sitemap in sitemaps:
                loc = sitemap.find('ns:loc', ns)
                if loc is not None:
                    try:
                        items.extend(self._fetch_sitemap(loc.text, ns))
                    except Exception as e:
                        print(f"Warning: Failed to fetch child sitemap {loc.text}: {e}", file=sys.stderr)
                        continue
        else:
            # This is a regular sitemap
            items = self._fetch_sitemap(self.sitemap_url, ns, root=root)

        return items

    def _fetch_sitemap(self, url: str, ns: dict, root: ET.Element = None) -> List[ContentItem]:
        """
        Fetch and parse a single sitemap

        Args:
            url: Sitemap URL
            ns: XML namespace dict
            root: Pre-parsed XML root (optional, if already fetched)

        Returns:
            List of ContentItems
        """
        if root is None:
            try:
                response = requests.get(url, timeout=10)
                response.raise_for_status()
                root = ET.fromstring(response.content)
            except (requests.RequestException, ET.ParseError) as e:
                print(f"Error fetching/parsing sitemap {url}: {e}", file=sys.stderr)
                return []

        items = []
        urls = root.findall('ns:url', ns)

        for url_elem in urls:
            loc = url_elem.find('ns:loc', ns)
            if loc is None:
                continue

            url_text = loc.text

            # Extract lastmod if available
            lastmod = url_elem.find('ns:lastmod', ns)
            published_date = lastmod.text if lastmod is not None else None

            # Extract title from URL slug (best effort)
            from urllib.parse import urlparse
            parsed = urlparse(url_text)
            path_parts = [p for p in parsed.path.strip('/').split('/') if p]  # Filter empty parts

            # Skip non-article pages (homepage, paginated lists, etc.)
            # Only include pages with meaningful slugs (typically 2+ path segments for /blog/article-name)
            if not path_parts:
                # Homepage or root - skip for internal linking
                continue

            # Get the last meaningful segment as the slug
            slug = path_parts[-1]

            # Skip pagination and category pages
            if parsed.query or slug in ['blog', 'pricing', 'privacy', 'terms', 'about', 'contact']:
                # Skip: query params (pagination), generic pages (not articles)
                continue

            # Convert slug to title (replace hyphens/underscores with spaces, title case)
            title = slug.replace('-', ' ').replace('_', ' ').title()

            items.append(ContentItem(
                url=parsed.path,  # Use path only (relative URL)
                title=title,
                excerpt=f"Content from {url_text}",
                keywords=[],  # Sitemaps don't contain keywords
                published_date=published_date,
                source='sitemap'
            ))

        return items


class ContentCache:
    """
    Cache content items to avoid repeated API calls

    Features:
    - 24 hour TTL (time-to-live)
    - JSON storage in user's home directory
    - Automatic cache invalidation
    """

    def __init__(self, cache_dir: Path = None, ttl_hours: int = 24):
        """
        Initialize content cache

        Args:
            cache_dir: Directory for cache files (default: ~/.seo-geo-blog-writer/content-cache)
            ttl_hours: Time-to-live in hours (default: 24)
        """
        self.cache_dir = cache_dir or Path.home() / '.seo-geo-blog-writer' / 'content-cache'
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.ttl_hours = ttl_hours

    def get(self, source_key: str) -> Optional[List[ContentItem]]:
        """
        Get cached content if valid

        Args:
            source_key: Unique identifier for content source

        Returns:
            List of ContentItems if cache valid, None otherwise
        """
        cache_file = self.cache_dir / f"{self._hash_key(source_key)}.json"

        if not cache_file.exists():
            return None

        # Check age
        file_age = datetime.now() - datetime.fromtimestamp(cache_file.stat().st_mtime)
        if file_age > timedelta(hours=self.ttl_hours):
            cache_file.unlink()  # Delete expired cache
            return None

        # Load cache
        try:
            with open(cache_file, 'r', encoding='utf-8') as f:
                data = json.load(f)

            return [ContentItem.from_dict(item) for item in data]
        except (json.JSONDecodeError, KeyError, TypeError) as e:
            print(f"Warning: Failed to load cache: {e}", file=sys.stderr)
            cache_file.unlink()  # Delete corrupted cache
            return None

    def set(self, source_key: str, items: List[ContentItem]):
        """
        Cache content items

        Args:
            source_key: Unique identifier for content source
            items: List of ContentItems to cache
        """
        cache_file = self.cache_dir / f"{self._hash_key(source_key)}.json"

        try:
            with open(cache_file, 'w', encoding='utf-8') as f:
                json.dump([item.to_dict() for item in items], f, indent=2)
        except Exception as e:
            print(f"Warning: Failed to write cache: {e}", file=sys.stderr)

    def clear(self):
        """Clear all cached content"""
        for cache_file in self.cache_dir.glob('*.json'):
            cache_file.unlink()

    def _hash_key(self, key: str) -> str:
        """Generate cache filename from key"""
        return hashlib.md5(key.encode()).hexdigest()


class ContentDiscovery:
    """
    Auto-detect and fetch content from available sources

    Priority order (first available source wins):
    1. Sitemap (if configured) - Best for Claude Code containers
    2. Local markdown (default: ../website/src/content/blog/) - Works in all environments
    3. Sanity CMS (deprecated, kept for backward compatibility)
    4. Fallback: empty list
    """

    def __init__(self,
                 sitemap_url: str = None,
                 sanity_project_id: str = None,
                 sanity_dataset: str = None,
                 sanity_token: str = None,
                 local_content_dir: Path = None,
                 cache_ttl_hours: int = None,
                 config_path: Path = None):
        """
        Initialize content discovery

        Args:
            sitemap_url: URL to sitemap.xml (CLI override)
            sanity_project_id: Sanity project ID (deprecated, CLI override)
            sanity_dataset: Sanity dataset name (deprecated, CLI override)
            sanity_token: Optional Sanity read token (deprecated, CLI override)
            local_content_dir: Local markdown directory (CLI override, default: ../website/src/content/blog/)
            cache_ttl_hours: Cache time-to-live in hours (CLI override)
            config_path: Path to .seo-geo-config.json
        """
        # Load config
        config = ConfigLoader(config_path)
        linking_config = config.get_internal_linking_config()

        self.sources = []
        ttl = cache_ttl_hours if cache_ttl_hours is not None else linking_config['cache_ttl_hours']
        self.cache = ContentCache(ttl_hours=ttl)

        # Priority 1: Sitemap source (works in containers)
        sitemap_source = SitemapSource(
            sitemap_url=sitemap_url,
            config_path=config_path
        )
        if sitemap_source.is_available():
            self.sources.append(sitemap_source)

        # Priority 2: Local markdown source
        local_dir = local_content_dir or linking_config['local_markdown_dir']
        if local_dir:
            local_source = LocalMarkdownSource(Path(local_dir))
            if local_source.is_available():
                self.sources.append(local_source)

        # Priority 3: Sanity source (deprecated — kept for backward compatibility)
        sanity_source = SanitySource(
            project_id=sanity_project_id,
            dataset=sanity_dataset,
            token=sanity_token,
            config_path=config_path
        )
        if sanity_source.is_available():
            self.sources.append(sanity_source)

    def discover_content(self, use_cache: bool = True) -> List[ContentItem]:
        """
        Discover content from available sources

        Priority (first available source wins):
        1. Sitemap (if configured) - Best for Claude Code containers
        2. Local markdown (default: ../website/src/content/blog/) - Works in all environments
        3. Sanity CMS (deprecated, kept for backward compatibility)
        4. Fallback: empty list

        Args:
            use_cache: Use cached results if available

        Returns:
            List of ContentItems from first available source
        """
        for source in self.sources:
            if not source.is_available():
                continue

            source_key = f"{source.__class__.__name__}_{getattr(source, 'project_id', 'local')}"

            # Try cache first
            if use_cache:
                cached = self.cache.get(source_key)
                if cached:
                    print(f"✓ Using cached content from {source.__class__.__name__} ({len(cached)} items)", file=sys.stderr)
                    return cached

            # Fetch fresh content
            try:
                items = source.fetch_content()
                print(f"✓ Fetched {len(items)} items from {source.__class__.__name__}", file=sys.stderr)

                # Cache results
                if use_cache:
                    self.cache.set(source_key, items)

                return items

            except Exception as e:
                print(f"Warning: Failed to fetch from {source.__class__.__name__}: {e}", file=sys.stderr)
                continue

        print("Warning: No content sources available", file=sys.stderr)
        return []


def main():
    """CLI for testing content discovery"""
    import argparse

    parser = argparse.ArgumentParser(description="Discover content for internal linking")
    parser.add_argument("--sitemap-url", help="URL to sitemap.xml (priority 1)")
    parser.add_argument("--sanity-project-id", help="Sanity project ID (priority 3)")
    parser.add_argument("--sanity-dataset", default="production", help="Sanity dataset")
    parser.add_argument("--sanity-token", help="Sanity read token (for private datasets)")
    parser.add_argument("--local-content", type=Path, help="Local markdown directory (priority 2)")
    parser.add_argument("--no-cache", action="store_true", help="Skip cache")
    parser.add_argument("--clear-cache", action="store_true", help="Clear cache and exit")
    parser.add_argument("--format", choices=['json', 'summary'], default='summary', help="Output format")

    args = parser.parse_args()

    # Handle cache clearing
    if args.clear_cache:
        cache = ContentCache()
        cache.clear()
        print("✓ Cache cleared")
        return

    # Initialize discovery
    discovery = ContentDiscovery(
        sitemap_url=args.sitemap_url,
        sanity_project_id=args.sanity_project_id,
        sanity_dataset=args.sanity_dataset,
        sanity_token=args.sanity_token,
        local_content_dir=args.local_content,
    )

    # Discover content
    items = discovery.discover_content(use_cache=not args.no_cache)

    # Output
    if args.format == 'json':
        print(json.dumps([item.to_dict() for item in items], indent=2))
    else:
        print(f"\n✓ Discovered {len(items)} content items\n")
        for i, item in enumerate(items[:10], 1):
            print(f"{i}. {item.title}")
            print(f"   URL: {item.url}")
            print(f"   Keywords: {', '.join(item.keywords[:5])}")
            print(f"   Source: {item.source}")
            if item.published_date:
                print(f"   Published: {item.published_date}")
            print()

        if len(items) > 10:
            print(f"... and {len(items) - 10} more")


if __name__ == "__main__":
    main()
