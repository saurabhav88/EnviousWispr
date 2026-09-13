"""#2885: hand a RUNNING dev build a file for Transcribe a File without the screen.

The dev build (DEBUG only; `Sources/EnviousWisprAppKit/App/DebugImportDoor.swift`)
listens for one distributed notification naming it by PID and per-launch id. It runs
the wizard's own steps with whatever Settings hold and replies twice: `accepted`
(or `busy`/`malformed`/`wrongLaunch`/`duplicate`) and then a terminal status with the
History row id. Nothing is activated and nothing is typed, so the founder keeps his
keyboard and mouse.

Every dev build shares one bundle id, so the caller names the PID and this module
refuses when that PID is not a running EnviousWispr, or (when `worktree` is given) is
not the build from that worktree. The door itself answers only its own PID and only a
`transcribe` carrying the launch id it handed out to `discover`, so a PID reused by
another process between resolve and post is never handed a file.

    from import_door import transcribe_file_backend
    reply = transcribe_file_backend(pid, "/abs/clip.m4a", timeout=600,
                                    worktree="/Users/x/EnviousWispr-feature")
    reply["status"]   # finished | refused | superseded | timeout | busy ...
    reply["history"]  # the row's UUID when status is finished/refused
    reply["saved"]    # "true" when the row was written; validate the JSON yourself
"""
import os
import time
import uuid

import objc
from Foundation import (NSDate, NSDistributedNotificationCenter, NSObject, NSRunLoop)

from instance_guard import running_enviouswispr_instances

REQUEST_NAME = "com.enviouswispr.dev.import.request"
REPLY_NAME = "com.enviouswispr.dev.import.reply"
TERMINAL = {"finished", "refused", "superseded", "timeout", "unexpected", "cancelled"}
REFUSALS = {"busy", "malformed", "wrongLaunch", "duplicate"}


class _Replies(NSObject):
    """Collects every reply the door posts, as plain dicts, in arrival order."""

    def init(self):
        self = objc.super(_Replies, self).init()
        if self is None:
            return None
        self.rows = []
        return self

    def onReply_(self, note):
        info = note.userInfo() or {}
        row = {str(k): str(v) for k, v in info.items()}
        row["_at"] = time.time()
        self.rows.append(row)


def _center():
    return NSDistributedNotificationCenter.defaultCenter()


def _post(info):
    _center().postNotificationName_object_userInfo_deliverImmediately_(
        REQUEST_NAME, None, info, True)


def _pump(seconds):
    NSRunLoop.currentRunLoop().runUntilDate_(
        NSDate.dateWithTimeIntervalSinceNow_(seconds))


def _wait(observer, request, statuses, timeout, echo):
    """The first reply for `request` whose status is in `statuses`, or None."""
    seen = 0
    deadline = time.time() + timeout
    while True:
        for row in observer.rows[seen:]:
            seen += 1
            if row.get("request") != request:
                continue
            if echo and not row.get("_echoed"):
                row["_echoed"] = True
                fields = " ".join(f"{k}={row[k]}" for k in sorted(row)
                                  if not k.startswith("_"))
                print(f"  door: {fields}")
            if row.get("status") in statuses:
                return row
        if time.time() >= deadline:
            return None
        _pump(0.1)


def resolve_pid(worktree):
    """The one running dev app built from `worktree`, or a RuntimeError naming every
    running instance. REFUSES rather than picks when the count is not exactly one."""
    root = os.path.abspath(os.path.expanduser(worktree)) + "/"
    instances = running_enviouswispr_instances()
    mine = {p: e for p, e in instances.items() if e.startswith(root)}
    if len(mine) != 1:
        rows = "\n".join(f"    {p}  {e}" for p, e in sorted(instances.items()))
        raise RuntimeError(
            f"need exactly one running EnviousWispr built under {root}; found "
            f"{len(mine)} of {len(instances)} running:\n{rows}")
    return int(next(iter(mine)))


def transcribe_file_backend(pid, path, timeout=900, worktree=None, echo=True):
    """Hand `path` to the dev app with process id `pid` and wait for its terminal reply.

    Returns the reply dict. A refusal (`busy`, `malformed`, `wrongLaunch`, `duplicate`)
    is returned as-is with no wait; a RuntimeError names a door that never answered
    (a Release build, a wrong PID, or a build without #2885).
    """
    pid = str(int(pid))
    path = os.path.abspath(os.path.expanduser(path))
    if not os.path.isfile(path):
        raise RuntimeError(f"not a file: {path}")
    instances = running_enviouswispr_instances()
    if pid not in instances:
        rows = "\n".join(f"    {p}  {e}" for p, e in sorted(instances.items()))
        raise RuntimeError(f"pid {pid} is not a running EnviousWispr; running:\n{rows}")
    if worktree is not None:
        root = os.path.abspath(os.path.expanduser(worktree)) + "/"
        if not instances[pid].startswith(root):
            raise RuntimeError(
                f"pid {pid} runs {instances[pid]}, not a build under {root}")

    observer = _Replies.alloc().init()
    # Registered BEFORE the first post: a reply that lands before the observer exists is
    # lost, and the door answers `discover` at once.
    _center().addObserver_selector_name_object_(observer, "onReply:", REPLY_NAME, None)
    try:
        discover = str(uuid.uuid4())
        _post({"kind": "discover", "pid": pid, "request": discover})
        alive = _wait(observer, discover, {"alive"}, 5.0, echo)
        if alive is None:
            raise RuntimeError(
                f"pid {pid} ({instances[pid]}) did not answer discover in 5 s: "
                "is it a DEBUG build carrying #2885's door?")
        launch = alive["launch"]

        request = str(uuid.uuid4())
        _post({"kind": "transcribe", "pid": pid, "launch": launch, "request": request,
               "path": path, "timeout": str(int(timeout))})
        first = _wait(observer, request, REFUSALS | {"accepted"}, 5.0, echo)
        if first is None:
            raise RuntimeError(f"pid {pid} did not answer the transcribe request in 5 s")
        if first["status"] != "accepted":
            return first
        final = _wait(observer, request, TERMINAL, timeout + 15, echo)
        if final is None:
            raise RuntimeError(
                f"pid {pid} accepted request {request} but sent no terminal reply "
                f"within {timeout + 15:.0f} s")
        return final
    finally:
        _center().removeObserver_(observer)
