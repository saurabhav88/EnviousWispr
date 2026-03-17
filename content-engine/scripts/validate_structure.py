#!/usr/bin/env python3
"""
SEO/GEO Blog Post Structure Validator

This script validates blog posts against SEO and GEO best practices.
Usage: python validate_structure.py <markdown_file>
"""

import re
import sys
import json
from typing import Dict, List, Tuple, Optional

try:
    from jsonschema import validate, ValidationError, Draft7Validator
    SCHEMA_VALIDATION_AVAILABLE = True
except ImportError:
    SCHEMA_VALIDATION_AVAILABLE = False

def analyze_readability(text: str) -> float:
    """Calculate Flesch Reading Ease score (simplified)"""
    sentences = len(re.findall(r'[.!?]+', text))
    words = len(text.split())
    syllables = sum(count_syllables(word) for word in text.split())
    
    if sentences == 0 or words == 0:
        return 0
    
    score = 206.835 - 1.015 * (words / sentences) - 84.6 * (syllables / words)
    return max(0, min(100, score))

def count_syllables(word: str) -> int:
    """Estimate syllable count"""
    word = word.lower()
    count = len(re.findall(r'[aeiouy]+', word))
    return max(1, count)


def extract_schema_from_content(content: str) -> List[Dict]:
    """
    Extract JSON-LD schema markup from markdown content.

    Looks for code blocks with schema markup.

    Returns:
        List of parsed schema objects
    """
    schemas = []

    # Pattern to match JSON-LD code blocks
    # Matches ```json or ```json-ld blocks
    code_blocks = re.findall(
        r'```(?:json|json-ld)\s*\n(.*?)\n```',
        content,
        re.DOTALL
    )

    for block in code_blocks:
        try:
            data = json.loads(block)
            # Check if it's schema.org markup (has @context or @type)
            if isinstance(data, dict) and ('@context' in data or '@type' in data):
                schemas.append(data)
            elif isinstance(data, list):
                # Handle array of schemas
                for item in data:
                    if isinstance(item, dict) and ('@context' in item or '@type' in item):
                        schemas.append(item)
        except json.JSONDecodeError:
            continue

    return schemas


def validate_schema_structure(schema: Dict) -> Tuple[bool, List[str]]:
    """
    Validate schema.org JSON-LD structure.

    Args:
        schema: Parsed schema object

    Returns:
        Tuple of (is_valid, list_of_errors)
    """
    errors = []

    # Basic structure validation
    if not isinstance(schema, dict):
        return False, ["Schema must be a JSON object"]

    # Check for @context (required for JSON-LD)
    if '@context' not in schema:
        errors.append("Missing @context field (required for JSON-LD)")

    # Check for @type (required)
    if '@type' not in schema:
        errors.append("Missing @type field (required)")
    else:
        schema_type = schema['@type']

        # Validate based on schema type
        if schema_type == 'BlogPosting' or schema_type == 'Article':
            errors.extend(validate_article_schema(schema))
        elif schema_type == 'FAQPage':
            errors.extend(validate_faq_schema(schema))
        elif schema_type == 'HowTo':
            errors.extend(validate_howto_schema(schema))

    return len(errors) == 0, errors


def validate_article_schema(schema: Dict) -> List[str]:
    """Validate BlogPosting/Article schema"""
    errors = []

    required_fields = ['headline', 'author', 'datePublished']
    recommended_fields = ['description', 'image', 'publisher']

    # Check required fields
    for field in required_fields:
        if field not in schema:
            errors.append(f"BlogPosting missing required field: '{field}'")

    # Check recommended fields
    for field in recommended_fields:
        if field not in schema:
            errors.append(f"BlogPosting missing recommended field: '{field}' (warning)")

    # Validate author structure
    if 'author' in schema:
        author = schema['author']
        if isinstance(author, dict):
            if '@type' not in author:
                errors.append("Author object missing '@type'")
            if 'name' not in author:
                errors.append("Author object missing 'name'")
        elif not isinstance(author, str):
            errors.append("Author must be object or string")

    # Validate image (if present)
    if 'image' in schema:
        image = schema['image']
        if isinstance(image, str):
            if not image.startswith('http'):
                errors.append("Image URL should be absolute (start with http/https)")
        elif isinstance(image, list):
            for img in image:
                if isinstance(img, str) and not img.startswith('http'):
                    errors.append("Image URL should be absolute (start with http/https)")

    return errors


def validate_faq_schema(schema: Dict) -> List[str]:
    """Validate FAQPage schema"""
    errors = []

    # Check for mainEntity
    if 'mainEntity' not in schema:
        errors.append("FAQPage missing 'mainEntity' field")
        return errors

    main_entity = schema['mainEntity']

    # mainEntity should be array of Questions
    if not isinstance(main_entity, list):
        errors.append("FAQPage 'mainEntity' should be array of questions")
        return errors

    if len(main_entity) < 4:
        errors.append(f"FAQPage has only {len(main_entity)} questions (recommend 4+)")

    # Validate each question
    for i, question in enumerate(main_entity):
        if not isinstance(question, dict):
            errors.append(f"Question {i+1} is not an object")
            continue

        if question.get('@type') != 'Question':
            errors.append(f"Question {i+1} missing @type='Question'")

        if 'name' not in question:
            errors.append(f"Question {i+1} missing 'name' (the question text)")

        if 'acceptedAnswer' not in question:
            errors.append(f"Question {i+1} missing 'acceptedAnswer'")
        else:
            answer = question['acceptedAnswer']
            if not isinstance(answer, dict):
                errors.append(f"Question {i+1} acceptedAnswer should be object")
            elif answer.get('@type') != 'Answer':
                errors.append(f"Question {i+1} acceptedAnswer missing @type='Answer'")
            elif 'text' not in answer:
                errors.append(f"Question {i+1} acceptedAnswer missing 'text'")

    return errors


def validate_howto_schema(schema: Dict) -> List[str]:
    """Validate HowTo schema"""
    errors = []

    required_fields = ['name', 'step']

    for field in required_fields:
        if field not in schema:
            errors.append(f"HowTo missing required field: '{field}'")

    # Validate steps
    if 'step' in schema:
        steps = schema['step']
        if not isinstance(steps, list):
            errors.append("HowTo 'step' should be array")
        else:
            for i, step in enumerate(steps):
                if not isinstance(step, dict):
                    errors.append(f"Step {i+1} should be object")
                    continue

                if step.get('@type') != 'HowToStep':
                    errors.append(f"Step {i+1} missing @type='HowToStep'")

                if 'text' not in step and 'name' not in step:
                    errors.append(f"Step {i+1} missing 'text' or 'name'")

    return errors


def validate_all_schemas(content: str) -> Dict:
    """
    Validate all schema markup in content.

    Returns:
        Dict with validation results
    """
    results = {
        'schemas_found': 0,
        'schemas_valid': 0,
        'schemas_invalid': 0,
        'errors': [],
        'warnings': []
    }

    if not SCHEMA_VALIDATION_AVAILABLE:
        results['warnings'].append(
            "⚠ Schema validation unavailable (install: pip install jsonschema)"
        )
        return results

    # Extract schemas from content
    schemas = extract_schema_from_content(content)
    results['schemas_found'] = len(schemas)

    if not schemas:
        results['warnings'].append("⚠ No schema markup found in content")
        return results

    # Validate each schema
    for i, schema in enumerate(schemas, 1):
        schema_type = schema.get('@type', 'Unknown')

        is_valid, schema_errors = validate_schema_structure(schema)

        if is_valid:
            results['schemas_valid'] += 1
        else:
            results['schemas_invalid'] += 1

            # Add errors to results
            for error in schema_errors:
                if 'warning' in error.lower():
                    results['warnings'].append(f"Schema {i} ({schema_type}): {error}")
                else:
                    results['errors'].append(f"Schema {i} ({schema_type}): {error}")

    return results

def validate_blog_post(content: str) -> Dict:
    """Validate blog post structure and SEO elements"""
    
    results = {
        'word_count': len(content.split()),
        'warnings': [],
        'passed': [],
        'failed': [],
        'score': 0
    }
    
    # Extract title
    title_match = re.search(r'^#\s+(.+)$', content, re.MULTILINE)
    title = title_match.group(1) if title_match else ""
    
    # Check 1: Title length (50-60 chars optimal)
    if 50 <= len(title) <= 60:
        results['passed'].append(f"✓ Title length optimal: {len(title)} chars")
    elif len(title) > 0:
        results['warnings'].append(f"⚠ Title length: {len(title)} chars (target: 50-60)")
    else:
        results['failed'].append("✗ No H1 title found")
    
    # Check 2: H2 headings (4-8 recommended)
    h2_count = len(re.findall(r'^##\s+', content, re.MULTILINE))
    if 4 <= h2_count <= 8:
        results['passed'].append(f"✓ H2 count optimal: {h2_count}")
    else:
        results['warnings'].append(f"⚠ H2 count: {h2_count} (target: 4-8)")
    
    # Check 3: Word count (1,500-3,000 typical)
    word_count = results['word_count']
    if 1500 <= word_count <= 3000:
        results['passed'].append(f"✓ Word count good: {word_count}")
    elif word_count < 1000:
        results['failed'].append(f"✗ Word count too low: {word_count} (min: 1,500)")
    else:
        results['warnings'].append(f"⚠ Word count: {word_count}")
    
    # Check 4: FAQ section
    if "## Frequently Asked Questions" in content or "## FAQ" in content:
        faq_questions = len(re.findall(r'###\s+.*\?', content))
        if faq_questions >= 4:
            results['passed'].append(f"✓ FAQ section with {faq_questions} questions")
        else:
            results['warnings'].append(f"⚠ FAQ section has only {faq_questions} questions (target: 4-8)")
    else:
        results['failed'].append("✗ No FAQ section found")
    
    # Check 5: Internal links (3-5 recommended)
    internal_links = len(re.findall(r'\[.+?\]\((?!http).*?\)', content))
    if 3 <= internal_links <= 5:
        results['passed'].append(f"✓ Internal links: {internal_links}")
    else:
        results['warnings'].append(f"⚠ Internal links: {internal_links} (target: 3-5)")
    
    # Check 6: External links (2-4 recommended)
    external_links = len(re.findall(r'\[.+?\]\(https?://.*?\)', content))
    if 2 <= external_links <= 4:
        results['passed'].append(f"✓ External links: {external_links}")
    else:
        results['warnings'].append(f"⚠ External links: {external_links} (target: 2-4)")
    
    # Check 7: Images
    images = len(re.findall(r'!\[.*?\]\(.*?\)', content))
    if images >= 5:
        results['passed'].append(f"✓ Images: {images}")
    else:
        results['warnings'].append(f"⚠ Images: {images} (target: 5-8)")
    
    # Check 8: Author bio
    if "## About the Author" in content or "**Author:**" in content[:500]:
        results['passed'].append("✓ Author bio present")
    else:
        results['failed'].append("✗ No author bio found")
    
    # Check 9: Table of Contents (for long content)
    if word_count > 1500:
        if "## Table of Contents" in content:
            results['passed'].append("✓ Table of contents present")
        else:
            results['warnings'].append("⚠ Consider adding table of contents (1,500+ words)")
    
    # Check 10: Schema markup validation
    schema_results = validate_all_schemas(content)

    if schema_results['schemas_found'] > 0:
        if schema_results['schemas_invalid'] == 0:
            results['passed'].append(
                f"✓ Schema markup valid ({schema_results['schemas_valid']} schemas)"
            )
        else:
            results['failed'].append(
                f"✗ Schema validation failed ({schema_results['schemas_invalid']} invalid)"
            )
            # Add schema errors to overall results
            results['schema_errors'] = schema_results['errors']

        # Add schema warnings
        if schema_results['warnings']:
            results['schema_warnings'] = schema_results['warnings']
    else:
        results['warnings'].append("⚠ No schema markup found")
    
    # Check 11: Meta description
    if "Meta Description" in content:
        meta_desc = re.search(r'Meta Description.*?:(.+)', content, re.IGNORECASE)
        if meta_desc:
            desc_length = len(meta_desc.group(1).strip())
            if 145 <= desc_length <= 155:
                results['passed'].append(f"✓ Meta description length: {desc_length} chars")
            else:
                results['warnings'].append(f"⚠ Meta description: {desc_length} chars (target: 145-155)")
    
    # Check 12: Readability
    readability = analyze_readability(content)
    if 60 <= readability <= 70:
        results['passed'].append(f"✓ Readability score: {readability:.1f}")
    else:
        results['warnings'].append(f"⚠ Readability: {readability:.1f} (target: 60-70)")
    
    # Calculate overall score
    total_checks = len(results['passed']) + len(results['warnings']) + len(results['failed'])
    if total_checks > 0:
        results['score'] = int((len(results['passed']) / total_checks) * 100)
    
    return results

def print_results(results: Dict):
    """Print validation results"""
    print("\n" + "="*60)
    print(f"SEO/GEO VALIDATION RESULTS")
    print("="*60)
    print(f"\nWord Count: {results['word_count']}")
    print(f"Overall Score: {results['score']}/100")

    if results['passed']:
        print(f"\n✓ PASSED ({len(results['passed'])} checks):")
        for item in results['passed']:
            print(f"  {item}")

    if results['warnings']:
        print(f"\n⚠ WARNINGS ({len(results['warnings'])} items):")
        for item in results['warnings']:
            print(f"  {item}")

    if results['failed']:
        print(f"\n✗ FAILED ({len(results['failed'])} checks):")
        for item in results['failed']:
            print(f"  {item}")

    # Print schema-specific errors if present
    if 'schema_errors' in results and results['schema_errors']:
        print(f"\n🔍 SCHEMA VALIDATION ERRORS:")
        for error in results['schema_errors']:
            print(f"  ✗ {error}")

    # Print schema-specific warnings if present
    if 'schema_warnings' in results and results['schema_warnings']:
        print(f"\n🔍 SCHEMA VALIDATION WARNINGS:")
        for warning in results['schema_warnings']:
            print(f"  {warning}")

    print("\n" + "="*60)

    if results['score'] >= 80:
        print("✓ Excellent! Blog post meets SEO/GEO standards.")
    elif results['score'] >= 60:
        print("⚠ Good, but address warnings for better optimization.")
    else:
        print("✗ Needs improvement. Address failed checks and warnings.")
    print("="*60 + "\n")

def main():
    if len(sys.argv) != 2:
        print("Usage: python validate_structure.py <markdown_file>")
        sys.exit(1)
    
    try:
        with open(sys.argv[1], 'r', encoding='utf-8') as f:
            content = f.read()
        
        results = validate_blog_post(content)
        print_results(results)
        
        # Exit code based on score
        sys.exit(0 if results['score'] >= 60 else 1)
        
    except FileNotFoundError:
        print(f"Error: File '{sys.argv[1]}' not found")
        sys.exit(1)
    except Exception as e:
        print(f"Error: {str(e)}")
        sys.exit(1)

if __name__ == "__main__":
    main()