#!/usr/bin/env python3
"""
Setup script for DataForSEO API credentials

Creates config file at ~/.dataforseo-skill/config.json
Following Claude Skills credential management best practices.

Usage:
    python setup_credentials.py
"""

import json
import os
import sys
from pathlib import Path
try:
    import getpass
except ImportError:
    getpass = None


def setup_config():
    """Interactive setup for DataForSEO API credentials"""
    config_dir = Path.home() / '.dataforseo-skill'
    config_file = config_dir / 'config.json'
    
    print("=" * 60)
    print("DataForSEO API Credential Setup")
    print("=" * 60)
    print()
    print("This will create a config file at:")
    print(f"  {config_file}")
    print()
    
    # Check if config already exists
    if config_file.exists():
        print("⚠ Config file already exists!")
        response = input("Overwrite? (y/N): ").strip().lower()
        if response != 'y':
            print("Cancelled.")
            return
        
        # Show current config (masked)
        try:
            with open(config_file, 'r') as f:
                current = json.load(f)
                api_key = current.get('api_key', '')
                if api_key:
                    masked = api_key[:10] + '...' if len(api_key) > 10 else '***'
                    print(f"Current API key: {masked}")
        except:
            pass
    
    print()
    print("Enter your DataForSEO API credentials:")
    print("Format options:")
    print("  1. Plain text: login:password")
    print("  2. Base64-encoded: [base64 string from DataForSEO]")
    print("Example: username@example.com:your_password")
    print()
    
    if getpass:
        api_key = getpass.getpass("API Key: ")
    else:
        api_key = input("API Key: ")
    
    if not api_key or not api_key.strip():
        print("No API key provided. Cancelled.")
        return
    
    api_key = api_key.strip()
    
    # Check if it's Base64 encoded (try to decode)
    is_base64 = False
    try:
        import base64
        decoded_bytes = base64.b64decode(api_key, validate=True)
        decoded = decoded_bytes.decode('utf-8')
        if ':' in decoded:
            print(f"✓ Detected Base64-encoded credentials")
            print(f"  Decoded format: {decoded[:20]}...")
            is_base64 = True
    except Exception:
        pass
    
    # Validate format (should contain ':' or be valid Base64)
    if not is_base64 and ':' not in api_key:
        print("⚠ Warning: API key should be in format 'login:password' or Base64-encoded")
        response = input("Continue anyway? (y/N): ").strip().lower()
        if response != 'y':
            print("Cancelled.")
            return
    
    # Create config directory
    config_dir.mkdir(parents=True, exist_ok=True)
    
    # Create config file
    config = {
        "api_key": api_key,
        "created_by": "setup_credentials.py"
    }
    
    try:
        with open(config_file, 'w') as f:
            json.dump(config, f, indent=2)
        
        # Set restrictive permissions (owner read/write only)
        os.chmod(config_file, 0o600)
        
        print()
        print("✓ Config file created successfully!")
        print(f"  Location: {config_file}")
        print()
        print("You can now use the keyword research script without passing credentials:")
        print("  python scripts/keyword_research.py \"your topic\" --limit 5")
        print()
        
    except Exception as e:
        print(f"✗ Error creating config file: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    try:
        setup_config()
    except KeyboardInterrupt:
        print("\n\nCancelled.")
        sys.exit(0)

