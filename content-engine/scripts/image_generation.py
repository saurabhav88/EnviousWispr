#!/usr/bin/env python3
"""
Automated Image Generation for Blog Posts

APIs supported:
- Google Imagen (priority 1 - $2000 startup credit)
- OpenAI DALL-E 3 (priority 2 - Microsoft Startup Hub credits)

Image types:
- Featured/hero images (photorealistic)
- Section illustrations (illustration/vector)
- Diagrams/infographics (technical diagrams)
"""

import os
import re
import sys
import requests
from pathlib import Path
from typing import List, Dict, Optional, Tuple
from dataclasses import dataclass
from enum import Enum
import hashlib
from datetime import datetime

# Import config loader
try:
    from config_loader import ConfigLoader
except ImportError:
    # Fallback if not in same directory
    sys.path.insert(0, str(Path(__file__).parent))
    from config_loader import ConfigLoader


class ImageType(Enum):
    """Image type classification"""
    FEATURED = "featured"
    SECTION = "section"
    DIAGRAM = "diagram"


class ImageStyle(Enum):
    """Image style preferences"""
    PHOTOREALISTIC = "photorealistic"
    ILLUSTRATION = "illustration"
    DIAGRAM = "diagram"


@dataclass
class ImageRequest:
    """Image generation request"""
    type: ImageType
    alt_text: str
    context: str  # Surrounding text for context
    style: ImageStyle
    section_heading: Optional[str] = None


@dataclass
class GeneratedImage:
    """Generated image metadata"""
    local_path: Path
    alt_text: str
    url: Optional[str]  # Original API URL
    prompt_used: str
    cost: float
    api_used: str


class ImageGenerator:
    """Abstract base for image generation APIs"""

    def __init__(self, api_key: str = None):
        self.api_key = api_key
        self.cost_per_image = 0.0

    def generate(self, request: ImageRequest, output_dir: Path) -> GeneratedImage:
        """Generate image from request"""
        raise NotImplementedError

    def is_available(self) -> bool:
        """Check if API is configured"""
        raise NotImplementedError


class GoogleImagenGenerator(ImageGenerator):
    """
    Google Imagen API generator via Vertex AI

    Authentication:
    - Option 1 (Recommended): gcloud application-default login
    - Option 2 (CI/CD): Service account JSON file via GOOGLE_APPLICATION_CREDENTIALS

    Cost: $0.02 per image
    Content Safety: Implements automatic word filtering to avoid safety filter blocks
    """

    def __init__(self, api_key: str = None, project_id: str = None):
        # Note: api_key parameter is for service account JSON file path (optional)
        # Authentication can also use gcloud application-default credentials
        super().__init__(api_key or os.getenv('GOOGLE_API_KEY'))
        self.project_id = project_id or os.getenv('GOOGLE_PROJECT_ID')
        self.cost_per_image = 0.02  # $0.02 per image

        if self.project_id:
            self.endpoint = f"https://us-central1-aiplatform.googleapis.com/v1/projects/{self.project_id}/locations/us-central1/publishers/google/models/imagegeneration@006:predict"
        else:
            self.endpoint = None

    def is_available(self) -> bool:
        """Check if API is configured (only project_id required for gcloud auth)"""
        return bool(self.project_id)

    def generate(self, request: ImageRequest, output_dir: Path) -> GeneratedImage:
        """
        Generate image using Google Imagen

        Uses Vertex AI Imagen 3 API
        """
        if not self.is_available():
            raise ValueError("Google Imagen not configured (missing project ID or gcloud auth not set up)")

        try:
            from google.cloud import aiplatform
            from vertexai.preview.vision_models import ImageGenerationModel
        except ImportError:
            raise ImportError(
                "Google AI Platform library not installed. Install: pip install google-cloud-aiplatform"
            )

        # Create prompt based on type and style
        prompt = self._create_prompt(request)

        print(f"    [Google Imagen] Generating: {request.alt_text[:50]}...", file=sys.stderr)
        print(f"    [Google Imagen] Prompt: {prompt[:100]}...", file=sys.stderr)

        try:
            # Set credentials if API key is provided (path to JSON file)
            # Otherwise, use gcloud application-default credentials
            if self.api_key and os.path.isfile(self.api_key):
                os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = self.api_key

            # Initialize Vertex AI
            aiplatform.init(
                project=self.project_id,
                location="us-central1"
            )

            # Load Imagen model
            model = ImageGenerationModel.from_pretrained("imagegeneration@006")

            # Determine image size based on type
            if request.type == ImageType.FEATURED:
                # Wider aspect ratio for hero images
                aspect_ratio = "16:9"
            else:
                # Square for section/diagram images
                aspect_ratio = "1:1"

            # Generate image
            response = model.generate_images(
                prompt=prompt,
                number_of_images=1,
                aspect_ratio=aspect_ratio,
                safety_filter_level="block_some",
                person_generation="allow_adult"
            )

            # Get the generated image
            if not response.images:
                raise ValueError("No images generated by Imagen API")

            image = response.images[0]

            # Save to file
            filename = self._generate_filename(request)
            local_path = output_dir / filename

            # Save image bytes
            image.save(location=str(local_path))

            print(f"    ✓ Generated: {local_path.name}", file=sys.stderr)

            return GeneratedImage(
                local_path=local_path,
                alt_text=request.alt_text,
                url=None,  # Imagen doesn't provide URL
                prompt_used=prompt,
                cost=self.cost_per_image,
                api_used='google_imagen'
            )

        except Exception as e:
            print(f"    ✗ Google Imagen error: {e}", file=sys.stderr)
            raise

    def _create_prompt(self, request: ImageRequest) -> str:
        """
        Create Imagen-optimized prompt

        Avoids triggering content safety filters by:
        - Focusing on abstract visual concepts
        - Avoiding sensitive keywords (manipulation, abuse, etc.)
        - Using neutral, professional language
        """
        # Filter out potentially sensitive words
        sensitive_words = ['gaslighting', 'manipulation', 'manipulating', 'abuse', 'abusive',
                          'toxic', 'narcissist', 'victim', 'trauma', 'confused', 'control']

        # Clean alt text
        safe_alt = request.alt_text.lower()
        for word in sensitive_words:
            safe_alt = safe_alt.replace(word, '')

        # Create abstract visual description based on type
        if request.type == ImageType.FEATURED:
            visual_desc = "Professional hero image for a mental health and wellness blog"
        elif request.style == ImageStyle.DIAGRAM:
            visual_desc = "Educational diagram showing relationship dynamics and communication patterns"
        else:
            visual_desc = "Modern illustration for psychology and relationships content"

        style_prompts = {
            ImageStyle.PHOTOREALISTIC: "Photorealistic professional photography, soft lighting, warm tones, high quality, calming atmosphere",
            ImageStyle.ILLUSTRATION: "Modern digital illustration, clean vector art style, professional design, soft colors, minimalist",
            ImageStyle.DIAGRAM: "Clean infographic style, educational diagram, simple icons, professional layout, clear typography"
        }

        style_text = style_prompts.get(request.style, "")

        # Combine with safe, abstract description
        prompt = f"{visual_desc}. {style_text}. Represents themes of self-awareness and healthy relationships."

        return prompt[:1000]  # Imagen limit

    def _generate_filename(self, request: ImageRequest) -> str:
        """Generate unique filename"""
        hash_input = f"{request.alt_text}_{request.context[:50]}_{datetime.now().isoformat()}"
        hash_suffix = hashlib.md5(hash_input.encode()).hexdigest()[:8]

        safe_name = re.sub(r'[^a-z0-9]+', '_', request.alt_text.lower())
        return f"{safe_name}_{hash_suffix}.png"


class OpenAIDallEGenerator(ImageGenerator):
    """OpenAI DALL-E 3 generator"""

    def __init__(self, api_key: str = None):
        super().__init__(api_key or os.getenv('OPENAI_API_KEY'))
        self.cost_per_image = 0.04  # $0.04 for standard, $0.08 for HD
        self.quality = "standard"  # or "hd"

    def is_available(self) -> bool:
        """Check if API key is configured"""
        return bool(self.api_key)

    def generate(self, request: ImageRequest, output_dir: Path) -> GeneratedImage:
        """
        Generate image using DALL-E 3

        API: https://platform.openai.com/docs/guides/images/usage
        """
        if not self.is_available():
            raise ValueError("OpenAI API key not configured")

        try:
            from openai import OpenAI
        except ImportError:
            raise ImportError(
                "OpenAI library not installed. Install: pip install openai"
            )

        client = OpenAI(api_key=self.api_key)

        # Create prompt
        prompt = self._create_prompt(request)

        print(f"    [DALL-E 3] Generating: {request.alt_text[:50]}...", file=sys.stderr)
        print(f"    [DALL-E 3] Prompt: {prompt[:100]}...", file=sys.stderr)

        # Generate image
        try:
            response = client.images.generate(
                model="dall-e-3",
                prompt=prompt,
                size="1792x1024" if request.type == ImageType.FEATURED else "1024x1024",
                quality=self.quality,
                n=1
            )

            image_url = response.data[0].url

            # Download image
            image_response = requests.get(image_url, timeout=30)
            image_response.raise_for_status()

            filename = self._generate_filename(request)
            local_path = output_dir / filename

            with open(local_path, 'wb') as f:
                f.write(image_response.content)

            print(f"    ✓ Generated: {local_path.name}", file=sys.stderr)

            return GeneratedImage(
                local_path=local_path,
                alt_text=request.alt_text,
                url=image_url,
                prompt_used=prompt,
                cost=self.cost_per_image if self.quality == "standard" else 0.08,
                api_used='openai_dalle3'
            )

        except Exception as e:
            print(f"    ✗ DALL-E 3 error: {e}", file=sys.stderr)
            raise

    def _create_prompt(self, request: ImageRequest) -> str:
        """Create DALL-E optimized prompt"""
        base = request.context[:200]

        style_prompts = {
            ImageStyle.PHOTOREALISTIC: "Photorealistic professional photograph, high quality, detailed, 4K",
            ImageStyle.ILLUSTRATION: "Modern digital illustration, vector art style, clean lines, professional design",
            ImageStyle.DIAGRAM: "Technical infographic, clean diagram style, educational illustration, minimalist"
        }

        style_text = style_prompts.get(request.style, "")

        # DALL-E 3 works best with clear, descriptive prompts
        prompt = f"{style_text}. Create an image for a blog post about: {base}. The image should represent: {request.alt_text}"

        return prompt[:1000]

    def _generate_filename(self, request: ImageRequest) -> str:
        """Generate unique filename"""
        hash_input = f"{request.alt_text}_{request.context[:50]}_{datetime.now().isoformat()}"
        hash_suffix = hashlib.md5(hash_input.encode()).hexdigest()[:8]

        safe_name = re.sub(r'[^a-z0-9]+', '_', request.alt_text.lower())
        return f"{safe_name}_{hash_suffix}.png"


class BlogImageGenerator:
    """High-level blog image generation orchestrator"""

    def __init__(self,
                 google_api_key: str = None,
                 google_project_id: str = None,
                 openai_api_key: str = None,
                 output_dir: Path = None,
                 config_path: Path = None):
        """
        Initialize blog image generator

        Args:
            google_api_key: Path to Google service account JSON file (optional, CLI override)
                           If not provided, uses gcloud application-default credentials
            google_project_id: Google project ID (required for Google Imagen, CLI override)
            openai_api_key: OpenAI API key (required for DALL-E 3, CLI override)
            output_dir: Image output directory (CLI override)
            config_path: Path to .seo-geo-config.json
        """
        # Load config
        config = ConfigLoader(config_path)
        image_config = config.get_image_generation_config()
        google_config = config.get_google_imagen_config(google_api_key, google_project_id)
        openai_config = config.get_openai_config(openai_api_key)

        self.output_dir = output_dir or Path(image_config['output_dir'])
        self.output_dir.mkdir(parents=True, exist_ok=True)

        # Initialize generators in priority order
        self.generators = []

        # Priority 1: Google Imagen ($2000 credit)
        google = GoogleImagenGenerator(google_config['api_key'], google_config['project_id'])
        if google.is_available():
            self.generators.append(google)
            print(f"✓ Google Imagen configured (priority 1)", file=sys.stderr)

        # Priority 2: OpenAI DALL-E (Microsoft credits)
        openai_gen = OpenAIDallEGenerator(openai_config['api_key'])
        if openai_gen.is_available():
            self.generators.append(openai_gen)
            print(f"✓ OpenAI DALL-E 3 configured (priority {2 if google.is_available() else 1})", file=sys.stderr)

        if not self.generators:
            raise ValueError("No image generation APIs configured")

    def extract_image_needs(self, draft_content: str) -> List[ImageRequest]:
        """
        Extract image placeholders from draft

        Looks for:
        - ![Alt text](placeholder)
        - ![Alt text](image-placeholder)
        - Auto-detects sections needing images
        """
        requests = []

        # Extract existing image placeholders
        placeholders = re.findall(r'!\[([^\]]+)\]\((placeholder|image-placeholder|image-\d+)\)', draft_content)

        for alt_text, _ in placeholders:
            # Find context (surrounding text)
            context = self._get_context_for_image(draft_content, alt_text)

            # Determine type and style from alt text
            alt_lower = alt_text.lower()

            if "featured" in alt_lower or "hero" in alt_lower:
                img_type = ImageType.FEATURED
                style = ImageStyle.PHOTOREALISTIC
            elif "diagram" in alt_lower or "infographic" in alt_lower or "workflow" in alt_lower:
                img_type = ImageType.DIAGRAM
                style = ImageStyle.DIAGRAM
            else:
                img_type = ImageType.SECTION
                style = ImageStyle.ILLUSTRATION

            requests.append(ImageRequest(
                type=img_type,
                alt_text=alt_text,
                context=context,
                style=style
            ))

        # Auto-detect: Add featured image if none exists
        if not any(r.type == ImageType.FEATURED for r in requests):
            # Use title as featured image
            title_match = re.search(r'^# (.+)$', draft_content, re.MULTILINE)
            if title_match:
                title = title_match.group(1)
                requests.insert(0, ImageRequest(
                    type=ImageType.FEATURED,
                    alt_text=f"Featured image: {title}",
                    context=draft_content[:500],
                    style=ImageStyle.PHOTOREALISTIC
                ))

        return requests

    def generate_images(self,
                        draft_content: str,
                        max_images: int = 5) -> Tuple[str, List[GeneratedImage]]:
        """
        Generate all needed images and insert into draft

        Returns:
            Tuple of (updated_draft, generated_images)
        """
        # Extract needs
        requests = self.extract_image_needs(draft_content)

        if not requests:
            print("ℹ️  No image placeholders found", file=sys.stderr)
            return draft_content, []

        # Limit to max_images
        requests = requests[:max_images]

        print(f"\n🎨 Generating {len(requests)} images...\n", file=sys.stderr)

        generated = []
        total_cost = 0.0

        for i, request in enumerate(requests, 1):
            print(f"[{i}/{len(requests)}] {request.alt_text}", file=sys.stderr)

            # Try generators in priority order
            for generator in self.generators:
                try:
                    image = generator.generate(request, self.output_dir)
                    generated.append(image)
                    total_cost += image.cost
                    break

                except NotImplementedError as e:
                    # Google Imagen not implemented, fall through to DALL-E
                    print(f"    ⚠ {generator.__class__.__name__}: {e}", file=sys.stderr)
                    continue
                except Exception as e:
                    print(f"    ✗ {generator.__class__.__name__} failed: {e}", file=sys.stderr)
                    continue

        print(f"\n✓ Generated {len(generated)}/{len(requests)} images (cost: ${total_cost:.2f})\n", file=sys.stderr)

        # Insert images into draft
        updated_draft = self._insert_images(draft_content, generated, requests)

        return updated_draft, generated

    def _get_context_for_image(self, content: str, alt_text: str) -> str:
        """Get surrounding text context for image"""
        # Find image placeholder
        pattern = re.escape(f"![{alt_text}]")
        match = re.search(pattern, content)

        if match:
            start = max(0, match.start() - 200)
            end = min(len(content), match.end() + 200)
            return content[start:end]

        return content[:500]  # Default to intro

    def _insert_images(self,
                       draft: str,
                       images: List[GeneratedImage],
                       requests: List[ImageRequest]) -> str:
        """Insert generated images into draft"""
        updated = draft

        for image, request in zip(images, requests):
            # Replace placeholder with actual image
            # Try multiple placeholder patterns
            patterns = [
                re.escape(f"![{request.alt_text}](placeholder)"),
                re.escape(f"![{request.alt_text}](image-placeholder)"),
                re.escape(f"![{request.alt_text}]") + r'\(image-\d+\)',
            ]

            replaced = False
            for pattern in patterns:
                if re.search(pattern, updated):
                    replacement = f"![{image.alt_text}]({image.local_path})"
                    updated = re.sub(pattern, replacement, updated, count=1)
                    replaced = True
                    break

            if not replaced:
                print(f"    ⚠ Could not find placeholder for: {request.alt_text}", file=sys.stderr)

        return updated


def main():
    """CLI interface"""
    import argparse

    parser = argparse.ArgumentParser(
        description="Generate blog post images using AI",
        epilog="""
Examples:
  # With OpenAI DALL-E 3 (easiest to set up):
  export OPENAI_API_KEY=sk-...
  python image_generation.py draft.md --output draft-with-images.md

  # With Google Imagen (requires Google Cloud setup):
  export GOOGLE_API_KEY=...
  export GOOGLE_PROJECT_ID=my-project
  python image_generation.py draft.md --output draft-with-images.md

  # Custom output directory:
  python image_generation.py draft.md \\
    --output draft-with-images.md \\
    --output-dir ./blog-images
        """
    )
    parser.add_argument("draft", type=Path, help="Draft blog post file")
    parser.add_argument("--max-images", type=int, default=5, help="Max images to generate (default: 5)")
    parser.add_argument("--output", type=Path, help="Save updated draft to file")
    parser.add_argument("--output-dir", type=Path, help="Image output directory (default: ./generated_images)")
    parser.add_argument("--dry-run", action="store_true", help="Extract image needs without generating (no API keys required)")

    # API credentials
    parser.add_argument("--google-api-key", help="Path to Google service account JSON (optional, uses gcloud auth if not provided)")
    parser.add_argument("--google-project-id", help="Google project ID (required for Google Imagen, or set GOOGLE_PROJECT_ID)")
    parser.add_argument("--openai-api-key", help="OpenAI API key (required for DALL-E 3, or set OPENAI_API_KEY)")

    args = parser.parse_args()

    # Validate draft file
    if not args.draft.exists():
        print(f"Error: Draft file not found: {args.draft}", file=sys.stderr)
        sys.exit(1)

    # Load draft
    with open(args.draft, 'r', encoding='utf-8') as f:
        draft_content = f.read()

    # Dry-run mode: extract image needs without API
    if args.dry_run:
        print("🔍 DRY-RUN MODE: Extracting image needs...\n")
        print(f"{'='*60}")

        # Create a minimal generator for extraction only
        temp_generator = BlogImageGenerator.__new__(BlogImageGenerator)
        temp_generator.generators = []
        temp_generator.output_dir = args.output_dir or Path("./generated_images")

        requests = temp_generator.extract_image_needs(draft_content)

        if not requests:
            print("No image placeholders found in draft.\n")
            print("Add placeholders like: ![Alt text](placeholder)\n")
            sys.exit(0)

        print(f"Found {len(requests)} image placeholder(s):\n")
        for i, req in enumerate(requests[:args.max_images], 1):
            print(f"{i}. Type: {req.type.value} | Style: {req.style.value}")
            print(f"   Alt: {req.alt_text}")
            if req.section_heading:
                print(f"   Section: {req.section_heading}")
            print(f"   Context: {req.context[:100]}...")
            print()

        if len(requests) > args.max_images:
            print(f"⚠️  Only first {args.max_images} images would be generated (use --max-images to change)\n")

        print(f"{'='*60}")
        print("\nTo generate images, run without --dry-run and configure an API key.\n")
        sys.exit(0)

    # Initialize generator
    try:
        generator = BlogImageGenerator(
            google_api_key=args.google_api_key,
            google_project_id=args.google_project_id,
            openai_api_key=args.openai_api_key,
            output_dir=args.output_dir
        )
    except ValueError as e:
        print(f"\n❌ {e}\n", file=sys.stderr)
        print("Configure at least one API:\n", file=sys.stderr)
        print("Option 1 - OpenAI DALL-E 3 (easiest):", file=sys.stderr)
        print("  export OPENAI_API_KEY=sk-...", file=sys.stderr)
        print("  Or: --openai-api-key sk-...\n", file=sys.stderr)
        print("Option 2 - Google Imagen (requires Google Cloud auth):", file=sys.stderr)
        print("  gcloud auth application-default login", file=sys.stderr)
        print("  export GOOGLE_PROJECT_ID=my-project", file=sys.stderr)
        print("  Or: --google-project-id my-project\n", file=sys.stderr)
        sys.exit(1)

    # Generate images
    updated_draft, images = generator.generate_images(draft_content, args.max_images)

    # Summary
    print(f"{'='*60}")
    print("IMAGE GENERATION SUMMARY")
    print(f"{'='*60}\n")

    for img in images:
        print(f"✓ {img.alt_text}")
        print(f"  File: {img.local_path}")
        print(f"  API: {img.api_used}")
        print(f"  Cost: ${img.cost:.2f}")
        print(f"  Prompt: {img.prompt_used[:80]}...")
        print()

    total_cost = sum(img.cost for img in images)
    print(f"Total cost: ${total_cost:.2f}")
    print(f"{'='*60}\n")

    # Save updated draft
    if args.output:
        with open(args.output, 'w', encoding='utf-8') as f:
            f.write(updated_draft)
        print(f"✓ Updated draft saved to: {args.output}\n")
    else:
        # Print to stdout
        print(updated_draft)


if __name__ == "__main__":
    main()
