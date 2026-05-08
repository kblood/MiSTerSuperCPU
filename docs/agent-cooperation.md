# Sharing the MiSTer between two Claude Code agents

Two Claude Code agents are operating from different working directories on
the same machine, both occasionally driving the **same physical MiSTer** at
`192.168.50.130` (root / password `1`). Conversation context and per-project
auto-memory don't cross between agents, so we coordinate via observable
device state and a tiny shared file convention.

This doc is meant to be readable by either agent dropped in cold.

## Ground rules

1. **The MiSTer is shared, the SD/USB filesystem is shared, but each
   agent owns its own slice of cores/games.** CD32 work happens on the
   Minimig core; the other agent's work happens on its core (currently
   C64 + a Doom-on-C64 project). Don't change files outside your own
   slice without checking.
2. **Read-only SSH commands are always safe** (`ps`, `cat /tmp/CORENAME`,
   `ls`, reading a log). They don't disrupt whatever's running.
3. **Disruptive actions** — anything that would interrupt the other
   agent's session — must check first. Disruptive means: `killall MiSTer`,
   `load_core <something>`, writing/replacing `/media/fat/MiSTer`,
   replacing the active `Minimig.rbf`, mounting/unmounting CDs, sending
   keys via uinput.

## The detect-and-defer protocol (always do this)

Before any disruptive action, SSH the MiSTer and read which core is loaded:

```bash
ssh root@192.168.50.130 'cat /tmp/CORENAME'
```

The contents identify the running core. Examples:
- `Minimig` → the CD32 agent is (or was last) running. CD32-side work is
  fair game.
- `C64` → the other agent's project is loaded. Don't disrupt unless your
  task has explicit permission for this slot.
- empty / no file → no core loaded yet, OK to proceed.

If the loaded core is not yours, **back off and do off-device work**:

- Read code, analyse logs you already have, write/refine sim tests.
- Prepare CFG/MGL files locally so they're ready when the device frees up.
- Diff WinUAE behavior against your last MiSTer trace.
- Update memory and docs.

Re-check after a few minutes. The loaded core changes on every `load_core`
or reset.

## Optional: lockfile for longer disruptive work

For multi-step on-device sessions (e.g. flashing a new RBF, running a
boot-test loop), write a lockfile so the other agent knows you're
holding the device:

```bash
ssh root@192.168.50.130 "echo \"agent=cd32 pid=$$ task='boot-test fleet' since=$(date -Iseconds)\" > /tmp/mister_session.lock"
# ... do work ...
ssh root@192.168.50.130 'rm -f /tmp/mister_session.lock'
```

Before you grab the device, also check the lockfile:

```bash
ssh root@192.168.50.130 'cat /tmp/mister_session.lock 2>/dev/null || echo "free"'
```

A stale lockfile (older than ~30 minutes) is OK to ignore — the holding
agent likely crashed or its session ended without cleanup.

## What NOT to do

- **Don't `killall MiSTer`** to "reset" — you'll evict the other agent
  from their session. Use the proper restart path (`tools/reset_minimig_core.py`
  for Minimig, equivalent for C64) which only acts when the matching core
  is loaded.
- **Don't replace `/media/fat/MiSTer`** without confirming the loaded
  core is yours. The binary is shared. If the C64 agent has an active
  session and you swap MiSTer, their session crashes. Use `tools/deploy_to_mister.py`
  with `--no-restart` if you must update the binary while the device is
  busy — it'll be picked up on next core load.
- **Don't clobber `/tmp/akiko_dbg.log`** if the other agent might also
  be reading or writing to `/tmp` for their workflow. The Akiko bridge
  owns this file; if Minimig isn't loaded, treat it as historical.

## Identifying who's who

| Marker | CD32 agent | Other agent |
|---|---|---|
| Working dir | `C:\LLM\MiSTer\CD32\` | (separate) |
| Core slot | Minimig (custom RBF in `_Test/`) | C64 / others |
| Log file | `/tmp/akiko_dbg.log` | (other) |
| Touching | `/media/fat/_Test/Minimig.rbf`, `/media/fat/MiSTer`, `/media/fat/_Computer/CD32-*.mgl`, `/media/fat/config/CD32-*.cfg`, `/media/usb0/games/AmigaCD32/` | (other) |

## Quick check, copy-paste

```bash
# What's running right now?
ssh root@192.168.50.130 "echo CORENAME=\$(cat /tmp/CORENAME 2>/dev/null); echo LOCK=\$(cat /tmp/mister_session.lock 2>/dev/null); ps aux | grep -E '/media/fat/MiSTer' | grep -v grep"
```

If `CORENAME` is yours and `LOCK` is empty (or yours) → safe to proceed.

## Why no per-project memory entry for this

The cooperation protocol applies cross-project, but auto-memory is
per-working-directory. Each agent should keep this doc visible in its
own project (e.g. `research/docs/agent-cooperation.md` for CD32, equivalent
path for the other agent) and reference it from `CLAUDE.md` if cross-agent
work becomes routine.
