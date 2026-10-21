"""Read-only preflight for the local iOS identity HOME and Flutter configuration.

Flutter 3.38.5 Config._configPath uses HOME/.flutter_settings before XDG.
Refuse a legacy entry rather than let Flutter read, repair or write user settings.
No credentials or signing tools are accessed here.
"""

import json
import math
import os
from pathlib import Path
import pwd
import stat
import sys


FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def directory(path):
    fd = os.open("/", FLAGS)
    try:
        for part in path.parts[1:]:
            child = os.open(part, FLAGS, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def home_path(value, *, allow_controls=False):
    if not value or (not allow_controls and any(ord(char) < 32 or ord(char) == 127 for char in value)):
        raise ValueError("HOME paths must be absolute plain text without control characters")
    path = Path(value)
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("HOME paths must be absolute without parent traversal")
    return path


def optional_stat(parent, name):
    try:
        return os.stat(name, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        return None


def check_environment(identity_home, private_home, pub_cache, tmpdir):
    identity = home_path(identity_home)
    private = home_path(private_home)
    if identity != Path(pwd.getpwuid(os.getuid()).pw_dir):
        raise ValueError("IOS_LOCAL_IDENTITY_HOME must be the current user's account home")
    identity_fd = directory(identity)
    try:
        identity_info = os.fstat(identity_fd)
        if identity_info.st_uid != os.getuid():
            raise ValueError("The identity home must belong to the current user")
        identity_key = (identity_info.st_dev, identity_info.st_ino)

        def separate(info, role):
            if (info.st_dev, info.st_ino) == identity_key:
                raise ValueError("The identity home must differ from the " + role)

        for role, value in (("pub cache root", pub_cache), ("temporary root", tmpdir)):
            role_fd = directory(home_path(value, allow_controls=True))
            try:
                separate(os.fstat(role_fd), role)
                if role == "temporary root":
                    xcode = optional_stat(role_fd, "ios-local-xcode")
                    if xcode is not None:
                        separate(xcode, "Xcode output root")
            finally:
                os.close(role_fd)
        output_fd = directory(Path.cwd())
        try:
            separate(os.fstat(output_fd), "source workspace")
            for part in ("build", "ios"):
                info = optional_stat(output_fd, part)
                if info is None:
                    break
                if not stat.S_ISDIR(info.st_mode):
                    raise ValueError("Refusing non-directory or linked output parent")
                child = os.open(part, FLAGS, dir_fd=output_fd)
                os.close(output_fd)
                output_fd = child
                separate(os.fstat(output_fd), "default output root")
            else:
                for part in ("archive", "ipa"):
                    info = optional_stat(output_fd, part)
                    if info is not None:
                        separate(info, "default output root")
        finally:
            os.close(output_fd)
        private_fd = directory(private)
        try:
            private_info = os.fstat(private_fd)
            if (identity_info.st_dev, identity_info.st_ino) == (private_info.st_dev, private_info.st_ino):
                raise ValueError("The private Flutter home must differ from the identity home")
            # Even a valid legacy file would beat private XDG and may be written
            # by the SDK's signing-selection configuration. Do not open it.
            if optional_stat(identity_fd, ".flutter_settings") is not None:
                raise ValueError("Legacy Flutter settings override private XDG configuration; ios-local does not read or modify them")
            config_fd = os.dup(private_fd)
            try:
                for part in (".config", "flutter"):
                    info = optional_stat(config_fd, part)
                    if info is None:
                        return
                    if not stat.S_ISDIR(info.st_mode):
                        raise ValueError("Flutter settings require regular private configuration paths")
                    child = os.open(part, FLAGS, dir_fd=config_fd)
                    os.close(config_fd)
                    config_fd = child
                    separate(os.fstat(config_fd), "private XDG configuration root")
                info = optional_stat(config_fd, "settings")
                if info is None:
                    return
                if not stat.S_ISREG(info.st_mode):
                    raise ValueError("Flutter settings require regular private configuration paths")
                fd = os.open("settings", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=config_fd)
                with os.fdopen(fd, "rb") as stream:
                    before = os.fstat(stream.fileno())
                    if not stat.S_ISREG(before.st_mode) or before.st_size > 1024 * 1024:
                        raise ValueError("Flutter settings must be a bounded regular JSON file")
                    raw = stream.read(1024 * 1024 + 1)
                    after = os.fstat(stream.fileno())
                    current = os.stat("settings", dir_fd=config_fd, follow_symlinks=False)
                    stamps = [(s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
                              for s in (before, after, current)]
                    if len(raw) != before.st_size or not stamps[0] == stamps[1] == stamps[2]:
                        raise ValueError("Flutter settings changed during preflight")
                def invalid(value):
                    raise ValueError("Non-finite Flutter configuration is not accepted")
                def finite_float(value):
                    number = float(value)
                    if not math.isfinite(number):
                        raise ValueError("Non-finite Flutter configuration is not accepted")
                    return number
                config = json.loads(raw.decode("utf-8"), parse_constant=invalid, parse_float=finite_float)
                if not isinstance(config, dict) or config.get("build-dir", "build") not in (None, "build"):
                    raise ValueError("ios-local requires default Flutter build-dir (build)")
            finally:
                os.close(config_fd)
        finally:
            os.close(private_fd)
    finally:
        os.close(identity_fd)


def main():
    try:
        check_environment(os.environ.get("IOS_LOCAL_IDENTITY_HOME"), os.environ.get("IOS_LOCAL_HOME"),
                          os.environ.get("IOS_LOCAL_PUB_CACHE"), os.environ.get("IOS_LOCAL_TMPDIR"))
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
