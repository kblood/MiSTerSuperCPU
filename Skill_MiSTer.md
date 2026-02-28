# MiSTer Skill (General)

General-purpose skill notes for working with MiSTer hardware, independent of any specific core.

## Access

- Host: `192.168.50.130`
- User: `root`
- SSH port: `22`
- Password fallback: `1`
- Preferred auth: SSH key (`~/.ssh/id_ed25519`)

Quick commands:

```powershell
ssh root@192.168.50.130
scp root@192.168.50.130:/path/to/remote/file .
scp .\local_file root@192.168.50.130:/path/to/remote/file
```

## Filesystem Notes

- `/media/fat/` is main writable SD-backed storage.
- `/` is typically read-only unless remounted.

Remount root read-write only when needed:

```bash
ssh root@192.168.50.130 "mount -o remount,rw /"
```

## Generic Core Deploy

Copy a prebuilt core binary to a known test path, then load it from OSD:

```powershell
scp .\core.rbf root@192.168.50.130:/media/fat/_Test/core.rbf
```

## Runtime Debug Basics

```bash
ssh root@192.168.50.130
tail -f /var/log/messages
dmesg | tail -50
```

## Troubleshooting

- `Connection refused`: verify MiSTer is powered and networked.
- `Permission denied`: validate key ACLs and fallback credentials.
- `No route to host`: verify IP/connectivity (`ping 192.168.50.130`).

## Core-Specific Skills

- C64-specific workflows (ROM builder, paths, deploy wrappers, debug process):
  see [Skill_MiSTer_C64.md](/C:/LLM/C64/MiSTerSuperCPU/Skill_MiSTer_C64.md)

