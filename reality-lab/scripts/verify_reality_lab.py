#!/usr/bin/env python3
"""
verify_reality_lab.py - Verification script for reality-lab directory deliverables.

Checks:
1. Desensitization check: Ensures no real credentials or real IP addresses leak in reality-lab/.
2. Links check: Ensures all local relative file markdown links in reality-lab/ resolve to existing files.
"""

import os
import urllib.parse
import re
import sys

FORBIDDEN_PATTERNS = [
    r"136\.87\.111\.54",
    r"202\.144\.188\.139",
    r"66\.92\.253\.201",
    r"45\.145\.57\.203",
    r"103\.240\.240\.1",
    r"gen-lang-client-0154104520",
    r"hOMryZiAixIC",
    r"8xrzw240",
]

def check_desensitization(base_dir):
    errors = []
    for root, dirs, files in os.walk(base_dir):
        for file in files:
            filepath = os.path.join(root, file)
            # Skip python verification script itself and binary files
            if file == "verify_reality_lab.py" or file.endswith(('.png', '.jpg', '.tar.gz', '.tgz')):
                continue
            try:
                with open(filepath, 'r', encoding='utf-8') as f:
                    content = f.read()
                    for pattern in FORBIDDEN_PATTERNS:
                        matches = re.findall(pattern, content)
                        if matches:
                            errors.append(f"Forbidden pattern '{pattern}' found in {filepath}")
            except Exception as e:
                errors.append(f"Could not read {filepath}: {e}")
    return errors

def check_links(base_dir):
    errors = []
    link_pattern = re.compile(r'\[([^\]]+)\]\(([^)]+)\)')
    for root, dirs, files in os.walk(base_dir):
        for file in files:
            if not file.endswith('.md'):
                continue
            filepath = os.path.join(root, file)
            with open(filepath, 'r', encoding='utf-8') as f:
                content = f.read()
                matches = link_pattern.findall(content)
                for text, target in matches:
                    if target.startswith('http://') or target.startswith('https://') or target.startswith('#'):
                        continue
                    # URL decode target path (e.g., %20 -> space)
                    decoded_target = urllib.parse.unquote(target)
                    target_path = os.path.normpath(os.path.join(os.path.dirname(filepath), decoded_target.split('#')[0]))
                    if not os.path.exists(target_path):
                        errors.append(f"Broken link in {filepath}: '{target}' (resolved to '{target_path}')")
    return errors

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    reality_lab_dir = os.path.dirname(script_dir)
    print(f"Verifying deliverables in: {reality_lab_dir}")

    desens_errors = check_desensitization(reality_lab_dir)
    link_errors = check_links(reality_lab_dir)

    all_errors = desens_errors + link_errors
    if all_errors:
        print("Verification FAILED with the following errors:")
        for err in all_errors:
            print(f" - {err}")
        sys.exit(1)
    else:
        print("ALL VERIFICATIONS PASSED SUCCESSFULLY!")

if __name__ == "__main__":
    main()
