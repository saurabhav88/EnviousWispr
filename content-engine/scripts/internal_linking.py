#!/usr/bin/env python3
"""
Internal Linking Suggestion Tool for SEO-GEO Blog Writer

Analyzes draft content and existing site content to suggest optimal
internal linking opportunities based on:
- Topic overlap and semantic relevance
- Keyword matching
- Contextual placement
- Anchor text optimization

Usage:
    python internal_linking.py draft.md --site-content blog/*.md
    python internal_linking.py draft.md --site-urls urls.json
    python internal_linking.py draft.md --format json
"""

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from dataclasses import dataclass, asdict
from collections import Counter


@dataclass
class InternalLinkSuggestion:
    """Internal link suggestion with context"""
    target_keyword: str  # Keyword/phrase to link
    target_url: str  # URL to link to
    target_title: str  # Title of target page
    anchor_text: str  # Recommended anchor text
    placement_section: str  # Which section (H2) to place in
    placement_context: str  # Surrounding text context
    relevance_score: float  # 0-100 relevance score
    reason: str  # Why this link makes sense

    def to_dict(self) -> Dict:
        return asdict(self)


@dataclass
class SiteContent:
    """Represents a page on your site"""
    url: str
    title: str
    keywords: List[str]  # Main topics/keywords
    content_preview: str  # First 200 chars
    h2_headings: List[str]

    @classmethod
    def from_markdown(cls, file_path: Path, base_url: str = ""):
        """Create SiteContent from markdown file"""
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()

        # Extract title (first H1)
        title_match = re.search(r'^#\s+(.+)$', content, re.MULTILINE)
        title = title_match.group(1) if title_match else file_path.stem

        # Extract H2 headings
        h2_headings = re.findall(r'^##\s+(.+)$', content, re.MULTILINE)

        # Extract keywords (simplified - could use NLP)
        keywords = cls._extract_keywords(content)

        # Content preview
        text = re.sub(r'#{1,6}\s+.+', '', content)  # Remove headings
        text = re.sub(r'\[.+?\]\(.+?\)', '', text)  # Remove links
        text = ' '.join(text.split())[:200]

        # Generate URL from file path
        url = base_url + "/" + file_path.stem.replace('_', '-')

        return cls(
            url=url,
            title=title,
            keywords=keywords,
            content_preview=text,
            h2_headings=h2_headings
        )

    @staticmethod
    def _extract_keywords(content: str) -> List[str]:
        """Extract main keywords from content (simplified)"""
        # Remove markdown formatting
        text = re.sub(r'#{1,6}\s+', '', content)
        text = re.sub(r'\[.+?\]\(.+?\)', '', text)
        text = re.sub(r'[*_`]', '', text)

        # Extract common phrases (2-3 words)
        words = text.lower().split()
        phrases = []

        # Extract 2-word phrases
        for i in range(len(words) - 1):
            phrase = f"{words[i]} {words[i+1]}"
            if len(phrase) > 6 and not any(c.isdigit() for c in phrase):
                phrases.append(phrase)

        # Extract 3-word phrases
        for i in range(len(words) - 2):
            phrase = f"{words[i]} {words[i+1]} {words[i+2]}"
            if len(phrase) > 10 and not any(c.isdigit() for c in phrase):
                phrases.append(phrase)

        # Return most common phrases
        counter = Counter(phrases)
        return [phrase for phrase, count in counter.most_common(20) if count >= 2]


class InternalLinkingAnalyzer:
    """Suggest internal linking opportunities"""

    def __init__(self, min_relevance: float = 60.0):
        """
        Initialize internal linking analyzer.

        Args:
            min_relevance: Minimum relevance score (0-100) for suggestions
        """
        self.min_relevance = min_relevance

    def suggest_links(
        self,
        draft_content: str,
        site_pages: List[SiteContent],
        max_suggestions: int = 5
    ) -> List[InternalLinkSuggestion]:
        """
        Suggest internal links for draft content.

        Args:
            draft_content: Draft blog post content
            site_pages: Existing site pages to link to
            max_suggestions: Maximum number of suggestions

        Returns:
            List of InternalLinkSuggestion sorted by relevance
        """
        suggestions = []

        # Extract sections from draft
        draft_sections = self._extract_sections(draft_content)

        # For each site page, find linking opportunities
        for page in site_pages:
            # Find keyword matches in draft
            matches = self._find_keyword_matches(draft_content, page.keywords)

            for keyword, contexts in matches.items():
                # Skip if keyword already linked
                if self._is_already_linked(draft_content, page.url):
                    continue

                # Find best placement
                placement = self._find_best_placement(contexts, draft_sections)

                if placement:
                    section, context = placement

                    # Calculate relevance score
                    relevance = self._calculate_relevance(
                        keyword=keyword,
                        page=page,
                        draft_content=draft_content,
                        context=context
                    )

                    if relevance >= self.min_relevance:
                        # Generate anchor text
                        anchor_text = self._generate_anchor_text(keyword, page.title)

                        # Create suggestion
                        suggestion = InternalLinkSuggestion(
                            target_keyword=keyword,
                            target_url=page.url,
                            target_title=page.title,
                            anchor_text=anchor_text,
                            placement_section=section,
                            placement_context=context,
                            relevance_score=relevance,
                            reason=self._generate_reason(keyword, page, relevance)
                        )
                        suggestions.append(suggestion)

        # Sort by relevance and limit
        suggestions.sort(key=lambda x: x.relevance_score, reverse=True)
        return suggestions[:max_suggestions]

    def _extract_sections(self, content: str) -> Dict[str, str]:
        """Extract sections (H2) from content"""
        sections = {}

        # Split by H2 headings
        parts = re.split(r'^##\s+(.+)$', content, flags=re.MULTILINE)

        # Group heading with its content
        for i in range(1, len(parts), 2):
            if i + 1 < len(parts):
                heading = parts[i].strip()
                section_content = parts[i + 1].strip()
                sections[heading] = section_content

        return sections

    def _find_keyword_matches(
        self,
        content: str,
        keywords: List[str]
    ) -> Dict[str, List[str]]:
        """
        Find keyword mentions in content with context.

        Returns:
            Dict of keyword -> list of context snippets
        """
        matches = {}

        content_lower = content.lower()

        for keyword in keywords:
            keyword_lower = keyword.lower()

            # Find all occurrences
            positions = []
            start = 0
            while True:
                pos = content_lower.find(keyword_lower, start)
                if pos == -1:
                    break
                positions.append(pos)
                start = pos + len(keyword_lower)

            if positions:
                # Extract context around each match
                contexts = []
                for pos in positions:
                    # Get 100 chars before and after
                    context_start = max(0, pos - 100)
                    context_end = min(len(content), pos + len(keyword) + 100)
                    context = content[context_start:context_end].strip()
                    contexts.append(context)

                matches[keyword] = contexts

        return matches

    def _is_already_linked(self, content: str, url: str) -> bool:
        """Check if URL is already linked in content"""
        return url in content

    def _find_best_placement(
        self,
        contexts: List[str],
        sections: Dict[str, str]
    ) -> Optional[Tuple[str, str]]:
        """
        Find best section for link placement.

        Returns:
            Tuple of (section_heading, context) or None
        """
        # Find which section contains the first mention
        for section_heading, section_content in sections.items():
            for context in contexts:
                # Check if context appears in this section
                if context in section_content:
                    return (section_heading, context)

        # Fallback: return first context with generic section
        if contexts:
            return ("Introduction", contexts[0])

        return None

    def _calculate_relevance(
        self,
        keyword: str,
        page: SiteContent,
        draft_content: str,
        context: str
    ) -> float:
        """
        Calculate relevance score (0-100) for link suggestion.

        Factors:
        - Keyword prominence (40%)
        - Topic overlap (30%)
        - Context quality (30%)
        """
        score = 0.0

        # Factor 1: Keyword prominence (40%)
        keyword_count = draft_content.lower().count(keyword.lower())
        if keyword_count >= 3:
            score += 40
        elif keyword_count == 2:
            score += 30
        elif keyword_count == 1:
            score += 20

        # Factor 2: Topic overlap (30%)
        # Check if page keywords appear in draft
        draft_lower = draft_content.lower()
        overlap_count = sum(1 for kw in page.keywords if kw.lower() in draft_lower)
        overlap_ratio = overlap_count / max(len(page.keywords), 1)
        score += overlap_ratio * 30

        # Factor 3: Context quality (30%)
        # Prefer contexts that are descriptive (longer)
        if len(context) > 150:
            score += 30
        elif len(context) > 100:
            score += 20
        else:
            score += 10

        return min(score, 100.0)

    def _generate_anchor_text(self, keyword: str, page_title: str) -> str:
        """Generate optimal anchor text"""
        # Prefer natural keyword as anchor
        # Capitalize first letter
        anchor = keyword.strip()
        if anchor:
            anchor = anchor[0].upper() + anchor[1:]
        return anchor

    def _generate_reason(
        self,
        keyword: str,
        page: SiteContent,
        relevance: float
    ) -> str:
        """Generate explanation for why this link makes sense"""
        if relevance >= 90:
            return f"Highly relevant: '{keyword}' appears multiple times and topics strongly overlap"
        elif relevance >= 75:
            return f"Strong relevance: '{keyword}' mentioned and topics align well"
        elif relevance >= 60:
            return f"Good relevance: '{keyword}' provides useful context for readers"
        else:
            return f"Moderate relevance: Related topic that adds value"


def load_site_content(
    content_paths: List[Path],
    base_url: str = ""
) -> List[SiteContent]:
    """Load site content from markdown files"""
    site_pages = []

    for path in content_paths:
        try:
            if path.is_file() and path.suffix == '.md':
                page = SiteContent.from_markdown(path, base_url)
                site_pages.append(page)
            elif path.is_dir():
                # Recursively load all .md files
                for md_file in path.rglob('*.md'):
                    page = SiteContent.from_markdown(md_file, base_url)
                    site_pages.append(page)
        except Exception as e:
            print(f"Warning: Failed to load {path}: {e}", file=sys.stderr)

    return site_pages


def format_suggestions(
    suggestions: List[InternalLinkSuggestion],
    format_type: str = "markdown"
) -> str:
    """Format internal linking suggestions"""

    if format_type == "json":
        return json.dumps([s.to_dict() for s in suggestions], indent=2)

    elif format_type == "markdown":
        if not suggestions:
            return "# Internal Linking Suggestions\n\nNo suggestions found. Try lowering --min-relevance threshold.\n"

        lines = [
            "# Internal Linking Suggestions\n",
            f"**Total Suggestions:** {len(suggestions)}\n"
        ]

        for i, sug in enumerate(suggestions, 1):
            lines.extend([
                f"## {i}. Link to: {sug.target_title}\n",
                f"**Keyword:** {sug.target_keyword}",
                f"**Target URL:** {sug.target_url}",
                f"**Anchor Text:** `{sug.anchor_text}`",
                f"**Placement:** {sug.placement_section} section",
                f"**Relevance:** {sug.relevance_score:.1f}/100",
                f"**Reason:** {sug.reason}\n",
                "**Context:**",
                f"> {sug.placement_context[:150]}...\n",
                "**Action:**",
                f"Replace `{sug.target_keyword}` with `[{sug.anchor_text}]({sug.target_url})`\n",
                "---\n"
            ])

        return "\n".join(lines)

    else:
        raise ValueError(f"Unknown format: {format_type}")


def main():
    """CLI interface for internal linking suggestions"""
    parser = argparse.ArgumentParser(
        description="Suggest internal linking opportunities for blog content"
    )
    parser.add_argument(
        "draft",
        type=Path,
        help="Draft blog post (markdown file)"
    )
    parser.add_argument(
        "--site-content",
        nargs='+',
        type=Path,
        help="Paths to existing site content (markdown files or directories)"
    )
    parser.add_argument(
        "--base-url",
        default="",
        help="Base URL for site (e.g., https://example.com/blog)"
    )
    parser.add_argument(
        "--max-suggestions",
        type=int,
        default=5,
        help="Maximum number of suggestions (default: 5)"
    )
    parser.add_argument(
        "--min-relevance",
        type=float,
        default=60.0,
        help="Minimum relevance score 0-100 (default: 60)"
    )
    parser.add_argument(
        "--format",
        choices=["json", "markdown"],
        default="markdown",
        help="Output format (default: markdown)"
    )

    args = parser.parse_args()

    # Validate draft file
    if not args.draft.exists():
        print(f"Error: Draft file not found: {args.draft}", file=sys.stderr)
        sys.exit(1)

    # Load draft content
    try:
        with open(args.draft, 'r', encoding='utf-8') as f:
            draft_content = f.read()
    except Exception as e:
        print(f"Error reading draft: {e}", file=sys.stderr)
        sys.exit(1)

    # Load site content
    if not args.site_content:
        print("Warning: No --site-content provided. No suggestions will be generated.", file=sys.stderr)
        print("Example: --site-content blog/*.md", file=sys.stderr)
        sys.exit(1)

    site_pages = load_site_content(args.site_content, args.base_url)

    if not site_pages:
        print("Error: No site content loaded. Check paths.", file=sys.stderr)
        sys.exit(1)

    print(f"✓ Loaded {len(site_pages)} site pages", file=sys.stderr)

    # Analyze and suggest links
    analyzer = InternalLinkingAnalyzer(min_relevance=args.min_relevance)

    try:
        suggestions = analyzer.suggest_links(
            draft_content=draft_content,
            site_pages=site_pages,
            max_suggestions=args.max_suggestions
        )

        # Output results
        print(format_suggestions(suggestions, args.format))

        if not suggestions:
            print(f"\nNo suggestions met the relevance threshold ({args.min_relevance}).", file=sys.stderr)
            print("Try lowering --min-relevance or adding more site content.", file=sys.stderr)

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
