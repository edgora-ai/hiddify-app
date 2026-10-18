"""Generate local-only automatic-signing export options, never signing material.

Generate: python3 -B tool/ios/local_export_options.py --team-id TEAM_ID --output ABSOLUTE_PLIST
Use --method development only when the selected Xcode requires the legacy name;
the default is debugging. No Xcode/signing compatibility is inferred or probed.
Check: python3 -B tool/ios/local_export_options.py --check ABSOLUTE_PLIST
"""

import argparse
import os
from pathlib import Path
import plistlib
import re
import stat
from xml.parsers.expat import ExpatError


METHODS = ("debugging", "development")


def local_options(team_id, method="debugging"):
    if not isinstance(team_id, str) or re.fullmatch(r"[A-Z0-9]{10}", team_id) is None:
        raise ValueError("team ID must contain exactly 10 uppercase ASCII letters or digits")
    if method not in METHODS:
        raise ValueError("method must be debugging or development for local export")
    return {
        "destination": "export",
        "manageAppVersionAndBuildNumber": False,
        "method": method,
        "signingStyle": "automatic",
        "teamID": team_id,
        "uploadSymbols": False,
    }


def validate_options(options):
    if not isinstance(options, dict):
        raise ValueError("export options must be a dictionary")
    expected = local_options(options.get("teamID"), options.get("method"))
    if options.keys() != expected.keys() or any(
        type(options[key]) is not type(value) or options[key] != value
        for key, value in expected.items()
    ):
        raise ValueError("only local automatic-signing options with uploads and version management disabled are accepted")


def plist_path(value):
    if not isinstance(value, str) or any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError("plist path must be plain text without control characters")
    path = Path(value)
    if not path.is_absolute() or ".." in path.parts or path.suffix != ".plist":
        raise ValueError("provide an absolute .plist path without parent traversal")
    return path


def write_options(output, team_id, method="debugging"):
    path = plist_path(output)
    payload = plistlib.dumps(local_options(team_id, method), fmt=plistlib.FMT_XML, sort_keys=True)
    # Exclusive creation also refuses existing files and dangling output symlinks.
    # The caller prepares the parent; no directory creation or overwrite fallback.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(payload)


def check_options(source):
    path = plist_path(source)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("export options must be a regular file, not a link or special file")
        validate_options(plistlib.load(stream))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--output", help="new absolute .plist path; parent must already exist")
    action.add_argument("--check", help="validate an existing local export plist without writing it")
    parser.add_argument("--team-id", help="explicit Apple team ID (required when generating)")
    parser.add_argument("--method", choices=METHODS, help="local export method (default: debugging)")
    args = parser.parse_args(argv)
    try:
        if args.check:
            if args.team_id is not None or args.method is not None:
                raise ValueError("--check cannot be combined with --team-id or --method")
            check_options(args.check)
        else:
            write_options(args.output, args.team_id, args.method or "debugging")
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
