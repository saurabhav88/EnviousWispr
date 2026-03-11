#!/usr/bin/env python3
"""
Automatic Internal Linking with Auto-Insertion

Discovers content from multiple sources and automatically inserts
high-confidence internal links (≥90 relevance).

Content sources (priority order):
1. Sitemap XML (if configured) - Best for Claude Code/containers
2. Local markdown files (default: ../website/src/content/blog/)
3. Fallback to empty list
"""

import sys
import re
from pathlib import Path
from typing import List, Tuple
from dataclasses import dataclass

# Import existing internal linking analyzer
from internal_linking import InternalLinkingAnalyzer, InternalLinkSuggestion, SiteContent

# Import new content discovery
from content_sources import ContentDiscovery, ContentItem


def content_items_to_site_content(items: List[ContentItem]) -> List[SiteContent]:
    """
    Convert ContentItems to SiteContent for analyzer

    Args:
        items: List of ContentItems from discovery

    Returns:
        List of SiteContent objects for internal linking analysis
    """
    site_pages = []

    for item in items:
        # Create SiteContent from ContentItem
        # Note: h2_headings not available from discovery, left empty
        page = SiteContent(
            url=item.url,
            title=item.title,
            keywords=item.keywords,
            content_preview=item.excerpt,
            h2_headings=[]  # Not available from content discovery
        )
        site_pages.append(page)

    return site_pages


def auto_insert_links(
    draft_content: str,
    suggestions: List[InternalLinkSuggestion],
    min_confidence: int = 90
) -> Tuple[str, List[InternalLinkSuggestion]]:
    """
    Automatically insert high-confidence internal links

    Strategy:
    - Find first occurrence of target keyword in draft
    - Replace with markdown link
    - Only insert once per keyword (avoid over-linking)

    Args:
        draft_content: Draft blog post content
        suggestions: List of link suggestions from analyzer
        min_confidence: Minimum relevance for auto-insertion (default: 90)

    Returns:
        Tuple of (updated_content, inserted_links)
    """
    updated = draft_content
    inserted = []

    # Sort suggestions by relevance (highest first)
    suggestions_sorted = sorted(suggestions, key=lambda x: x.relevance_score, reverse=True)

    for suggestion in suggestions_sorted:
        if suggestion.relevance_score >= min_confidence:
            # Find first occurrence of keyword (case-insensitive)
            # Use word boundaries to avoid partial matches
            pattern = re.compile(r'\b' + re.escape(suggestion.target_keyword) + r'\b', re.IGNORECASE)
            match = pattern.search(updated)

            if match:
                # Check if this text is already part of a link
                # Look for [...](...)  pattern around the match
                start_pos = max(0, match.start() - 100)
                end_pos = min(len(updated), match.end() + 100)
                context = updated[start_pos:end_pos]

                # Skip if already in a link
                if '[' in context[:100] and '](' in context:
                    continue

                # Replace with markdown link
                link = f"[{match.group()}]({suggestion.target_url})"
                updated = updated[:match.start()] + link + updated[match.end():]
                inserted.append(suggestion)

                print(f"  ✓ Inserted: {suggestion.anchor_text} → {suggestion.target_url} ({suggestion.relevance_score:.0f})", file=sys.stderr)

    return updated, inserted


def main():
    """CLI interface"""
    import argparse

    parser = argparse.ArgumentParser(
        description="Auto-insert internal links into blog draft",
        epilog="""
Examples:
  # With sitemap (recommended for Claude Code/containers):
  python auto_internal_linking.py draft.md --sitemap-url https://yourdomain.com/sitemap.xml

  # With local markdown:
  python auto_internal_linking.py draft.md --local-content ./blog-posts

  # Dry run (show suggestions without inserting):
  python auto_internal_linking.py draft.md --sitemap-url https://example.com/sitemap.xml --dry-run

  # Adjust confidence threshold:
  python auto_internal_linking.py draft.md --sitemap-url https://example.com/sitemap.xml --min-confidence 85
        """
    )
    parser.add_argument("draft", type=Path, help="Draft blog post file")

    # Content source options
    parser.add_argument("--sitemap-url", help="Sitemap URL (e.g., https://yourdomain.com/sitemap.xml) - Recommended for containers")
    parser.add_argument("--local-content", type=Path, help="Local markdown directory")
    parser.add_argument("--sanity-project-id", help="(Deprecated) Sanity project ID — use --local-content instead")
    parser.add_argument("--sanity-dataset", default="production", help="(Deprecated) Sanity dataset (default: production)")
    parser.add_argument("--sanity-token", help="(Deprecated) Sanity read token for private datasets")
    parser.add_argument("--config-path", type=Path, help="Path to .seo-geo-config.json (default: auto-detect)")

    # Linking options
    parser.add_argument("--min-confidence", type=int, default=90, help="Min relevance for auto-insert (default: 90)")
    parser.add_argument("--max-links", type=int, default=5, help="Max links to insert (default: 5)")
    parser.add_argument("--output", type=Path, help="Save updated draft to file")
    parser.add_argument("--dry-run", action="store_true", help="Show suggestions without inserting")
    parser.add_argument("--no-cache", action="store_true", help="Skip content cache")

    args = parser.parse_args()

    # Validate draft file
    if not args.draft.exists():
        print(f"Error: Draft file not found: {args.draft}", file=sys.stderr)
        sys.exit(1)

    # Load draft
    with open(args.draft, 'r', encoding='utf-8') as f:
        draft_content = f.read()

    # Discover content
    print("🔍 Discovering existing content...", file=sys.stderr)
    discovery = ContentDiscovery(
        sitemap_url=args.sitemap_url,
        sanity_project_id=args.sanity_project_id,
        sanity_dataset=args.sanity_dataset,
        sanity_token=args.sanity_token,
        local_content_dir=args.local_content,
        config_path=args.config_path
    )

    content_items = discovery.discover_content(use_cache=not args.no_cache)
    site_pages = content_items_to_site_content(content_items)

    if not site_pages:
        print("\n❌ No existing content found.", file=sys.stderr)
        print("\nPlease configure at least one content source:", file=sys.stderr)
        print("  --sitemap-url <url>          (Recommended: works in containers)", file=sys.stderr)
        print("  --local-content <directory>  (Local markdown files)", file=sys.stderr)
        print("\nAlternatively, use .seo-geo-config.json:", file=sys.stderr)
        print('  {"content_sources": {"sitemap_url": "https://yourdomain.com/sitemap.xml"}}', file=sys.stderr)
        sys.exit(1)

    print(f"✓ Found {len(site_pages)} existing pages for internal linking", file=sys.stderr)

    # Analyze for internal links
    print(f"\n🔗 Analyzing internal linking opportunities...", file=sys.stderr)
    analyzer = InternalLinkingAnalyzer(min_relevance=60.0)

    suggestions = analyzer.suggest_links(
        draft_content=draft_content,
        site_pages=site_pages,
        max_suggestions=args.max_links * 2  # Get more suggestions to filter
    )

    if not suggestions:
        print("\nℹ️  No internal linking opportunities found", file=sys.stderr)
        print("\nPossible reasons:", file=sys.stderr)
        print("  - Draft content doesn't match existing page topics", file=sys.stderr)
        print("  - Existing content library too small", file=sys.stderr)
        print("  - Keywords don't overlap sufficiently", file=sys.stderr)
        sys.exit(0)

    # Filter by confidence
    high_confidence = [s for s in suggestions if s.relevance_score >= args.min_confidence]
    high_confidence = high_confidence[:args.max_links]  # Limit to max_links

    print(f"\n✓ Found {len(suggestions)} total suggestions", file=sys.stderr)
    print(f"  → {len(high_confidence)} high-confidence (≥{args.min_confidence})\n", file=sys.stderr)

    if args.dry_run:
        # Show suggestions only
        print("=" * 60)
        print("DRY RUN - Internal Link Suggestions")
        print("=" * 60)
        print(f"\nHigh-confidence links (≥{args.min_confidence} relevance):")
        for i, sug in enumerate(high_confidence, 1):
            print(f"\n{i}. Keyword: '{sug.target_keyword}'")
            print(f"   → Link to: {sug.target_url}")
            print(f"   → Anchor: {sug.anchor_text}")
            print(f"   → Relevance: {sug.relevance_score:.0f}/100")
            print(f"   → Reason: {sug.reason}")

        if len(suggestions) > len(high_confidence):
            print(f"\n\nMedium-confidence links ({args.min_confidence-10}-{args.min_confidence-1} relevance):")
            medium = [s for s in suggestions if 80 <= s.relevance_score < args.min_confidence][:3]
            for i, sug in enumerate(medium, 1):
                print(f"\n{i}. Keyword: '{sug.target_keyword}'")
                print(f"   → Link to: {sug.target_url}")
                print(f"   → Relevance: {sug.relevance_score:.0f}/100")

        print("\n" + "=" * 60)
        print("\nTo insert these links, remove --dry-run flag")
        sys.exit(0)

    # Auto-insert high-confidence links
    print(f"🔗 Auto-inserting {len(high_confidence)} high-confidence links...\n", file=sys.stderr)
    updated_content, inserted = auto_insert_links(draft_content, high_confidence, args.min_confidence)

    # Results
    print(f"\n{'='*60}", file=sys.stderr)
    print(f"INTERNAL LINKING RESULTS", file=sys.stderr)
    print(f"{'='*60}", file=sys.stderr)
    print(f"\n✓ Successfully inserted {len(inserted)} links:\n", file=sys.stderr)

    for i, link in enumerate(inserted, 1):
        print(f"{i}. {link.anchor_text}", file=sys.stderr)
        print(f"   → {link.target_url}", file=sys.stderr)
        print(f"   → Relevance: {link.relevance_score:.0f}/100", file=sys.stderr)
        print(f"   → {link.reason}", file=sys.stderr)
        print(file=sys.stderr)

    if len(high_confidence) > len(inserted):
        skipped = len(high_confidence) - len(inserted)
        print(f"ℹ️  Skipped {skipped} suggestions (keyword not found or already linked)\n", file=sys.stderr)

    print(f"{'='*60}\n", file=sys.stderr)

    # Save or print
    if args.output:
        with open(args.output, 'w', encoding='utf-8') as f:
            f.write(updated_content)
        print(f"✓ Updated draft saved to: {args.output}\n", file=sys.stderr)
    else:
        # Print to stdout for piping
        print(updated_content)


if __name__ == "__main__":
    main()
