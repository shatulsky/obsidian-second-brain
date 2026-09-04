#!/usr/bin/env python3
"""validate-ai-first.py - Enforce the AI-first vault rule on Write/Edit (Windows).

Python port of validate-ai-first.sh, created 2026-07-05. History: settings.json
referenced a non-existent validate-ai-first.ps1, so every Write/Edit printed
"failed with non-blocking status code" noise with zero validation. A PS 5.1 port
was written first but powershell.exe hangs reading piped stdin (console-host
quirk, reproduced with minimal probes) - Python reads hook stdin reliably.

Checks (same as the .sh): frontmatter delimiters, no tabs in frontmatter,
required fields (date/type/tags/ai-first), '## For future Claude' preamble,
banned non-ASCII substitution characters, secret material (private keys,
AWS/GitHub/Slack/Google API keys, quoted passwords - ported from the .sh's
v0.14.0 check 6), and Obsidian tag syntax (ported from the .sh's v0.15.0
check 7 - the .sh's own implementation of this check is itself Python,
shelled out via `python3 -`; re-implemented natively here against the
already-parsed `fm` lines instead of re-parsing the raw frontmatter text).

Vault-convention exceptions (per this vault's _CLAUDE.md, added in this port):
  - Daily/     : only date + tags required (Section 5) - preamble still checked
  - Logs/      : skipped entirely (minimal frontmatter by design)
  - log.md     : skipped (pointer file)
  - catchup.md : skipped (bot-written queue)

Exit codes:
  0 = pass / out of scope (silent)
  2 = warnings on stderr (PostToolUse: fed back to Claude for same-turn repair;
      the write is never reverted)
"""
import json
import os
import re
import sys

SECRET_PATTERNS = [
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "private key block"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "AWS access key id"),
    (re.compile(r"\bsk-[A-Za-z0-9_-]{24,}\b"), "sk- API key"),
    (re.compile(r"\bghp_[A-Za-z0-9]{36}\b"), "GitHub personal token"),
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{22,}\b"), "GitHub fine-grained token"),
    (re.compile(r"\bxox[bpars]-[A-Za-z0-9-]{10,}\b"), "Slack token"),
    (re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b"), "Google API key"),
    (re.compile(r"(?i)\b(?:password|passwd)\s*[:=]\s*['\"][^'\"\s]{8,}['\"]"), "quoted password assignment"),
]

TAG_ALLOWED = re.compile(r"^[\w/-]+$", re.UNICODE)   # \w is Unicode-aware: letters, digits, underscore
TAG_HAS_NON_DIGIT = re.compile(r"[^\d/]")


def _tags_from_frontmatter(fm: list) -> list:
    """Mirrors the .sh's v0.15.0 check 7 tag extraction: inline `[a, b]`,
    scalar, and block `- item` forms. Only the first `tags:` line is read -
    same as upstream."""
    for i, line in enumerate(fm):
        m = re.match(r"^tags:\s*(.*)$", line)
        if not m:
            continue
        rest = m.group(1).strip()
        if rest.startswith('['):
            inner = rest.strip('[]')
            return [t.strip().strip("'\"") for t in inner.split(',') if t.strip()]
        if rest:
            return [rest.strip("'\"")]
        tags = []
        for nxt in fm[i + 1:]:
            lm = re.match(r"^\s+-\s*(.+?)\s*$", nxt)
            if not lm:
                break
            tags.append(lm.group(1).strip().strip("'\""))
        return tags
    return []


def _tag_problem(tag: str):
    """Same rule as the .sh/vault_health.py check_tag_syntax - keep all three in step."""
    t = tag.lstrip('#')
    if not t:
        return 'empty tag'
    if ' ' in t or '\t' in t:
        return 'contains whitespace (Obsidian cannot render it) - use `-` between words'
    if '.' in t:
        return 'contains `.` (Obsidian cannot render it) - use `-` or spell it out'
    if not TAG_ALLOWED.match(t):
        return 'contains characters outside letters/digits/_/-// (Obsidian cannot render it)'
    if not TAG_HAS_NON_DIGIT.search(t):
        return f'is digits only (Obsidian renders it struck through) - prefix a word, e.g. `store-{t}`'
    return None


BANNED = {
    '—': ('U+2014 em-dash', ' - '),
    '–': ('U+2013 en-dash', ' - '),
    '“': ('U+201C left double quote', '"'),
    '”': ('U+201D right double quote', '"'),
    '‘': ('U+2018 left single quote', "'"),
    '’': ('U+2019 right single quote', "'"),
    '≥': ('U+2265 >=', '>='),
    '≤': ('U+2264 <=', '<='),
    '≠': ('U+2260 !=', '!='),
    '…': ('U+2026 ellipsis', '...'),
    ' ': ('U+00A0 non-breaking space', ' '),
}


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0

    tool_input = payload.get('tool_input') or payload.get('args') or {}
    file_path = tool_input.get('file_path') or ''
    if not file_path:
        return 0

    file_path = file_path.replace('\\', '/')
    if not file_path.lower().endswith('.md') or not os.path.isfile(file_path):
        return 0

    vault = (os.environ.get('OBSIDIAN_VAULT_PATH') or '').replace('\\', '/')
    if not vault:
        return 0
    if not file_path.lower().startswith(vault.lower() + '/'):
        return 0

    rel = file_path[len(vault) + 1:]
    parts = rel.split('/')
    skip_dirs = {'raw', 'templates', '_export', '.obsidian', '.git', '.trash', 'Logs'}
    if any(p in skip_dirs for p in parts[:-1]):
        return 0
    if rel.lower() in ('log.md', 'catchup.md'):
        return 0
    is_daily = parts[0] == 'Daily'

    basename = os.path.basename(file_path)
    try:
        with open(file_path, encoding='utf-8-sig', errors='replace') as fh:
            lines = fh.read().splitlines()
    except OSError:
        return 0

    warnings = []

    # Check 1: frontmatter delimiters
    if not lines or lines[0].rstrip() != '---':
        sys.stderr.write(
            f'AI-first warning: {basename} has no frontmatter (expected --- on the '
            f'first line). AI-first notes need date/type/tags/ai-first metadata.\n')
        return 2

    close_idx = next((i for i in range(1, len(lines)) if lines[i].rstrip() == '---'), -1)
    if close_idx < 0:
        warnings.append(f'{basename} frontmatter is missing the closing --- delimiter.')
        fm, body = [], []
    else:
        fm = lines[1:close_idx]
        body = lines[close_idx + 1:]

    # Check 2: tabs in frontmatter
    if any('\t' in line for line in fm):
        warnings.append(f'{basename} frontmatter contains tab characters. YAML requires spaces only.')

    # Check 3: required AI-first fields
    def has_field(key: str) -> bool:
        return any(line.startswith(key + ':') for line in fm)

    if not has_field('date'):
        warnings.append(f"{basename} missing 'date:' in frontmatter.")
    if not has_field('tags'):
        warnings.append(f"{basename} missing 'tags:' in frontmatter.")
    if not is_daily:
        if not has_field('type'):
            warnings.append(f"{basename} missing 'type:' in frontmatter.")
        if not any(line.split('#')[0].strip() == 'ai-first: true' for line in fm):
            warnings.append(f"{basename} missing 'ai-first: true' in frontmatter.")

    # Check 4: 'For future <agent|AI|Claude|Codex>' preamble - v0.15.0 widened the
    # accepted spelling from Claude-only to any of the four; this vault's own
    # convention (_CLAUDE.md) still asks for 'For future Claude' by default, but
    # all four are accepted here so the hook doesn't false-positive-warn on either
    # spelling.
    PREAMBLE_LABELS = ('For future agent', 'For future AI', 'For future Claude', 'For future Codex')
    if not any(line.startswith('## ') and line[3:].lstrip().startswith(PREAMBLE_LABELS)
               for line in body):
        warnings.append(
            f"{basename} missing a '## For future <agent|AI|Claude|Codex>' preamble "
            f'(required by ai-first-rules.md rule #2).')

    # Check 5: banned non-ASCII substitution characters
    hits = []
    for lineno, line in enumerate(lines, 1):
        seen_on_line = set()
        for ch in line:
            if ch in BANNED and ch not in seen_on_line:
                seen_on_line.add(ch)
                name, suggest = BANNED[ch]
                hits.append(f'    line {lineno}: {name} -- try {suggest!r}')
    if hits:
        warnings.append(f'{basename} contains banned non-ASCII substitution characters:')
        warnings.extend(hits)

    # Check 6: secrets never belong in a vault note (high-precision patterns only -
    # a false positive here trains people to ignore the hook)
    secret_hits = []
    for lineno, line in enumerate(lines, 1):
        for pat, label in SECRET_PATTERNS:
            if pat.search(line):
                secret_hits.append(
                    f'    line {lineno}: looks like a {label} - secrets never belong in '
                    f'vault notes; keep them in ~/.config/obsidian-second-brain/.env or a '
                    f'password manager and reference them by NAME only')
                break
    if secret_hits:
        warnings.append(f'{basename} appears to contain secret material:')
        warnings.extend(secret_hits)

    # Check 7: Obsidian tag syntax (v0.15.0) - a tag Obsidian can't render is
    # struck through with no error anywhere, so this is the only place an
    # agent would ever learn it wrote one.
    tag_hits = []
    for tag in _tags_from_frontmatter(fm):
        why = _tag_problem(tag)
        if why:
            tag_hits.append(f'    tag `{tag}` {why}')
    if tag_hits:
        warnings.append(f'{basename} has tags Obsidian will render broken (no error is ever shown for these):')
        warnings.extend(tag_hits)

    if warnings:
        sys.stderr.write(f'AI-first warnings on {basename}:\n')
        for w in warnings:
            sys.stderr.write(f'  - {w}\n')
        sys.stderr.write('\nSee references/ai-first-rules.md for the full spec.\n')
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
