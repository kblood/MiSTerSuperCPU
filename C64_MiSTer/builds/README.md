# Build archive

This directory holds per-build snapshots of `output_files/C64.rbf`,
keyed by branch + git short SHA + UTC timestamp + md5 prefix.

It exists because we lost the v342 RBF (md5
`71722b93a461fc29562f85836ec31bf1`) when v347 overwrote
`output_files/C64.rbf` — no archive meant no rollback. Don't repeat that.

## What's tracked vs. ignored

- `INDEX.md` — committed, one line per build (timestamp, branch, SHA, md5, subject).
- `*.json` — committed, per-build metadata.
- `*.rbf` — **gitignored** (large binaries stay local). Restore from a
  known-good prior build by copying the `.rbf` you need to
  `/media/fat/_Test/C64.rbf` on the MiSTer.

## Automatic archival

`build_c64.ps1` calls `tools/archive_rbf.py` on every successful build,
so every working RBF lands here without you thinking about it.

## Manual archival

If you already have an RBF somewhere and want it in the archive:

```
python tools/archive_rbf.py path/to/some.rbf
```

The script is idempotent — re-running on the same RBF md5 is a no-op
(it just refreshes `INDEX.md`).
