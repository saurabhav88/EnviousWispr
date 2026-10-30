#!/usr/bin/env python3
"""Physical macOS cleanup boundary shared by seeding and local purge (#4197).

Removal: 0 removed, 3 already absent, 1 refused/incomplete/unknown, 2 invocation
or platform failure. Inspect is read-only: 0 validated existing/creation
namespace, 3 validated absent final target, 1 unknown/refused, 2 bad invocation.

This is the macOS floor, not an atomic filesystem snapshot. A mount or link may
change after preflight; find's device boundary remains active during traversal.
No alternate deletion command or production test/bypass switch is provided.
"""

import base64
import binascii
import json
import os
import stat
import subprocess
import sys

REMOVED, REFUSED, INVALID, ABSENT = 0, 1, 2, 3
MAX_OWNER_BYTES = 65536  # v1 has three short metadata fields; larger records are unknown.


def refuse(target, reason, status=REFUSED):
    print("remove-tree: {!r}: {}".format(target, reason), file=sys.stderr)
    return status


def checked_path(value):
    if not value or not os.path.isabs(value) or ".." in value.split(os.sep) or "\0" in value:
        raise ValueError("paths must be absolute and contain no '..' or NUL")
    return os.path.normpath(value)


def identity(entry):
    return "{}:{}".format(entry.st_dev, entry.st_ino)


def check_directory(path):
    entry = os.lstat(path)
    if not stat.S_ISDIR(entry.st_mode):
        raise ValueError("linked or non-directory component: {!r}".format(path))
    try:
        parent = os.stat(os.path.dirname(path))
    except OSError as error:
        raise ValueError("unknown parent metadata: {!r}".format(path)) from error
    if entry.st_dev != parent.st_dev or identity(entry) == identity(parent):
        raise ValueError("mounted or filesystem-root component: {!r}".format(path))
    return entry


def inspect_namespace(root):
    """Validate an existing root or its existing creation parent, without mkdir.

    The creation parent may have an ordinary alias above the declared root.
    Resolve that parent explicitly; never adopt a linked declared root.
    The caller must inspect the new root again after creating it.
    """
    root = checked_path(root)
    if root == os.sep:
        raise ValueError("filesystem root is not a cache namespace")
    try:
        entry = check_directory(root)
    except FileNotFoundError:
        parent = os.path.dirname(root)
        while True:
            try:
                os.lstat(parent)
                break
            except FileNotFoundError:
                if parent == os.sep:
                    raise ValueError("no verified creation parent")
                parent = os.path.dirname(parent)
        physical_parent = os.path.realpath(parent)
        entry = check_directory(physical_parent)
        return {"root": root, "exists": False, "creation_parent": physical_parent,
                "parent_identity": identity(entry)}
    return {"root": root, "exists": True, "identity": identity(entry)}


def inspect_target(root, target, expected_identity=None):
    """Validate root through target; only a missing FINAL component is ABSENT."""
    root, target = checked_path(root), checked_path(target)
    if root == os.sep or target == root or os.path.commonpath((root, target)) != root:
        raise ValueError("target must be a strict descendant of the declared root")
    root_entry = check_directory(root)
    parent_entry = root_entry
    current = root
    components = os.path.relpath(target, root).split(os.sep)
    for index, component in enumerate(components):
        current = os.path.join(current, component)
        try:
            entry = check_directory(current)
        except FileNotFoundError:
            if index != len(components) - 1:
                raise ValueError("missing initial target parent")
            current_parent = check_directory(os.path.dirname(current))
            if identity(current_parent) != identity(parent_entry):
                raise ValueError("parent changed during absence inspection")
            return {"root": root, "target": target, "root_identity": identity(root_entry),
                    "exists": False}
        parent_entry = entry
    if expected_identity is not None and identity(entry) != expected_identity:
        raise ValueError("target identity changed since registration")
    return {"root": root, "target": target, "root_identity": identity(root_entry),
            "identity": identity(entry), "exists": True}


def remove_tree(root, target, expected_identity=None):
    if sys.platform != "darwin":
        return refuse(target, "this cleanup boundary requires macOS", INVALID)
    try:
        observed = inspect_target(root, target, expected_identity)
    except (OSError, ValueError) as error:
        return refuse(target, "preflight refused; no traversal: {}".format(error))
    if not observed["exists"]:
        return ABSENT
    target = observed["target"]
    try:
        result = subprocess.run(
            ["/usr/bin/find", "-P", target, "-xdev", "-delete"], check=False
        )
    except OSError as error:
        return refuse(target, "could not start bounded removal: {}".format(error), INVALID)
    # macOS find -delete can return success while a target survives. lstat also
    # sees a dangling symlink, unlike an existence check that follows the link.
    try:
        os.lstat(target)
    except FileNotFoundError:
        if result.returncode == 0:
            return REMOVED
        return refuse(target, "find failed with status {}; no success credited".format(result.returncode))
    except OSError as error:
        return refuse(target, "could not verify disappearance: {}".format(error))
    return refuse(target, "removal incomplete; target remains (find status {})".format(result.returncode))


def open_directory(target, expected_identity):
    """Pin metadata IO to the directory instance inspected by the caller."""
    if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY"):
        raise NotImplementedError("safe directory handles unavailable")
    fd = os.open(target, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        if identity(os.fstat(fd)) != expected_identity:
            raise ValueError("directory changed while opening metadata handle")
    except BaseException:
        os.close(fd)
        raise
    return fd


def read_owner(fd):
    """Opaque bytes, not lifecycle eligibility. Never follow an owner link."""
    try:
        entry = os.stat("owner", dir_fd=fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(entry.st_mode):
        raise ValueError("owner is linked or not a regular file")
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_NONBLOCK", 0)
    owner_fd = os.open("owner", flags, dir_fd=fd)
    try:
        opened = os.fstat(owner_fd)
        if not stat.S_ISREG(opened.st_mode) or identity(opened) != identity(entry):
            raise ValueError("owner changed while opening metadata")
        with os.fdopen(owner_fd, "rb") as stream:
            owner_fd = None
            data = stream.read(MAX_OWNER_BYTES + 1)
        if len(data) > MAX_OWNER_BYTES:
            raise ValueError("owner metadata exceeds the supported envelope")
        return data
    finally:
        if owner_fd is not None:
            os.close(owner_fd)


def inspect_owner(root, target, expected_identity=None):
    observed = inspect_target(root, target, expected_identity)
    if not observed["exists"]:
        return observed
    fd = open_directory(observed["target"], observed["identity"])
    try:
        data = read_owner(fd)
    finally:
        os.close(fd)
    observed["owner_exists"] = data is not None
    observed["owner_base64"] = None if data is None else base64.b64encode(data).decode("ascii")
    return observed


def publish_owner(root, target, expected_identity, encoded):
    """Publish exact captured bytes atomically, refusing an existing other owner.

    Lifecycle policy stays in the shell owner. This primitive never interprets
    PID/start/version. A hard-link publication cannot overwrite a concurrent
    owner; only the temporary file we created is eligible for unlink.
    """
    data = base64.b64decode(encoded, validate=True)
    if not data or len(data) > MAX_OWNER_BYTES:
        raise ValueError("invalid owner metadata envelope")
    observed = inspect_target(root, target, expected_identity)
    if not observed["exists"]:
        raise ValueError("cannot publish into an absent directory")
    fd = open_directory(observed["target"], observed["identity"])
    temporary = ".owner.{}".format(os.getpid())
    temporary_identity = None
    try:
        old = read_owner(fd)
        if old is not None:
            if old != data:
                raise ValueError("existing owner differs; refusing overwrite")
            return 0
        writer = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        try:
            temporary_identity = identity(os.fstat(writer))
            with os.fdopen(writer, "wb") as stream:
                writer = None
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            os.link(temporary, "owner", src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
        finally:
            if writer is not None:
                os.close(writer)
        if read_owner(fd) != data:
            raise ValueError("published owner could not be verified")
        return 0
    finally:
        try:
            if temporary_identity is not None:
                current = os.stat(temporary, dir_fd=fd, follow_symlinks=False)
                if identity(current) != temporary_identity:
                    raise ValueError("publication temporary changed; retained")
                os.unlink(temporary, dir_fd=fd)
        finally:
            os.close(fd)


def remove_empty(root, target, expected_identity):
    """Mutation gates are removed nonrecursively; never empty them for the caller."""
    observed = inspect_target(root, target, expected_identity)
    if not observed["exists"]:
        return ABSENT
    parent = os.path.dirname(observed["target"])
    parent_entry = check_directory(parent)
    fd = open_directory(parent, identity(parent_entry))
    try:
        leaf = os.path.basename(observed["target"])
        current = os.stat(leaf, dir_fd=fd, follow_symlinks=False)
        if identity(current) != expected_identity or not stat.S_ISDIR(current.st_mode):
            raise ValueError("gate changed before rmdir")
        os.rmdir(leaf, dir_fd=fd)
        try:
            os.stat(leaf, dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            return 0
        raise ValueError("gate remains after rmdir")
    finally:
        os.close(fd)


def main(argv):
    args = argv[1:]
    if args and args[0] in ("owner", "publish-owner", "rmdir"):
        command = args.pop(0)
        expected = {"owner": (2, 3), "publish-owner": (4,), "rmdir": (3,)}[command]
        if len(args) not in expected:
            return refuse("", "invalid {} invocation".format(command), INVALID)
        if sys.platform != "darwin":
            return refuse(args[0], "this cleanup boundary requires macOS", INVALID)
        try:
            if command == "owner":
                observed = inspect_owner(*args)
                print(json.dumps(observed, ensure_ascii=True, sort_keys=True))
                return 0 if observed["exists"] else ABSENT
            if command == "publish-owner":
                return publish_owner(*args)
            return remove_empty(*args)
        except NotImplementedError as error:
            return refuse(args[1], str(error), INVALID)
        except (OSError, ValueError, binascii.Error) as error:
            return refuse(args[1], "{} refused: {}".format(command, error))
    if args and args[0] == "inspect":
        if len(args) not in (2, 3):
            return refuse("", "usage: remove-tree.py inspect ROOT [TARGET]", INVALID)
        if sys.platform != "darwin":
            return refuse(args[1], "this cleanup boundary requires macOS", INVALID)
        try:
            observed = inspect_namespace(args[1]) if len(args) == 2 else inspect_target(args[1], args[2])
        except (OSError, ValueError) as error:
            return refuse(args[-1], "inspect refused: {}".format(error))
        print(json.dumps(observed, ensure_ascii=True, sort_keys=True))
        return ABSENT if len(args) == 3 and not observed["exists"] else 0
    if args and args[0] == "remove":
        args = args[1:]
    if len(args) not in (2, 3):
        return refuse("", "usage: remove-tree.py [remove] ROOT TARGET [EXPECTED_ID]", INVALID)
    return remove_tree(*args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
