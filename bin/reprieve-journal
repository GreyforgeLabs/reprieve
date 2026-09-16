#!/usr/bin/env python3
"""Reprieve recovery journal: the only thing that touches state.json.

    reprieve-journal read   [--state-dir DIR]
    reprieve-journal write  [--state-dir DIR]   (JSON document on stdin)
    reprieve-journal quarantine [--state-dir DIR] [--reason WORD]
    reprieve-journal inspect [--state-dir DIR]

`read` prints a JSON envelope: {"status": ..., "text": "<raw file contents>"}
so the shell can validate the document itself. `write` replaces state.json
atomically (same-directory temp file, fsync, rename) and refuses symlinks at
every step. `quarantine` moves a damaged file aside without deleting it.

No network, no shell, stdlib only.
"""
from __future__ import annotations

import argparse
import errno
import json
import os
import stat
import sys
import time

MAX_BYTES = 262144
DIR_MODE = 0o700
FILE_MODE = 0o600
STATE_FILE = "state.json"


def default_state_dir() -> str:
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "reprieve")


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, separators=(",", ":")))
    sys.stdout.write("\n")
    sys.stdout.flush()


def ensure_dir(path: str) -> str | None:
    """Create the state directory with 0700; refuse if it is not a real dir."""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        parent = os.path.dirname(path)
        try:
            os.makedirs(parent, exist_ok=True)
            os.mkdir(path, DIR_MODE)
        except FileExistsError:
            pass
        except OSError as exc:
            return f"mkdir: {exc.strerror}"
        try:
            st = os.lstat(path)
        except OSError as exc:
            return f"lstat: {exc.strerror}"
    except OSError as exc:
        return f"lstat: {exc.strerror}"
    if stat.S_ISLNK(st.st_mode):
        return "state directory is a symlink"
    if not stat.S_ISDIR(st.st_mode):
        return "state path is not a directory"
    if st.st_uid != os.getuid():
        return "state directory is not owned by the current user"
    if st.st_mode & 0o077:
        try:
            os.chmod(path, DIR_MODE)
        except OSError:
            pass
    return None


def dir_problem(state_dir: str) -> str | None:
    """Refuse a state directory that is a symlink, not a directory, or not
    ours. Missing is fine (read reports empty, write creates it)."""
    try:
        st = os.lstat(state_dir)
    except FileNotFoundError:
        return None
    except OSError:
        return "irregular"
    if stat.S_ISLNK(st.st_mode):
        return "symlink"
    if not stat.S_ISDIR(st.st_mode):
        return "irregular"
    if st.st_uid != os.getuid():
        return "irregular"
    return None


def check_regular(path: str) -> tuple[str, os.stat_result | None]:
    """Classify the state file: missing | symlink | irregular | oversized | ok."""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return "missing", None
    except OSError:
        return "irregular", None
    if stat.S_ISLNK(st.st_mode):
        return "symlink", st
    if not stat.S_ISREG(st.st_mode):
        return "irregular", st
    if st.st_uid != os.getuid():
        return "irregular", st
    if st.st_size > MAX_BYTES:
        return "oversized", st
    return "ok", st


def read_state(state_dir: str) -> dict:
    path = os.path.join(state_dir, STATE_FILE)
    problem = dir_problem(state_dir)
    if problem:
        return {"status": problem, "text": "", "path": path}
    kind, st = check_regular(path)
    if kind == "missing":
        return {"status": "empty", "text": "", "path": path}
    if kind != "ok":
        return {"status": kind, "text": "", "path": path}
    try:
        # O_NOFOLLOW closes the lstat/open race.
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            return {"status": "symlink", "text": "", "path": path}
        return {"status": "irregular", "text": "", "path": path}
    try:
        with os.fdopen(fd, "rb") as fh:
            data = fh.read(MAX_BYTES + 1)
    except OSError:
        return {"status": "irregular", "text": "", "path": path}
    if len(data) > MAX_BYTES:
        return {"status": "oversized", "text": "", "path": path}
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return {"status": "invalid", "text": "", "path": path}
    return {"status": "ok", "text": text, "path": path}


def write_state(state_dir: str, text: str) -> dict:
    err = ensure_dir(state_dir)
    if err:
        return {"status": "error", "error": err}
    if len(text.encode("utf-8")) > MAX_BYTES:
        return {"status": "error", "error": "document too large"}
    try:
        json.loads(text)
    except ValueError:
        return {"status": "error", "error": "document is not JSON"}
    path = os.path.join(state_dir, STATE_FILE)
    kind, _ = check_regular(path)
    if kind in ("symlink", "irregular"):
        return {"status": "error", "error": f"refusing to replace {kind} at {path}"}
    tmp = os.path.join(state_dir, f".{STATE_FILE}.{os.getpid()}.{int(time.time() * 1000)}.tmp")
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, FILE_MODE)
    except OSError as exc:
        return {"status": "error", "error": f"open temp: {exc.strerror}"}
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(text.encode("utf-8"))
            if not text.endswith("\n"):
                fh.write(b"\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, FILE_MODE)
        os.rename(tmp, path)
        try:
            dfd = os.open(state_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
            try:
                os.fsync(dfd)
            finally:
                os.close(dfd)
        except OSError:
            pass
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return {"status": "error", "error": f"write: {exc.strerror}"}
    return {"status": "ok", "path": path, "bytes": len(text)}


def quarantine(state_dir: str, reason: str) -> dict:
    problem = dir_problem(state_dir)
    if problem:
        return {"status": "error", "error": f"state directory is {problem}"}
    path = os.path.join(state_dir, STATE_FILE)
    kind, _ = check_regular(path)
    if kind == "missing":
        return {"status": "empty"}
    safe_reason = "".join(ch for ch in (reason or "damaged") if ch.isalnum() or ch in "-_")[:32] or "damaged"
    # PID in the name: two quarantines within the same second must not
    # overwrite each other.
    target = os.path.join(state_dir, f"{STATE_FILE}.{safe_reason}.{int(time.time())}.{os.getpid()}")
    try:
        if kind == "symlink":
            os.unlink(path)
            return {"status": "removed", "kind": kind}
        os.rename(path, target)
    except OSError as exc:
        return {"status": "error", "error": exc.strerror}
    return {"status": "ok", "moved_to": target, "kind": kind}


def inspect(state_dir: str) -> dict:
    """Read-only summary for `reprieve doctor`. Never mutates anything."""
    result = read_state(state_dir)
    out = {"status": result["status"], "path": result["path"], "entries": 0, "session": "", "schema": None}
    if result["status"] != "ok":
        return out
    try:
        doc = json.loads(result["text"])
    except ValueError:
        out["status"] = "invalid"
        return out
    if not isinstance(doc, dict) or doc.get("schema") != 1 or not isinstance(doc.get("entries"), list):
        out["status"] = "invalid"
        return out
    out["schema"] = doc.get("schema")
    out["session"] = str(doc.get("session") or "")
    out["entries"] = len(doc.get("entries") or [])
    out["addresses"] = [str(e.get("address") or "") for e in doc["entries"] if isinstance(e, dict)][:64]
    current = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") or ""
    out["current_session"] = current == out["session"] if current else None
    return out


def main() -> int:
    parser = argparse.ArgumentParser(prog="reprieve-journal")
    parser.add_argument("action", choices=["read", "write", "quarantine", "inspect"])
    parser.add_argument("--state-dir", default=default_state_dir())
    parser.add_argument("--reason", default="damaged")
    args = parser.parse_args()
    state_dir = os.path.abspath(args.state_dir)

    if args.action == "read":
        emit(read_state(state_dir))
        return 0
    if args.action == "write":
        raw = sys.stdin.buffer.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            emit({"status": "error", "error": "document too large"})
            return 1
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            emit({"status": "error", "error": "document is not UTF-8"})
            return 1
        result = write_state(state_dir, text)
        emit(result)
        return 0 if result["status"] == "ok" else 1
    if args.action == "quarantine":
        result = quarantine(state_dir, args.reason)
        emit(result)
        return 0 if result["status"] in ("ok", "empty", "removed") else 1
    emit(inspect(state_dir))
    return 0


if __name__ == "__main__":
    sys.exit(main())
