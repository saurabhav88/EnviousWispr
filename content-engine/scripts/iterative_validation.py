#!/usr/bin/env python3
"""
Iterative Validation Loop with Auto-Fix Capabilities

Automatically fixes blog post issues through multiple validation iterations.
Stops when: score >= 80 OR max_iterations reached
"""

import sys
import re
from pathlib import Path
from typing import Dict, List, Tuple, Optional
from dataclasses import dataclass

# Import existing validation
from validate_structure import validate_blog_post


@dataclass
class FixResult:
    """Result of applying a fix"""
    fixed: bool
    description: str
    content: str  # Updated content


class AutoFixer:
    """Automatically fixes common blog post issues"""

    def __init__(self, draft_content: str):
        self.content = draft_content
        self.fixes_applied = []

    def fix_missing_faq(self) -> FixResult:
        """
        Auto-generate FAQ section from content headings

        Strategy:
        1. Extract H2 headings
        2. Convert to questions (e.g., "Best Practices" → "What are the best practices?")
        3. Generate placeholder answers from section content
        4. Add FAQ section before conclusion
        """
        if "## FAQ" in self.content or "## Frequently Asked Questions" in self.content:
            return FixResult(False, "FAQ section already exists", self.content)

        # Extract H2 headings
        h2_headings = re.findall(r'^## (.+)$', self.content, re.MULTILINE)

        # Filter out meta sections
        exclude = ['FAQ', 'Frequently Asked Questions', 'About the Author', 'Conclusion', 'Introduction', 'Table of Contents']
        h2_headings = [h for h in h2_headings if h not in exclude]

        if len(h2_headings) < 3:
            return FixResult(False, "Not enough headings to generate FAQ", self.content)

        # Generate FAQs (take first 4-6 headings)
        faqs = []
        for heading in h2_headings[:6]:
            question = self._heading_to_question(heading)
            # Extract first paragraph from that section as answer
            answer = self._extract_section_summary(heading)
            faqs.append(f"### {question}\n\n{answer}\n")

        # Insert FAQ section before conclusion or at end
        faq_section = "\n## Frequently Asked Questions\n\n" + "\n".join(faqs)

        # Find insertion point (before "## Conclusion" or "## About the Author")
        insertion_point = self._find_insertion_point(['## Conclusion', '## About the Author'])

        if insertion_point:
            updated = self.content[:insertion_point] + faq_section + "\n\n" + self.content[insertion_point:]
        else:
            updated = self.content + "\n\n" + faq_section

        return FixResult(True, f"Added FAQ section with {len(faqs)} questions", updated)

    def fix_missing_author_bio(self) -> FixResult:
        """
        Add author bio template at end of article

        Note: Requires user to fill in actual details
        But validates structure is present
        """
        if "## About the Author" in self.content or "**Author:**" in self.content:
            return FixResult(False, "Author bio already exists", self.content)

        bio_template = """
## About the Author

[Author Name] is a [job title] with [X years] of experience in [industry/field].
[Brief accomplishment or expertise statement].

Connect with [Author Name] on [LinkedIn/Twitter] or visit [website].
"""

        updated = self.content + "\n\n" + bio_template
        return FixResult(True, "Added author bio template (requires user completion)", updated)

    def fix_short_title(self, current_title: str) -> FixResult:
        """
        Expand title if too short (<50 chars)

        Strategy:
        1. Add year if tutorial/guide ("Guide" → "Guide 2025")
        2. Add specificity ("Marketing Tools" → "Best Marketing Tools for Small Business")
        3. Keep within 60 char limit
        """
        if len(current_title) >= 50:
            return FixResult(False, "Title length is adequate", self.content)

        # Extract current title (first H1)
        title_match = re.search(r'^# (.+)$', self.content, re.MULTILINE)
        if not title_match:
            return FixResult(False, "No title found", self.content)

        title = title_match.group(1)

        # Enhancement strategies
        if "guide" in title.lower() and "2025" not in title:
            enhanced = f"{title} 2025"
        elif len(title) < 40:
            # Add descriptive phrase
            enhanced = f"Complete {title} Guide"
        else:
            # Minor expansion
            enhanced = f"{title}: Essential Guide"

        # Ensure < 60 chars
        if len(enhanced) > 60:
            enhanced = enhanced[:57] + "..."

        updated = self.content.replace(f"# {title}", f"# {enhanced}", 1)
        return FixResult(True, f"Expanded title: '{title}' → '{enhanced}'", updated)

    def fix_low_word_count(self, current_count: int, target: int = 1500) -> FixResult:
        """
        Expand thin content sections

        Strategy:
        1. Identify shortest sections
        2. Add expansion prompts (for Claude to fill)
        3. Cannot fully auto-fix, but can structure for expansion
        """
        if current_count >= target:
            return FixResult(False, "Word count is adequate", self.content)

        # This requires Claude to actually write more content
        # We can identify thin sections and add placeholders
        sections = re.split(r'^## (.+)$', self.content, flags=re.MULTILINE)

        thin_sections = []
        for i in range(1, len(sections), 2):
            if i + 1 < len(sections):
                heading = sections[i]
                content = sections[i + 1]
                word_count = len(content.split())
                if word_count < 150:
                    thin_sections.append(heading)

        if thin_sections:
            note = f"\n\n<!-- VALIDATION NOTE: Expand these thin sections: {', '.join(thin_sections)} -->\n"
            return FixResult(False, f"Identified {len(thin_sections)} thin sections (manual expansion needed)", self.content + note)

        return FixResult(False, "No obvious thin sections to expand", self.content)

    def fix_missing_schema(self) -> FixResult:
        """
        Add basic schema markup templates

        Generates:
        - BlogPosting schema
        - FAQPage schema (if FAQ section exists)
        """
        if "```json" in self.content and '"@type": "BlogPosting"' in self.content:
            return FixResult(False, "Schema markup already exists", self.content)

        # Extract metadata for schema
        title_match = re.search(r'^# (.+)$', self.content, re.MULTILINE)
        title = title_match.group(1) if title_match else "Blog Post"

        # Basic BlogPosting schema
        schema_template = f'''
## Schema Markup

```json
{{
  "@context": "https://schema.org",
  "@type": "BlogPosting",
  "headline": "{title}",
  "author": {{
    "@type": "Person",
    "name": "[Author Name]"
  }},
  "datePublished": "[YYYY-MM-DD]",
  "dateModified": "[YYYY-MM-DD]",
  "description": "[Meta description]",
  "image": "[Featured image URL]"
}}
```
'''

        # Add FAQPage schema if FAQ section exists
        if "## FAQ" in self.content or "## Frequently Asked Questions" in self.content:
            # Extract FAQ questions
            faq_questions = re.findall(r'###\s+(.+\?)', self.content)

            if faq_questions:
                faq_entities = []
                for i, question in enumerate(faq_questions[:8], 1):
                    faq_entities.append(f'''    {{
      "@type": "Question",
      "name": "{question}",
      "acceptedAnswer": {{
        "@type": "Answer",
        "text": "[Answer {i}]"
      }}
    }}''')

                faq_schema = f'''
```json
{{
  "@context": "https://schema.org",
  "@type": "FAQPage",
  "mainEntity": [
{','.join(faq_entities)}
  ]
}}
```
'''
                schema_template += "\n" + faq_schema

        updated = self.content + "\n\n" + schema_template
        return FixResult(True, "Added schema markup templates (requires completion)", updated)

    # Helper methods

    def _heading_to_question(self, heading: str) -> str:
        """Convert heading to FAQ question"""
        # Simple heuristics
        heading_lower = heading.lower()

        if heading_lower.startswith("what"):
            return heading + "?"
        elif heading_lower.startswith("how"):
            return heading + "?"
        elif heading_lower.startswith("why"):
            return heading + "?"
        elif "best" in heading_lower:
            return f"What are the {heading_lower}?"
        elif "benefit" in heading_lower:
            return f"What are the benefits of {heading_lower.replace('benefits of', '').strip()}?"
        elif "tip" in heading_lower or "strategy" in heading_lower or "practice" in heading_lower:
            return f"What are some {heading_lower}?"
        else:
            return f"What is {heading}?"

    def _extract_section_summary(self, heading: str) -> str:
        """Extract first 100 words from section"""
        # Find section content
        pattern = f"## {re.escape(heading)}\\n+(.+?)(?=\\n## |\\Z)"
        match = re.search(pattern, self.content, re.DOTALL)
        if match:
            content = match.group(1).strip()
            # Remove markdown formatting for cleaner summary
            content = re.sub(r'\[([^\]]+)\]\([^\)]+\)', r'\1', content)  # Remove links
            content = re.sub(r'[*_`]', '', content)  # Remove formatting
            words = content.split()[:100]
            return " ".join(words) + ("..." if len(words) >= 100 else "")
        return "[Answer placeholder - expand with content from this section]"

    def _find_insertion_point(self, markers: List[str]) -> Optional[int]:
        """Find position to insert content (before markers)"""
        for marker in markers:
            pos = self.content.find(marker)
            if pos != -1:
                return pos
        return None


def iterative_validation(
    draft_path: Path,
    max_iterations: int = 3,
    target_score: int = 80,
    show_progress: bool = False
) -> Tuple[str, Dict, List[str]]:
    """
    Iteratively validate and fix blog post

    Args:
        draft_path: Path to draft markdown file
        max_iterations: Maximum fix attempts (default: 3)
        target_score: Target validation score (default: 80)
        show_progress: Print iteration details (default: False)

    Returns:
        Tuple of (final_content, final_validation_result, fixes_applied)
    """

    # Read initial content
    with open(draft_path, 'r', encoding='utf-8') as f:
        content = f.read()

    fixes_applied = []

    for iteration in range(1, max_iterations + 1):
        if show_progress:
            print(f"\n🔄 Iteration {iteration}/{max_iterations}", file=sys.stderr)

        # Validate current state
        validation = validate_blog_post(content)

        if show_progress:
            print(f"   Score: {validation['score']}/100", file=sys.stderr)

        # Check stop criteria
        if validation['score'] >= target_score:
            if show_progress:
                print(f"✓ Target score reached ({validation['score']} >= {target_score})", file=sys.stderr)
            break

        if iteration == max_iterations:
            if show_progress:
                print(f"⚠ Max iterations reached", file=sys.stderr)
            break

        # Apply fixes
        fixer = AutoFixer(content)
        iteration_fixes = []

        # Categorize warnings and apply fixes
        for warning in validation.get('warnings', []):
            fix_result = None

            if "FAQ section" in warning:
                fix_result = fixer.fix_missing_faq()
            elif "author bio" in warning.lower():
                fix_result = fixer.fix_missing_author_bio()
            elif "title length" in warning.lower():
                # Extract current title length
                title_match = re.search(r'^# (.+)$', content, re.MULTILINE)
                if title_match:
                    fix_result = fixer.fix_short_title(title_match.group(1))
            elif "schema markup" in warning.lower():
                fix_result = fixer.fix_missing_schema()
            elif "word count" in warning.lower():
                # Extract current count
                word_count = len(content.split())
                fix_result = fixer.fix_low_word_count(word_count)

            if fix_result and fix_result.fixed:
                content = fix_result.content
                fixer.content = content  # Update fixer's content for next fix
                iteration_fixes.append(fix_result.description)
                if show_progress:
                    print(f"   ✓ {fix_result.description}", file=sys.stderr)

        # Also check failed items
        for failed in validation.get('failed', []):
            fix_result = None

            if "FAQ section" in failed:
                fix_result = fixer.fix_missing_faq()
            elif "author bio" in failed.lower():
                fix_result = fixer.fix_missing_author_bio()

            if fix_result and fix_result.fixed:
                content = fix_result.content
                fixer.content = content  # Update fixer's content for next fix
                iteration_fixes.append(fix_result.description)
                if show_progress:
                    print(f"   ✓ {fix_result.description}", file=sys.stderr)

        if iteration_fixes:
            fixes_applied.extend(iteration_fixes)
        else:
            # No fixable warnings, stop iteration
            if show_progress:
                print("   No auto-fixable warnings remaining", file=sys.stderr)
            break

    # Final validation
    final_validation = validate_blog_post(content)

    return content, final_validation, fixes_applied


def main():
    """CLI interface"""
    import argparse

    parser = argparse.ArgumentParser(description="Iterative blog post validation and fixing")
    parser.add_argument("draft", type=Path, help="Draft blog post file")
    parser.add_argument("--max-iterations", type=int, default=3, help="Max fix iterations (default: 3)")
    parser.add_argument("--target-score", type=int, default=80, help="Target score (default: 80)")
    parser.add_argument("--output", type=Path, help="Save fixed version to file")
    parser.add_argument("--show-progress", action="store_true", help="Show iteration details")

    args = parser.parse_args()

    # Run iterative validation
    final_content, validation, fixes = iterative_validation(
        draft_path=args.draft,
        max_iterations=args.max_iterations,
        target_score=args.target_score,
        show_progress=args.show_progress
    )

    # Output results
    print("\n" + "="*60)
    print("ITERATIVE VALIDATION RESULTS")
    print("="*60)
    print(f"\nFinal Score: {validation['score']}/100")
    print(f"\nFixes Applied ({len(fixes)}):")
    for fix in fixes:
        print(f"  ✓ {fix}")

    # Show validation summary
    if validation['passed']:
        print(f"\n✓ PASSED ({len(validation['passed'])} checks):")
        for item in validation['passed'][:5]:  # Show first 5
            print(f"  {item}")
        if len(validation['passed']) > 5:
            print(f"  ... and {len(validation['passed']) - 5} more")

    if validation['warnings']:
        print(f"\n⚠ WARNINGS ({len(validation['warnings'])} items):")
        for item in validation['warnings'][:5]:  # Show first 5
            print(f"  {item}")
        if len(validation['warnings']) > 5:
            print(f"  ... and {len(validation['warnings']) - 5} more")

    if validation['failed']:
        print(f"\n✗ FAILED ({len(validation['failed'])} checks):")
        for item in validation['failed']:
            print(f"  {item}")

    # Final assessment
    print("\n" + "="*60)
    if validation['score'] >= 80:
        print("✓ Excellent! Blog post meets SEO/GEO standards.")
    elif validation['score'] >= 60:
        print("⚠ Good, but address warnings for better optimization.")
    else:
        print("✗ Needs improvement. Address failed checks and warnings.")
    print("="*60 + "\n")

    # Save if requested
    if args.output:
        with open(args.output, 'w', encoding='utf-8') as f:
            f.write(final_content)
        print(f"✓ Fixed version saved to: {args.output}\n")


if __name__ == "__main__":
    main()
