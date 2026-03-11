#!/usr/bin/env python3
"""
Keyword Research Tool for SEO-GEO Blog Writer
Wrapper for DataForSEO API with graceful fallback

Uses DataForSEO v3 API:
- Endpoint: /v3/keywords_data/google_ads/search_volume/live
- Documentation: https://docs.dataforseo.com/v3/keywords_data/google_ads/search_volume/live
- Returns: search_volume, competition, competition_index, cpc, monthly_searches

Note: For related keywords, consider using:
- /v3/keywords_data/google_ads/keywords_for_keywords/live
- /v3/keywords_data/google_ads/keywords_for_keywords/task_post

Usage:
    python keyword_research.py "empath boundaries" --limit 5
    python keyword_research.py "healthy boundaries" --api-key YOUR_KEY
    python keyword_research.py "topic" --interactive  # Prompt for credentials
    
Credential Management (tries in order):
    1. --api-key command line argument
    2. DATAFORSEO_API_KEY environment variable
    3. ~/.dataforseo-skill/config.json config file
    4. --interactive flag (prompts user)
    
See scripts/CREDENTIALS.md for details.
"""

import argparse
import base64
import hashlib
import json
import os
import sys
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, List, Optional
from dataclasses import dataclass, asdict
try:
    import getpass
except ImportError:
    getpass = None

# Cache configuration
CACHE_DIR = Path.home() / '.dataforseo-skill' / 'cache'
CACHE_TTL_DAYS = 30  # Cache keyword research for 30 days


class KeywordResearchError(Exception):
    """Custom exception for keyword research failures with helpful context"""
    pass


@dataclass
class KeywordData:
    """Structured keyword research data"""
    keyword: str
    search_volume: int
    keyword_difficulty: int
    related_keywords: List[str]
    relevance_score: float  # 0-100
    
    def to_dict(self) -> Dict:
        return asdict(self)


def decode_base64_credentials(encoded: str) -> Optional[str]:
    """
    Decode Base64-encoded credentials from DataForSEO.
    
    DataForSEO provides credentials in Base64 format. This function detects
    and decodes them automatically.
    
    Args:
        encoded: Base64-encoded credential string
        
    Returns:
        Decoded credential string (login:password format) or None if invalid
    """
    if not encoded or not encoded.strip():
        return None
    
    encoded = encoded.strip()
    
    # Try to decode Base64
    try:
        decoded_bytes = base64.b64decode(encoded, validate=True)
        decoded = decoded_bytes.decode('utf-8')
        
        # Verify it's in the expected format (contains ':')
        if ':' in decoded:
            return decoded
        else:
            # Decoded but not in expected format - might be plain text Base64
            # Return as-is and let the API handle it
            return decoded
    except Exception:
        # Not valid Base64, return as-is (might be plain text)
        return encoded


def _ensure_cache_dir():
    """Create cache directory if it doesn't exist"""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)


def _get_cache_key(topic: str, limit: int) -> str:
    """Generate cache key from topic and limit"""
    cache_input = f"{topic.lower().strip()}_{limit}"
    return hashlib.md5(cache_input.encode()).hexdigest()


def get_cached_keywords(topic: str, limit: int) -> Optional[List['KeywordData']]:
    """
    Retrieve cached keyword research if available and fresh.

    Args:
        topic: The topic/keyword seed
        limit: Number of results requested

    Returns:
        Cached KeywordData list or None if cache miss/expired
    """
    try:
        _ensure_cache_dir()
        cache_key = _get_cache_key(topic, limit)
        cache_file = CACHE_DIR / f"{cache_key}.json"

        if not cache_file.exists():
            return None

        # Load cached data
        with open(cache_file, 'r', encoding='utf-8') as f:
            data = json.load(f)

        # Check if cache is still valid
        cached_at = datetime.fromisoformat(data['timestamp'])
        cache_age = datetime.now() - cached_at

        if cache_age > timedelta(days=CACHE_TTL_DAYS):
            # Cache expired
            cache_file.unlink()  # Delete expired cache
            return None

        # Reconstruct KeywordData objects
        keywords = [KeywordData(**kw) for kw in data['keywords']]

        # Print cache hit info to stderr (not interfering with output)
        print(f"✓ Cache hit for '{topic}' (age: {cache_age.days} days)", file=sys.stderr)

        return keywords

    except (json.JSONDecodeError, KeyError, ValueError, IOError) as e:
        # If cache is corrupted, ignore it
        print(f"Warning: Cache read failed ({e}), will fetch fresh data", file=sys.stderr)
        return None


def save_keywords_to_cache(topic: str, limit: int, keywords: List['KeywordData']):
    """
    Save keyword research results to cache.

    Args:
        topic: The topic/keyword seed
        limit: Number of results
        keywords: KeywordData list to cache
    """
    try:
        _ensure_cache_dir()
        cache_key = _get_cache_key(topic, limit)
        cache_file = CACHE_DIR / f"{cache_key}.json"

        # Prepare cache data
        cache_data = {
            'timestamp': datetime.now().isoformat(),
            'topic': topic,
            'limit': limit,
            'keywords': [kw.to_dict() for kw in keywords]
        }

        # Write to cache
        with open(cache_file, 'w', encoding='utf-8') as f:
            json.dump(cache_data, f, indent=2)

        print(f"✓ Cached results for '{topic}'", file=sys.stderr)

    except IOError as e:
        # Cache write failure is not critical - just log and continue
        print(f"Warning: Could not write to cache ({e})", file=sys.stderr)


def get_api_key(api_key: Optional[str] = None, interactive: bool = False) -> Optional[str]:
    """
    Hybrid credential management following Claude Skills best practices.

    Tries multiple methods in order:
    1. Explicitly provided API key (command line argument)
    2. Environment variable (DATAFORSEO_API_KEY)
    3. Project-local config file (.seo-geo-config.json) - works in containers
    4. User home config file (~/.dataforseo-skill/config.json)
    5. Interactive prompt (if interactive=True)

    Automatically detects and decodes Base64-encoded credentials from DataForSEO.

    Based on: https://medium.com/ducky-ai/the-credential-conundrum-managing-api-keys-in-claude-skills-430c41b21aa8

    Args:
        api_key: Explicitly provided API key (highest priority)
                 Can be plain text (login:password) or Base64-encoded
        interactive: Whether to prompt user if no credentials found

    Returns:
        API key string in login:password format, or None if not found
    """
    # Method 1: Explicitly provided (command line argument)
    if api_key:
        return decode_base64_credentials(api_key)

    # Method 2: Environment variable
    api_key = os.getenv('DATAFORSEO_API_KEY')
    if api_key:
        return decode_base64_credentials(api_key)

    # Method 3: Project-local config file (works in containers)
    # Check current directory and parent directories up to 3 levels
    current_dir = Path.cwd()
    for _ in range(3):
        project_config = current_dir / '.seo-geo-config.json'
        if project_config.exists():
            try:
                with open(project_config, 'r') as f:
                    config = json.load(f)
                    # Look for api_key in dataforseo section
                    api_key = config.get('dataforseo', {}).get('api_key')
                    if api_key:
                        return decode_base64_credentials(api_key)
            except (json.JSONDecodeError, IOError) as e:
                print(f"Warning: Could not read project config file ({e})", file=sys.stderr)
        # Move up one directory
        if current_dir.parent == current_dir:
            break
        current_dir = current_dir.parent

    # Method 4: User home config file
    config_path = Path.home() / '.dataforseo-skill' / 'config.json'
    if config_path.exists():
        try:
            with open(config_path, 'r') as f:
                config = json.load(f)
                api_key = config.get('api_key')
                if api_key:
                    return decode_base64_credentials(api_key)
        except (json.JSONDecodeError, IOError) as e:
            print(f"Warning: Could not read home config file ({e})", file=sys.stderr)

    # Method 5: Interactive prompt (if enabled and available)
    if interactive and getpass:
        try:
            print("DataForSEO API key not found in environment or config file.", file=sys.stderr)
            print("Enter your DataForSEO API key:", file=sys.stderr)
            print("  - Plain text format: login:password", file=sys.stderr)
            print("  - Base64 format: [base64-encoded string]", file=sys.stderr)
            print("(Press Ctrl+C to cancel and use fallback mode)", file=sys.stderr)
            api_key = getpass.getpass("API Key: ")
            if api_key and api_key.strip():
                return decode_base64_credentials(api_key.strip())
        except (KeyboardInterrupt, EOFError):
            print("\nCancelled. Using fallback mode.", file=sys.stderr)

    return None


class KeywordResearcher:
    """Keyword research with DataForSEO API integration"""
    
    def __init__(self, api_key: Optional[str] = None, interactive: bool = False):
        """
        Initialize keyword researcher with hybrid credential management.
        
        Args:
            api_key: Explicitly provided API key (optional)
            interactive: Whether to prompt for credentials if not found (default: False)
        """
        self.api_key = get_api_key(api_key, interactive=interactive)
        self.api_available = bool(self.api_key)
        
    def research_keywords(self, topic: str, limit: int = 5) -> List[KeywordData]:
        """
        Research keywords for a given topic with caching support.

        Args:
            topic: The topic/keyword seed to research
            limit: Maximum number of keyword suggestions to return

        Returns:
            List of KeywordData objects sorted by relevance score
        """
        # Check cache first
        cached_results = get_cached_keywords(topic, limit)
        if cached_results:
            return cached_results

        # Cache miss - fetch fresh data
        if self.api_available:
            keywords = self._api_research(topic, limit)
        else:
            keywords = self._fallback_research(topic, limit)

        # Save to cache for future use
        if keywords:
            save_keywords_to_cache(topic, limit, keywords)

        return keywords
    
    def _api_research(self, topic: str, limit: int) -> List[KeywordData]:
        """
        Call DataForSEO API for keyword research

        Uses the Google Ads Search Volume Live endpoint which returns immediate results.
        API Documentation: https://docs.dataforseo.com/v3/keywords_data/google_ads/search_volume/live
        """
        try:
            # Import requests only if API is available
            import requests
            from requests.auth import HTTPBasicAuth

            # DataForSEO API endpoint - Live endpoint returns immediate results
            url = "https://api.dataforseo.com/v3/keywords_data/google_ads/search_volume/live"

            # Parse credentials (format: "login:password")
            login, password = self.api_key.split(':')

            # Generate keyword variations to get metrics for multiple options
            variations = self._generate_variations(topic)

            # Prepare request according to DataForSEO v3 API specification
            # Live endpoint expects array of request objects
            # Send more variations than limit to have options after sorting
            payload = [{
                "keywords": variations[:limit * 2],  # Get metrics for multiple variations
                "location_code": 2840,  # USA (can also use location_name: "United States")
                "language_code": "en",   # English (can also use language_name: "English")
                # Note: search_partners, date_from, date_to are not valid for /live endpoint
            }]
            
            response = requests.post(
                url,
                json=payload,
                auth=HTTPBasicAuth(login, password),
                timeout=30,
                headers={
                    "Content-Type": "application/json"
                }
            )
            
            response.raise_for_status()
            data = response.json()
            
            # Debug: Print response structure (can be disabled)
            if os.getenv('DEBUG_API_RESPONSE'):
                print(f"DEBUG: API Response structure:", file=sys.stderr)
                print(f"DEBUG: Keys: {list(data.keys())}", file=sys.stderr)
                if 'tasks' in data:
                    print(f"DEBUG: Tasks count: {len(data.get('tasks', []))}", file=sys.stderr)
                    for i, task in enumerate(data.get('tasks', [])):
                        print(f"DEBUG: Task {i} keys: {list(task.keys())}", file=sys.stderr)
                        print(f"DEBUG: Task {i} status_code: {task.get('status_code')}", file=sys.stderr)
                        if 'result' in task:
                            print(f"DEBUG: Task {i} result type: {type(task.get('result'))}", file=sys.stderr)
                            print(f"DEBUG: Task {i} result length: {len(task.get('result', []))}", file=sys.stderr)
                            if task.get('result'):
                                print(f"DEBUG: Task {i} first result keys: {list(task.get('result', [{}])[0].keys())}", file=sys.stderr)
                print("", file=sys.stderr)
            
            # Parse API response
            keywords = self._parse_api_response(data, topic, limit)
            return keywords
            
        except ImportError:
            print("=" * 60, file=sys.stderr)
            print("ERROR: Required 'requests' library not installed", file=sys.stderr)
            print("=" * 60, file=sys.stderr)
            print("\nTo fix this issue:", file=sys.stderr)
            print("  pip install requests", file=sys.stderr)
            print("\nOr install all dependencies:", file=sys.stderr)
            print("  pip install -r requirements.txt", file=sys.stderr)
            print("\nFalling back to heuristic mode (limited functionality).", file=sys.stderr)
            print("=" * 60 + "\n", file=sys.stderr)
            return self._fallback_research(topic, limit)
        except requests.exceptions.Timeout:
            print("=" * 60, file=sys.stderr)
            print("ERROR: API Request Timeout (>30 seconds)", file=sys.stderr)
            print("=" * 60, file=sys.stderr)
            print("\nPossible causes:", file=sys.stderr)
            print("  • Slow internet connection", file=sys.stderr)
            print("  • DataForSEO API experiencing delays", file=sys.stderr)
            print("\nSolutions:", file=sys.stderr)
            print("  1. Check your internet connection", file=sys.stderr)
            print("  2. Try again in a few moments", file=sys.stderr)
            print("  3. Use fallback mode (automatic - no action needed)", file=sys.stderr)
            print("\nFalling back to heuristic mode.", file=sys.stderr)
            print("=" * 60 + "\n", file=sys.stderr)
            return self._fallback_research(topic, limit)
        except requests.exceptions.HTTPError as e:
            status_code = e.response.status_code if e.response else None

            if status_code == 401:
                print("=" * 60, file=sys.stderr)
                print("ERROR: Invalid API Credentials (401 Unauthorized)", file=sys.stderr)
                print("=" * 60, file=sys.stderr)
                print("\nYour API credentials are incorrect or expired.", file=sys.stderr)
                print("\nChecklist:", file=sys.stderr)
                print("  1. Verify format: 'login:password' (colon-separated)", file=sys.stderr)
                print("  2. Check credentials in DataForSEO dashboard:", file=sys.stderr)
                print("     https://app.dataforseo.com/", file=sys.stderr)
                print("  3. Ensure account is active (not expired trial)", file=sys.stderr)
                print("  4. Verify no extra spaces in credential string", file=sys.stderr)
                print("\nCurrent credential source:", file=sys.stderr)
                if os.getenv('DATAFORSEO_API_KEY'):
                    print("  → Environment variable (DATAFORSEO_API_KEY)", file=sys.stderr)
                else:
                    print("  → Config file or command line", file=sys.stderr)
                print("\nFalling back to heuristic mode.", file=sys.stderr)
                print("=" * 60 + "\n", file=sys.stderr)
            elif status_code == 429:
                print("=" * 60, file=sys.stderr)
                print("ERROR: API Rate Limit Exceeded (429)", file=sys.stderr)
                print("=" * 60, file=sys.stderr)
                print("\nYou've made too many requests to the API.", file=sys.stderr)
                print("\nSolutions:", file=sys.stderr)
                print("  1. Wait a few minutes before trying again", file=sys.stderr)
                print("  2. Check your DataForSEO plan limits", file=sys.stderr)
                print("  3. Cached results will be used for repeated queries", file=sys.stderr)
                print("\nFalling back to heuristic mode.", file=sys.stderr)
                print("=" * 60 + "\n", file=sys.stderr)
            elif status_code == 402:
                print("=" * 60, file=sys.stderr)
                print("ERROR: Insufficient API Credits (402 Payment Required)", file=sys.stderr)
                print("=" * 60, file=sys.stderr)
                print("\nYour DataForSEO account has insufficient credits.", file=sys.stderr)
                print("\nActions:", file=sys.stderr)
                print("  1. Add credits to your account:", file=sys.stderr)
                print("     https://app.dataforseo.com/billing", file=sys.stderr)
                print("  2. Check your current balance in the dashboard", file=sys.stderr)
                print("\nFalling back to heuristic mode.", file=sys.stderr)
                print("=" * 60 + "\n", file=sys.stderr)
            else:
                print("=" * 60, file=sys.stderr)
                print(f"ERROR: API HTTP Error ({status_code})", file=sys.stderr)
                print("=" * 60, file=sys.stderr)
                print(f"\nHTTP Status: {status_code}", file=sys.stderr)
                print(f"Error: {e}", file=sys.stderr)
                print("\nFalling back to heuristic mode.", file=sys.stderr)
                print("=" * 60 + "\n", file=sys.stderr)

            return self._fallback_research(topic, limit)
        except requests.exceptions.ConnectionError:
            print("=" * 60, file=sys.stderr)
            print("ERROR: Network Connection Failed", file=sys.stderr)
            print("=" * 60, file=sys.stderr)
            print("\nCannot connect to DataForSEO API.", file=sys.stderr)
            print("\nChecklist:", file=sys.stderr)
            print("  1. Check your internet connection", file=sys.stderr)
            print("  2. Verify you can access: https://api.dataforseo.com", file=sys.stderr)
            print("  3. Check if a firewall is blocking outbound HTTPS", file=sys.stderr)
            print("  4. Try disabling VPN if you're using one", file=sys.stderr)
            print("\nFalling back to heuristic mode.", file=sys.stderr)
            print("=" * 60 + "\n", file=sys.stderr)
            return self._fallback_research(topic, limit)
        except ValueError as e:
            if "split" in str(e) or ":" in str(e):
                print("=" * 60, file=sys.stderr)
                print("ERROR: Invalid API Key Format", file=sys.stderr)
                print("=" * 60, file=sys.stderr)
                print("\nAPI key must be in format: 'login:password'", file=sys.stderr)
                print(f"Error details: {e}", file=sys.stderr)
                print("\nExamples of correct format:", file=sys.stderr)
                print("  user@example.com:mypassword123", file=sys.stderr)
                print("  username:SecureP@ssw0rd", file=sys.stderr)
                print("\nFalling back to heuristic mode.", file=sys.stderr)
                print("=" * 60 + "\n", file=sys.stderr)
            else:
                print(f"Warning: Value error ({e}). Using fallback.", file=sys.stderr)
            return self._fallback_research(topic, limit)
        except Exception as e:
            print("=" * 60, file=sys.stderr)
            print("ERROR: Unexpected API Failure", file=sys.stderr)
            print("=" * 60, file=sys.stderr)
            print(f"\nError: {type(e).__name__}: {e}", file=sys.stderr)
            print("\nThis is an unexpected error. Please report if it persists.", file=sys.stderr)
            print("\nFalling back to heuristic mode.", file=sys.stderr)
            print("=" * 60 + "\n", file=sys.stderr)
            return self._fallback_research(topic, limit)
    
    def _parse_api_response(self, data: Dict, topic: str, limit: int) -> List[KeywordData]:
        """
        Parse DataForSEO API response into KeywordData objects
        
        Response structure for /live endpoint:
        {
            "status_code": 200,
            "status_message": "OK.",
            "time_taken": 0.123,
            "tasks": [{
                "id": "...",
                "status_code": 20000,
                "status_message": "Ok.",
                "time_taken": 0.123,
                "result": [{
                    "keyword": "...",
                    "search_volume": 1000,
                    "competition": "HIGH|MEDIUM|LOW",
                    "competition_index": 0-100,
                    "cpc": 1.23,
                    "monthly_searches": [...],
                    ...
                }]
            }]
        }
        """
        keywords = []
        
        try:
            # Check HTTP status code
            # DataForSEO API returns 20000 for success (not HTTP 200)
            http_status = data.get('status_code')
            if http_status not in [200, 20000]:
                print(f"Warning: API returned status {http_status}: {data.get('status_message', 'Unknown error')}", file=sys.stderr)
                # Don't return early - might still have data in tasks
            
            # Extract keyword data from API response
            # Live endpoint returns tasks array with results
            tasks = data.get('tasks', [])
            
            if not tasks:
                print(f"Warning: No tasks found in API response", file=sys.stderr)
                return keywords
            
            for task in tasks:
                # Check task-level status (20000 = success)
                task_status = task.get('status_code')
                if task_status != 20000:
                    status_msg = task.get('status_message', 'Unknown error')
                    print(f"Warning: Task failed with status {task_status}: {status_msg}", file=sys.stderr)
                    continue
                
                # Extract results from task
                # Note: result might be a list or a single object
                result = task.get('result', [])
                
                # Handle different response structures
                if isinstance(result, list):
                    results = result
                elif isinstance(result, dict):
                    # Single result object
                    results = [result]
                else:
                    # Empty or unexpected format
                    results = []
                
                if not results:
                    print(f"Warning: Task succeeded but no results found. Task keys: {list(task.keys())}", file=sys.stderr)
                    continue
                
                for item in results[:limit]:
                    # Handle case where item might be None or empty
                    if not item or not isinstance(item, dict):
                        continue
                    
                    keyword_data = KeywordData(
                        keyword=item.get('keyword', topic),
                        search_volume=item.get('search_volume') or 0,
                        keyword_difficulty=self._calculate_difficulty(item),
                        related_keywords=self._extract_related(item),
                        relevance_score=self._calculate_relevance(item, topic)
                    )
                    keywords.append(keyword_data)
                
                # Only process first task (should only be one for live endpoint)
                break
            
            # Sort by relevance score
            keywords.sort(key=lambda x: x.relevance_score, reverse=True)
            
        except Exception as e:
            print(f"Warning: Failed to parse API response ({e})", file=sys.stderr)
            import traceback
            print(f"Traceback: {traceback.format_exc()}", file=sys.stderr)
        
        return keywords
    
    def _calculate_difficulty(self, item: Dict) -> int:
        """
        Calculate keyword difficulty score (0-100)
        
        Uses competition_index (0-100) if available, otherwise falls back to
        competition string (HIGH/MEDIUM/LOW) and CPC.
        """
        # Prefer competition_index if available (0-100 scale)
        competition_index = item.get('competition_index')
        if competition_index is not None:
            return competition_index

        # Fallback: use competition string and CPC
        competition_str = (item.get('competition') or '').upper()
        cpc = item.get('cpc') or 0
        
        # Map competition string to numeric value
        competition_map = {
            'HIGH': 75,
            'MEDIUM': 50,
            'LOW': 25
        }
        competition_value = competition_map.get(competition_str, 50)
        
        # Combine competition and CPC (capped at 100)
        # Higher competition and CPC = higher difficulty
        difficulty = int(competition_value * 0.7 + min(cpc * 5, 30))
        return min(difficulty, 100)
    
    def _extract_related(self, item: Dict) -> List[str]:
        """
        Extract related keywords from API response
        
        Note: The Google Ads Search Volume endpoint doesn't return related keywords.
        This method is kept for compatibility but returns empty list.
        For related keywords, consider using the Keywords For Keywords endpoint.
        """
        # Google Ads Search Volume API doesn't provide related keywords
        # Return empty list - related keywords would need separate API call
        return item.get('related_keywords', [])[:5]
    
    def _calculate_relevance(self, item: Dict, original_topic: str) -> float:
        """Calculate relevance score (0-100) based on multiple factors"""
        score = 0.0

        # Factor 1: Search volume (30%)
        volume = item.get('search_volume') or 0
        if volume > 10000:
            score += 30
        elif volume > 1000:
            score += 20
        elif volume > 100:
            score += 10
        
        # Factor 2: Keyword difficulty (30% - inverse, easier = better)
        difficulty = self._calculate_difficulty(item)
        score += (100 - difficulty) * 0.3
        
        # Factor 3: Topic relevance (40%)
        keyword = item.get('keyword', '').lower()
        topic_lower = original_topic.lower()
        
        # Exact match = highest relevance
        if keyword == topic_lower:
            score += 40
        # Partial match
        elif topic_lower in keyword or keyword in topic_lower:
            score += 30
        # Related terms
        else:
            score += 10
        
        return min(score, 100.0)
    
    def _fallback_research(self, topic: str, limit: int) -> List[KeywordData]:
        """
        Fallback keyword suggestions when API is unavailable
        Uses heuristic-based keyword generation
        """
        keywords = []
        
        # Generate common keyword variations
        variations = self._generate_variations(topic)
        
        for i, variation in enumerate(variations[:limit]):
            # Estimate metrics heuristically
            estimated_volume = self._estimate_volume(variation)
            estimated_difficulty = self._estimate_difficulty(variation)
            
            keyword_data = KeywordData(
                keyword=variation,
                search_volume=estimated_volume,
                keyword_difficulty=estimated_difficulty,
                related_keywords=self._generate_related(variation, topic),
                relevance_score=100 - (i * 10)  # Decrease by position
            )
            keywords.append(keyword_data)
        
        return keywords
    
    def _generate_variations(self, topic: str) -> List[str]:
        """Generate keyword variations using common patterns"""
        variations = [topic]  # Original topic first
        
        # Common modifiers
        prefixes = ["best", "how to", "what is", "guide to", "tips for"]
        suffixes = ["guide", "tips", "for beginners", "explained", "2024"]
        
        # Add prefix variations
        for prefix in prefixes:
            variations.append(f"{prefix} {topic}")
        
        # Add suffix variations
        for suffix in suffixes:
            variations.append(f"{topic} {suffix}")
        
        # Combined variations
        variations.append(f"best {topic} tips")
        variations.append(f"how to {topic}")
        
        return variations[:15]  # Return top 15 variations
    
    def _estimate_volume(self, keyword: str) -> int:
        """Estimate search volume based on keyword characteristics"""
        word_count = len(keyword.split())
        
        # Longer keywords typically have lower volume
        if word_count <= 2:
            return 5000
        elif word_count == 3:
            return 2000
        else:
            return 800
    
    def _estimate_difficulty(self, keyword: str) -> int:
        """Estimate keyword difficulty based on characteristics"""
        word_count = len(keyword.split())
        
        # Longer, more specific keywords are typically easier
        if word_count >= 4:
            return 35
        elif word_count == 3:
            return 55
        else:
            return 70
    
    def _generate_related(self, keyword: str, original: str) -> List[str]:
        """Generate related keyword suggestions"""
        related = []
        
        # Add question formats
        related.append(f"what is {original}")
        related.append(f"how to {original}")
        related.append(f"why {original}")
        
        # Add comparison format
        if " " in original:
            related.append(f"{original} vs")
        
        return related[:5]


def format_output(keywords: List[KeywordData], format_type: str = "json") -> str:
    """Format keyword research results"""
    if format_type == "json":
        return json.dumps([kw.to_dict() for kw in keywords], indent=2)
    
    elif format_type == "markdown":
        lines = ["# Keyword Research Results\n"]
        
        for i, kw in enumerate(keywords, 1):
            lines.append(f"## {i}. {kw.keyword}")
            lines.append(f"- **Search Volume:** {kw.search_volume:,}")
            lines.append(f"- **Difficulty:** {kw.keyword_difficulty}/100")
            lines.append(f"- **Relevance:** {kw.relevance_score:.1f}/100")
            
            if kw.related_keywords:
                lines.append(f"- **Related:** {', '.join(kw.related_keywords[:3])}")
            lines.append("")
        
        return "\n".join(lines)
    
    elif format_type == "simple":
        lines = []
        for i, kw in enumerate(keywords, 1):
            lines.append(
                f"{i}. {kw.keyword} "
                f"(Vol: {kw.search_volume:,}, Diff: {kw.keyword_difficulty}, "
                f"Score: {kw.relevance_score:.0f})"
            )
        return "\n".join(lines)
    
    else:
        raise ValueError(f"Unknown format: {format_type}")


def main():
    """CLI interface for keyword research"""
    parser = argparse.ArgumentParser(
        description="Research keywords for SEO-GEO blog writing"
    )
    parser.add_argument(
        "topic",
        help="Topic or seed keyword to research"
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=5,
        help="Maximum number of keyword suggestions (default: 5)"
    )
    parser.add_argument(
        "--api-key",
        help="DataForSEO API key (format: 'login:password' or Base64-encoded). Can also use DATAFORSEO_API_KEY env var or config file"
    )
    parser.add_argument(
        "--interactive",
        action="store_true",
        help="Prompt for API key interactively if not found (useful for Claude Skills)"
    )
    parser.add_argument(
        "--format",
        choices=["json", "markdown", "simple"],
        default="markdown",
        help="Output format (default: markdown)"
    )
    
    args = parser.parse_args()
    
    # Initialize researcher with hybrid credential management
    researcher = KeywordResearcher(api_key=args.api_key, interactive=args.interactive)
    
    # Display API status
    if researcher.api_available:
        print("✓ Using DataForSEO API for research", file=sys.stderr)
    else:
        print("⚠ API key not found. Using heuristic fallback.", file=sys.stderr)
        print("  Credential options (checked in order):", file=sys.stderr)
        print("  1. Set DATAFORSEO_API_KEY environment variable", file=sys.stderr)
        print("  2. Create .seo-geo-config.json in project root (works in containers!)", file=sys.stderr)
        print("  3. Create ~/.dataforseo-skill/config.json with {'api_key': 'login:password'}", file=sys.stderr)
        print("  4. Use --api-key 'login:password' command line argument", file=sys.stderr)
        print("  5. Use --interactive flag to prompt for credentials", file=sys.stderr)
        print("  Note: Supports both plain text (login:password) and Base64-encoded formats", file=sys.stderr)
    
    print("", file=sys.stderr)
    
    # Conduct research
    try:
        keywords = researcher.research_keywords(args.topic, args.limit)
        
        if not keywords:
            print("Error: No keywords found", file=sys.stderr)
            sys.exit(1)
        
        # Output results
        print(format_output(keywords, args.format))
        
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
