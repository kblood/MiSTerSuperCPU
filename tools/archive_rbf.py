"""Archive a built C64.rbf into builds/ keyed by commit + timestamp + md5.

Called automatically by build_c64.ps1 after a successful build, but can also
be run manually:

    python tools/archive_rbf.py [<rbf_path>]

Default <rbf_path> = C64_MiSTer/output_files/C64.rbf.

Archive layout:
    C64_MiSTer/builds/
      C64_<branch>_<shortsha>_<utc>_<md5short>.rbf
      C64_<branch>_<shortsha>_<utc>_<md5short>.json   (metadata)
      INDEX.md                                          (one-line-per-build index)

The .rbf files are .gitignored by default (large binaries), but INDEX.md
plus the .json metadata files are committed so the history is queryable.

This is in response to losing v342's RBF after only v347 was deployed —
without an archive, you can't quickly fall back to a known-working build.
"""
import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BUILDS = REPO / 'C64_MiSTer' / 'builds'
DEFAULT_RBF = REPO / 'C64_MiSTer' / 'output_files' / 'C64.rbf'


def git(*args, default=''):
    try:
        r = subprocess.run(['git'] + list(args), cwd=REPO, capture_output=True, text=True, timeout=15)
        return r.stdout.strip() if r.returncode == 0 else default
    except Exception:
        return default


def main(argv):
    rbf = Path(argv[1]) if len(argv) > 1 else DEFAULT_RBF
    if not rbf.exists():
        print('ERROR: rbf not found: %s' % rbf, file=sys.stderr)
        return 2

    md5 = hashlib.md5(rbf.read_bytes()).hexdigest()
    md5short = md5[:8]
    branch = git('rev-parse', '--abbrev-ref', 'HEAD', default='detached')
    sha = git('rev-parse', '--short=10', 'HEAD', default='unknown')
    subject = git('log', '-1', '--pretty=%s', default='')
    dirty = bool(git('status', '--porcelain', default=''))
    utc = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())

    BUILDS.mkdir(parents=True, exist_ok=True)
    branch_safe = branch.replace('/', '_').replace('\\', '_')
    suffix = '-dirty' if dirty else ''
    name = 'C64_%s_%s_%s_%s%s' % (branch_safe, sha, utc, md5short, suffix)
    dst_rbf = BUILDS / (name + '.rbf')
    dst_json = BUILDS / (name + '.json')

    # Skip if an identical-md5 archive already exists (idempotent re-runs).
    for existing in BUILDS.glob('*_%s*.rbf' % md5short):
        if existing.read_bytes() == rbf.read_bytes():
            print('Already archived: %s' % existing.name)
            print('Skipping copy; updating INDEX.md only.')
            update_index()
            return 0

    dst_rbf.write_bytes(rbf.read_bytes())
    meta = {
        'name': name,
        'md5': md5,
        'size_bytes': rbf.stat().st_size,
        'git_branch': branch,
        'git_sha': sha,
        'git_subject': subject,
        'git_dirty': dirty,
        'built_utc': utc,
        'source_rbf': str(rbf.relative_to(REPO)).replace('\\', '/'),
    }
    dst_json.write_text(json.dumps(meta, indent=2) + '\n')
    print('Archived RBF -> %s (md5=%s, size=%.2f MB)' % (
        dst_rbf.relative_to(REPO), md5, rbf.stat().st_size / 1048576))
    update_index()
    return 0


def update_index():
    idx = BUILDS / 'INDEX.md'
    lines = [
        '# C64 fork RBF build archive',
        '',
        '| Built (UTC)        | Branch              | SHA        | MD5 (short) | Subject                                    | Dirty |',
        '|--------------------|---------------------|------------|-------------|--------------------------------------------|-------|',
    ]
    entries = []
    for j in sorted(BUILDS.glob('*.json')):
        try:
            m = json.loads(j.read_text())
        except Exception:
            continue
        utc = m.get('built_utc', '?').replace('T', ' ').replace('Z', '')
        branch = m.get('git_branch', '?')[:19].ljust(19)
        sha = m.get('git_sha', '?')[:10].ljust(10)
        md5s = m.get('md5', '?')[:8]
        subj = m.get('git_subject', '')[:42].ljust(42)
        dirty = 'yes' if m.get('git_dirty') else 'no'
        entries.append((utc, '| %s | %s | %s | %s    | %s | %s   |' % (utc, branch, sha, md5s, subj, dirty)))
    entries.sort(key=lambda e: e[0], reverse=True)
    lines.extend(e[1] for e in entries)
    lines.append('')
    idx.write_text('\n'.join(lines))
    print('INDEX.md updated (%d builds tracked)' % len(entries))


if __name__ == '__main__':
    sys.exit(main(sys.argv))
