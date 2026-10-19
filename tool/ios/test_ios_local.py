"""Make contract tests: only a fake Flutter executable runs, never build tools."""

from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

import local_export_options as export


REPO = Path(__file__).parents[2]
TEAM = "AB12CD34EF"
XCODE_ROOT_CONFIG = (
    "OBJROOT = $(HIDDIFY_IOS_LOCAL_XCODE_ROOT)/Intermediates.noindex\n"
    "SYMROOT = $(HIDDIFY_IOS_LOCAL_XCODE_ROOT)/Products\n"
    "CACHE_ROOT = $(HIDDIFY_IOS_LOCAL_XCODE_ROOT)/Caches\n"
    "MODULE_CACHE_DIR = $(HIDDIFY_IOS_LOCAL_XCODE_ROOT)/ModuleCache.noindex\n"
    "CLANG_MODULE_CACHE_PATH = $(MODULE_CACHE_DIR)\n"
    "SWIFT_MODULE_CACHE_PATH = $(MODULE_CACHE_DIR)\n"
    "SDK_STAT_CACHE_DIR = $(HIDDIFY_IOS_LOCAL_XCODE_ROOT)\n"
    "SHARED_PRECOMPS_DIR = $(HIDDIFY_IOS_LOCAL_XCODE_ROOT)/SharedPrecompiledHeaders\n"
    "DSTROOT = $(HIDDIFY_IOS_LOCAL_XCODE_ROOT)/InstallationBuildProducts\n"
)


def expected_config(build_number):
    return (f"FLUTTER_BUILD_NUMBER = {build_number}\nCURRENT_PROJECT_VERSION = {build_number}\n"
            + XCODE_ROOT_CONFIG)


class LocalBuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ios-local-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "private source"
        self.root.mkdir()
        for directory in ("home", "pub cache", "tmp", "bin", "lib", ".dart_tool", "ios/Pods", "tool/ios", "ios/Frameworks/HiddifyCore.xcframework"):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        (self.root / "dependencies.properties").write_text("core.version=synthetic\n")
        (self.root / "lib/main.dart").write_text("// Synthetic entrypoint, never compiled.\n")
        (self.root / ".dart_tool/package_config.json").write_text("{}")
        (self.root / "ios/Podfile.lock").write_text("synthetic prepared Pods\n")
        (self.root / "ios/Pods/Manifest.lock").write_text("synthetic prepared Pods\n")
        self.core = self.root / "ios/Frameworks/HiddifyCore.xcframework/Info.plist"
        self.core.write_bytes(plistlib.dumps({"Synthetic": True}))
        self.core_bytes = self.core.read_bytes()
        shutil.copyfile(REPO / "tool/ios/local_export_options.py", self.root / "tool/ios/local_export_options.py")
        self.options = self.root / "local export.plist"
        export.write_options(str(self.options), TEAM)
        self.log = self.root / "fake-flutter.jsonl"
        self.unexpected = self.root / "unexpected-command.txt"
        self.attempt = self.root / ".ios-local-attempt"
        self.xcode_root = self.root / "tmp/ios-local-xcode"
        self.xcode_cache = self.xcode_root / "synthetic-cache.txt"
        self.entered = self.root / "fake-entered"
        self.archive = self.root / "build/ios/archive/Runner.xcarchive/synthetic.txt"
        self.ipa = self.root / "build/ios/ipa/synthetic.ipa"
        self.flutter = self.root / "bin/private flutter"
        self.flutter.write_text(
            "#!" + sys.executable + "\n"
            "import json, os, pathlib, sys, time\n"
            "config = pathlib.Path(os.environ['XCODE_XCCONFIG_FILE'])\n"
            "attempt = pathlib.Path('.ios-local-attempt')\n"
            "xcode_root = pathlib.Path(os.environ['HIDDIFY_IOS_LOCAL_XCODE_ROOT'])\n"
            "(xcode_root / 'synthetic-cache.txt').write_text('Synthetic retained cache, not an Xcode product.\\n')\n"
            "row = {'argv': sys.argv[1:], 'config_path': str(config), 'config': config.read_text(), "
            "'config_mode': config.stat().st_mode & 0o777, 'attempt_mode': attempt.stat().st_mode & 0o777, "
            "'xcode_root_mode': xcode_root.stat().st_mode & 0o777, "
            "'env': {k: os.environ[k] for k in ('HOME', 'PUB_CACHE', 'TMPDIR', 'XDG_CONFIG_HOME', 'FLUTTER_SUPPRESS_ANALYTICS', 'HIDDIFY_IOS_LOCAL_XCODE_ROOT')}}\n"
            "with open(os.environ['FAKE_LOG'], 'a') as stream: stream.write(json.dumps(row) + '\\n')\n"
            "release = os.environ.get('FAKE_RELEASE')\n"
            "deadline = time.monotonic() + 10\n"
            "if release: pathlib.Path(os.environ['FAKE_ENTERED']).write_text('synthetic waiting\\n')\n"
            "while release and not pathlib.Path(release).exists():\n"
            "    if time.monotonic() >= deadline: raise SystemExit(96)\n"
            "    time.sleep(0.01)\n"
            "outputs = os.environ.get('FAKE_OUTPUTS', 'all')\n"
            "if outputs != 'none':\n"
            "    archive = pathlib.Path('build/ios/archive/Runner.xcarchive/synthetic.txt')\n"
            "    archive.parent.mkdir(parents=True)\n"
            "    archive.write_text('Synthetic retained archive, not an Xcode product.\\n')\n"
            "if outputs == 'all':\n"
            "    ipa = pathlib.Path('build/ios/ipa/synthetic.ipa')\n"
            "    ipa.parent.mkdir(parents=True)\n"
            "    ipa.write_text('Synthetic retained IPA, not an installable package.\\n')\n"
            "raise SystemExit(int(os.environ.get('FAKE_FLUTTER_EXIT', '0')))\n"
        )
        self.flutter.chmod(0o700)
        for name in ("flutter", "dart", "pod", "xcodebuild", "go", "curl", "wget", "fastforge"):
            guard = self.root / "bin" / name
            guard.write_text(
                "#!" + sys.executable + "\n"
                "import os, pathlib, sys\n"
                "pathlib.Path(os.environ['UNEXPECTED_COMMANDS']).write_text(sys.argv[0])\n"
                "raise SystemExit(97)\n"
            )
            guard.chmod(0o700)
        self.values = {
            "IOS_LOCAL_FLUTTER": str(self.flutter), "IOS_LOCAL_HOME": str(self.root / "home"),
            "IOS_LOCAL_PUB_CACHE": str(self.root / "pub cache"), "IOS_LOCAL_TMPDIR": str(self.root / "tmp"),
            "IOS_LOCAL_EXPORT_OPTIONS": str(self.options), "IOS_LOCAL_BUILD_NUMBER": "60001",
        }

    def run_make(self, updates=None, flags=(), assignments=()):
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith("IOS_LOCAL_") and key not in ("MAKEFLAGS", "MFLAGS", "GNUMAKEFLAGS", "MAKEOVERRIDES")}
        environment.update(self.values)
        for key, value in (updates or {}).items():
            if value is None:
                environment.pop(key, None)
            else:
                environment[key] = value
        environment.update({"FAKE_LOG": str(self.log), "FAKE_ENTERED": str(self.entered),
                            "UNEXPECTED_COMMANDS": str(self.unexpected),
                            "PATH": str(self.root / "bin") + os.pathsep + os.environ.get("PATH", "")})
        return subprocess.run(
            ["make", "--no-print-directory", *flags, "-f", str(REPO / "Makefile"), "-C", str(self.root), "ios-local", *assignments],
            env=environment, capture_output=True, text=True, timeout=20, check=False,
        )

    def assert_blocked(self, result, *, attempt_exists=False, tmp_entries=()):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.log.exists(), result.stdout + result.stderr)
        self.assertFalse(self.unexpected.exists())
        self.assertEqual(self.core.read_bytes(), self.core_bytes)
        self.assertEqual(list((self.root / "tmp").iterdir()), list(tmp_entries))
        self.assertEqual(os.path.lexists(self.attempt), attempt_exists)

    def assert_retry_preserves_attempt(self):
        log = self.log.read_bytes()
        outputs = {path: path.read_bytes() for path in (self.archive, self.ipa) if path.exists()}
        attempt_inode = self.attempt.stat().st_ino
        xcode_inode = self.xcode_root.stat().st_ino
        cache = self.xcode_cache.read_bytes()
        result = self.run_make({"IOS_LOCAL_BUILD_NUMBER": "60002"})
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.log.read_bytes(), log)
        self.assertEqual({path: path.read_bytes() for path in (self.archive, self.ipa) if path.exists()}, outputs)
        self.assertEqual(self.attempt.stat().st_ino, attempt_inode)
        self.assertEqual(self.xcode_root.stat().st_ino, xcode_inode)
        self.assertEqual(self.xcode_cache.read_bytes(), cache)
        self.assertFalse(self.unexpected.exists())
        self.assertEqual(list((self.root / "tmp").iterdir()), [self.xcode_root])

    def write_flutter_config(self, value, *, legacy=False):
        path = self.root / "home" / (".flutter_settings" if legacy else ".config/flutter/settings")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))
        return path

    def test_release_driver_off_private_paths_and_shared_version_override(self):
        result = self.run_make(assignments=("CHANNEL=prod", "TARGET=lib/main_prod.dart", "BUILD_ARGS=--debug --dart-define=driver=true"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(len(calls), 1)
        call = calls[0]
        self.assertEqual(call["argv"], [
            "build", "ipa", "--release", "--no-pub", "--target=lib/main.dart", "--dart-define=driver=false",
            "--build-number=60001", "--export-options-plist=" + str(self.options),
        ])
        self.assertEqual(call["env"], {
            "HOME": self.values["IOS_LOCAL_HOME"], "PUB_CACHE": self.values["IOS_LOCAL_PUB_CACHE"],
            "TMPDIR": self.values["IOS_LOCAL_TMPDIR"], "FLUTTER_SUPPRESS_ANALYTICS": "true",
            "XDG_CONFIG_HOME": str(self.root / "home/.config/flutter"),
            "HIDDIFY_IOS_LOCAL_XCODE_ROOT": str(self.xcode_root),
        })
        self.assertTrue(self.attempt.is_dir())
        self.assertEqual(call["attempt_mode"], 0o700)
        self.assertTrue(self.archive.is_file())
        self.assertTrue(self.ipa.is_file())
        self.assertEqual(call["config"], expected_config("60001"))
        self.assertEqual(call["config_mode"], 0o600)
        self.assertEqual(Path(call["config_path"]).parent, self.root / "tmp")
        self.assertFalse(Path(call["config_path"]).exists())
        self.assertEqual(self.core.read_bytes(), self.core_bytes)
        self.assertFalse(self.unexpected.exists())

    def test_explicit_entrypoint_and_build_number_are_forwarded(self):
        (self.root / "lib/custom entry.dart").write_text("// Synthetic alternate target.\n")
        result = self.run_make({"IOS_LOCAL_TARGET": "lib/custom entry.dart", "IOS_LOCAL_BUILD_NUMBER": "60002"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        call = json.loads(self.log.read_text())
        self.assertIn("--target=lib/custom entry.dart", call["argv"])
        self.assertIn("--build-number=60002", call["argv"])
        self.assertEqual(call["config"], expected_config("60002"))

    def test_xcode_roots_use_a_private_retained_directory_not_an_inherited_root(self):
        inherited = self.root / "inherited-xcode-root"
        result = self.run_make({"HIDDIFY_IOS_LOCAL_XCODE_ROOT": str(inherited)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        call = json.loads(self.log.read_text())
        self.assertEqual(call["env"]["HIDDIFY_IOS_LOCAL_XCODE_ROOT"], str(self.xcode_root))
        self.assertEqual(call["config"], expected_config("60001"))
        self.assertNotIn("BUILD_DIR =", call["config"])
        self.assertNotIn("BUILD_ROOT =", call["config"])
        self.assertEqual(self.xcode_root.parent, Path(self.values["IOS_LOCAL_TMPDIR"]))
        self.assertEqual(call["xcode_root_mode"], 0o700)
        self.assertEqual(self.xcode_root.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.xcode_cache.read_text(), "Synthetic retained cache, not an Xcode product.\n")
        self.assertEqual(list((self.root / "tmp").iterdir()), [self.xcode_root])
        self.assertFalse(inherited.exists())
        self.assertFalse(Path(call["config_path"]).exists())
        self.assert_retry_preserves_attempt()

    def assert_opaque_xcode_root_path(self, tmpdir):
        Path(tmpdir).mkdir(parents=True)
        result = self.run_make({"IOS_LOCAL_TMPDIR": tmpdir})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        call = json.loads(self.log.read_text())
        xcode_root = tmpdir + "/ios-local-xcode"
        self.assertEqual(call["env"]["TMPDIR"], tmpdir)
        self.assertEqual(call["env"]["HIDDIFY_IOS_LOCAL_XCODE_ROOT"], xcode_root)
        self.assertEqual(call["config"], expected_config("60001"))
        self.assertNotIn(tmpdir, call["config"])
        self.assertEqual(call["xcode_root_mode"], 0o700)
        self.assertEqual(Path(call["config_path"]).parent, Path(tmpdir))
        self.assertFalse(Path(call["config_path"]).exists())
        self.assertEqual(list(Path(tmpdir).iterdir()), [Path(xcode_root)])
        self.assertEqual((Path(xcode_root) / "synthetic-cache.txt").read_text(),
                         "Synthetic retained cache, not an Xcode product.\n")
        self.assertEqual(len(self.log.read_text().splitlines()), 1)
        self.assertTrue(self.attempt.is_dir())
        self.assertEqual(self.core.read_bytes(), self.core_bytes)
        self.assertFalse(self.unexpected.exists())

    def test_xcode_root_path_with_spaces_and_shell_symbols_stays_in_environment(self):
        tmpdir = str(self.root / "tmp spaces #; ' \" $(touch xcode-command-ran) `touch xcode-backtick-ran`") + "//private"
        self.assert_opaque_xcode_root_path(tmpdir)
        self.assertFalse((self.root / "xcode-command-ran").exists())
        self.assertFalse((self.root / "xcode-backtick-ran").exists())

    def test_xcode_root_path_cannot_inject_xcconfig_lines_or_comments(self):
        tmpdir = str(self.root / "tmp\nBUILD_DIR = injected\n") + "//private"
        self.assert_opaque_xcode_root_path(tmpdir)

    def assert_existing_xcode_root_preserved(self, kind):
        target = self.root / "retained-xcode-target"
        target.mkdir()
        retained = target / "retained.txt"
        retained.write_bytes(b"retained Xcode target")
        if kind == "directory":
            self.xcode_root.mkdir(mode=0o755)
            (self.xcode_root / "retained.txt").write_bytes(b"retained Xcode root")
        elif kind == "file":
            self.xcode_root.write_bytes(b"retained Xcode root")
        else:
            self.xcode_root.symlink_to(target if kind == "link" else self.root / "absent-xcode-target")
        original = self.xcode_root.lstat()
        result = self.run_make()
        self.assert_blocked(result, attempt_exists=True, tmp_entries=(self.xcode_root,))
        self.assertIn("Xcode root already exists or cannot be created", result.stderr)
        attempt_inode = self.attempt.stat().st_ino
        self.assertEqual(self.attempt.stat().st_mode & 0o777, 0o700)
        retry = self.run_make({"IOS_LOCAL_BUILD_NUMBER": "60002"})
        self.assert_blocked(retry, attempt_exists=True, tmp_entries=(self.xcode_root,))
        self.assertIn("workspace is already claimed or unavailable", retry.stderr)
        self.assertEqual(self.attempt.stat().st_ino, attempt_inode)
        self.assertEqual(self.xcode_root.lstat().st_ino, original.st_ino)
        self.assertEqual(self.xcode_root.lstat().st_mode, original.st_mode)
        self.assertFalse((self.root / "build").exists())
        if kind == "directory":
            self.assertEqual(list(self.xcode_root.iterdir()), [self.xcode_root / "retained.txt"])
            self.assertEqual((self.xcode_root / "retained.txt").read_bytes(), b"retained Xcode root")
        elif kind == "file":
            self.assertEqual(self.xcode_root.read_bytes(), b"retained Xcode root")
        else:
            expected = target if kind == "link" else self.root / "absent-xcode-target"
            self.assertEqual(os.readlink(self.xcode_root), str(expected))
            self.assertFalse((self.root / "absent-xcode-target").exists())
        self.assertEqual(retained.read_bytes(), b"retained Xcode target")
        self.assertEqual(list(target.iterdir()), [retained])

    def test_existing_xcode_root_directory_is_not_reused_or_removed(self):
        self.assert_existing_xcode_root_preserved("directory")

    def test_existing_xcode_root_file_is_not_replaced(self):
        self.assert_existing_xcode_root_preserved("file")

    def test_existing_xcode_root_symlink_is_not_followed_or_replaced(self):
        self.assert_existing_xcode_root_preserved("link")

    def test_existing_xcode_root_dangling_symlink_is_not_replaced(self):
        self.assert_existing_xcode_root_preserved("dangling-link")

    def test_all_private_inputs_and_build_number_are_mandatory(self):
        for key in self.values:
            with self.subTest(key=key):
                self.assert_blocked(self.run_make({key: None}))

    def test_relative_private_paths_are_rejected(self):
        for key in self.values.keys() - {"IOS_LOCAL_BUILD_NUMBER"}:
            with self.subTest(key=key):
                self.assert_blocked(self.run_make({key: "relative/path"}))

    def test_invalid_build_numbers_never_reach_flutter(self):
        for number in ("", "0", "01", "-1", "1.2", " 42", "42\n", "42;exit 0"):
            with self.subTest(number=number):
                self.assert_blocked(self.run_make({"IOS_LOCAL_BUILD_NUMBER": number}))

    def test_missing_private_directory_executable_or_entrypoint_are_rejected(self):
        for key in ("IOS_LOCAL_HOME", "IOS_LOCAL_PUB_CACHE", "IOS_LOCAL_TMPDIR", "IOS_LOCAL_FLUTTER", "IOS_LOCAL_TARGET"):
            with self.subTest(key=key):
                self.assert_blocked(self.run_make({key: str(self.root / "not-prepared")}))

    def test_missing_core_fails_without_replacement_or_download(self):
        retained = self.core.parent.with_name("retained-synthetic-core")
        self.core.parent.rename(retained)
        result = self.run_make()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Prebuilt ios/Frameworks/HiddifyCore.xcframework is required", result.stderr)
        self.assertFalse(self.core.parent.exists())
        self.assertEqual((retained / "Info.plist").read_bytes(), self.core_bytes)
        self.assertFalse(self.log.exists())
        self.assertFalse(self.unexpected.exists())

    def test_unprepared_pub_or_stale_pods_are_rejected(self):
        package_config = self.root / ".dart_tool/package_config.json"
        package_config.unlink()
        self.assert_blocked(self.run_make())
        package_config.write_text("{}")
        (self.root / "ios/Pods/Manifest.lock").write_text("stale synthetic Pods\n")
        self.assert_blocked(self.run_make())

    def test_legacy_or_upload_export_options_are_rejected(self):
        self.assert_blocked(self.run_make({"IOS_LOCAL_EXPORT_OPTIONS": str(REPO / "ios/exportOptions.plist")}))
        unsafe = export.local_options(TEAM)
        unsafe["destination"] = "upload"
        self.options.write_bytes(plistlib.dumps(unsafe))
        self.assert_blocked(self.run_make())

    def test_flutter_failure_preserves_outputs_and_only_removes_own_config(self):
        result = self.run_make({"FAKE_FLUTTER_EXIT": "9"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Error 9", result.stderr)
        call = json.loads(self.log.read_text())
        self.assertFalse(Path(call["config_path"]).exists())
        self.assertEqual(self.core.read_bytes(), self.core_bytes)
        self.assertTrue(self.options.exists())
        self.assertTrue(self.archive.is_file())
        self.assertTrue(self.ipa.is_file())
        self.assertTrue(self.attempt.is_dir())
        self.assertFalse(self.unexpected.exists())
        self.assert_retry_preserves_attempt()

    def test_successful_attempt_blocks_normal_retry_with_another_build_number(self):
        result = self.run_make()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_retry_preserves_attempt()

    def test_preflight_failure_can_be_corrected_before_first_attempt(self):
        self.assert_blocked(self.run_make({"IOS_LOCAL_BUILD_NUMBER": None}))
        result = self.run_make()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_retry_preserves_attempt()

    def test_failure_before_any_outputs_still_consumes_the_attempt(self):
        result = self.run_make({"FAKE_FLUTTER_EXIT": "9", "FAKE_OUTPUTS": "none"})
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.attempt.is_dir())
        self.assertFalse((self.root / "build").exists())
        self.assert_retry_preserves_attempt()

    def test_archive_only_zero_exit_still_retains_archive_and_attempt(self):
        # Flutter 3.38.5 can return success after archive success/export failure.
        # This fixture is not evidence of an IPA; a retry must still be blocked.
        result = self.run_make({"FAKE_OUTPUTS": "archive"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.archive.is_file())
        self.assertFalse(self.ipa.exists())
        self.assert_retry_preserves_attempt()

    def test_concurrent_claim_is_blocked_before_first_attempt_writes_outputs(self):
        release = self.root / "release-fake"
        with ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(self.run_make, {"FAKE_RELEASE": str(release)})
            try:
                deadline = time.monotonic() + 5
                while not self.entered.exists() and not future.done() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(self.entered.exists(), "fake Flutter did not reach the controlled wait")
                self.assertFalse(future.done())
                self.assertFalse((self.root / "build").exists())
                second = self.run_make()
                self.assertNotEqual(second.returncode, 0, second.stdout + second.stderr)
                self.assertIn("workspace is already claimed or unavailable", second.stderr)
                self.assertFalse(future.done())
                self.assertEqual(len(self.log.read_text().splitlines()), 1)
                self.assertFalse((self.root / "build").exists())
            finally:
                release.write_text("release synthetic process\n")
                first = future.result(timeout=20)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assert_retry_preserves_attempt()

    def test_existing_attempt_file_directory_and_links_are_never_removed(self):
        target = self.root / "retained-marker-target"
        target.write_bytes(b"retained target")
        for kind in ("file", "directory", "link", "dangling-link"):
            with self.subTest(kind=kind):
                if kind == "directory":
                    self.attempt.mkdir()
                    (self.attempt / "retained.txt").write_bytes(b"retained claim")
                elif kind == "file":
                    self.attempt.write_bytes(b"retained claim")
                else:
                    self.attempt.symlink_to(target if kind == "link" else self.root / "absent-marker-target")
                inode = self.attempt.lstat().st_ino
                self.assert_blocked(self.run_make(), attempt_exists=True)
                self.assertEqual(self.attempt.lstat().st_ino, inode)
                if self.attempt.is_symlink():
                    expected = target if kind == "link" else self.root / "absent-marker-target"
                    self.assertEqual(os.readlink(self.attempt), str(expected))
                    self.attempt.unlink()
                elif kind == "directory":
                    self.assertEqual((self.attempt / "retained.txt").read_bytes(), b"retained claim")
                    (self.attempt / "retained.txt").unlink()
                    self.attempt.rmdir()
                else:
                    self.assertEqual(self.attempt.read_bytes(), b"retained claim")
                    self.attempt.unlink()
                self.assertEqual(target.read_bytes(), b"retained target")

    def test_existing_archive_and_ipa_file_directory_and_links_are_preserved(self):
        target = self.root / "retained-output-target"
        target.write_bytes(b"retained output target")
        for relative in ("build/ios/archive", "build/ios/ipa"):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            for kind in ("file", "directory", "link", "dangling-link"):
                with self.subTest(output=relative, kind=kind):
                    if kind == "directory":
                        path.mkdir()
                        (path / "retained.txt").write_bytes(b"retained artifact")
                    elif kind == "file":
                        path.write_bytes(b"retained artifact")
                    else:
                        path.symlink_to(target if kind == "link" else self.root / "absent-output-target")
                    inode = path.lstat().st_ino
                    result = self.run_make()
                    self.assert_blocked(result)
                    self.assertIn("Preserving existing iOS output", result.stderr)
                    self.assertEqual(path.lstat().st_ino, inode)
                    if path.is_symlink():
                        expected = target if kind == "link" else self.root / "absent-output-target"
                        self.assertEqual(os.readlink(path), str(expected))
                        path.unlink()
                    elif kind == "directory":
                        self.assertEqual((path / "retained.txt").read_bytes(), b"retained artifact")
                        (path / "retained.txt").unlink()
                        path.rmdir()
                    else:
                        self.assertEqual(path.read_bytes(), b"retained artifact")
                        path.unlink()
                    self.assertEqual(target.read_bytes(), b"retained output target")

    def test_output_parent_files_and_links_are_rejected_before_traversal(self):
        target = self.root / "retained-output-parent"
        target.mkdir()
        (target / "retained.txt").write_bytes(b"retained parent")
        for relative in ("build", "build/ios"):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            for kind in ("file", "link", "dangling-link"):
                with self.subTest(parent=relative, kind=kind):
                    if kind == "file":
                        path.write_bytes(b"retained parent file")
                    else:
                        path.symlink_to(target if kind == "link" else self.root / "absent-output-parent")
                    inode = path.lstat().st_ino
                    result = self.run_make()
                    self.assert_blocked(result)
                    self.assertIn("Refusing non-directory or linked output parent", result.stderr)
                    self.assertEqual(path.lstat().st_ino, inode)
                    if path.is_symlink():
                        expected = target if kind == "link" else self.root / "absent-output-parent"
                        self.assertEqual(os.readlink(path), str(expected))
                    else:
                        self.assertEqual(path.read_bytes(), b"retained parent file")
                    path.unlink()
                    self.assertEqual((target / "retained.txt").read_bytes(), b"retained parent")
                    self.assertEqual(list(target.iterdir()), [target / "retained.txt"])

    def test_configured_nondefault_build_directories_are_rejected_in_both_locations(self):
        for legacy in (False, True):
            for value in ("another-build", "../build", "build/", "./build", "", str(self.root / "other-build"), False, 7, ["build"]):
                with self.subTest(legacy=legacy, value=value):
                    path = self.write_flutter_config({"build-dir": value}, legacy=legacy)
                    raw = path.read_bytes()
                    result = self.run_make()
                    self.assert_blocked(result)
                    self.assertIn("requires default Flutter build-dir", result.stderr)
                    self.assertEqual(path.read_bytes(), raw)
                    path.unlink()

    def test_malformed_flutter_configuration_is_not_deleted_or_repaired(self):
        for legacy in (False, True):
            path = self.write_flutter_config({}, legacy=legacy)
            for raw in ("{", "[]", "null", "NaN", '{"build-dir": NaN}'):
                with self.subTest(legacy=legacy, raw=raw):
                    path.write_text(raw)
                    self.assert_blocked(self.run_make())
                    self.assertEqual(path.read_text(), raw)
            path.unlink()

    def test_configuration_links_are_rejected_without_following_fixture_targets(self):
        target = self.root / "retained-config-target"
        target.write_bytes(b"retained configuration")
        for relative in ("home/.flutter_settings", "home/.config", "home/.config/flutter", "home/.config/flutter/settings"):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            for dangling in (False, True):
                with self.subTest(path=relative, dangling=dangling):
                    destination = self.root / "absent-config-target" if dangling else target
                    path.symlink_to(destination)
                    result = self.run_make()
                    self.assert_blocked(result)
                    self.assertIn("regular private configuration paths", result.stderr)
                    self.assertEqual(os.readlink(path), str(destination))
                    path.unlink()
                    self.assertEqual(target.read_bytes(), b"retained configuration")

    def test_null_build_dir_and_existing_empty_output_parents_use_default(self):
        self.write_flutter_config({"build-dir": None})
        (self.root / "build/ios").mkdir(parents=True)
        result = self.run_make()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.archive.is_file())
        self.assertTrue(self.ipa.is_file())

    def test_legacy_settings_take_precedence_over_private_xdg_settings(self):
        self.write_flutter_config({"build-dir": "unused-alternate-build"})
        self.write_flutter_config({"build-dir": "build"}, legacy=True)
        result = self.run_make()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.archive.is_file())
        self.assertFalse((self.root / "unused-alternate-build").exists())

    def test_inherited_xdg_cannot_redirect_the_actual_output_directory(self):
        inherited = self.root / "inherited-config"
        inherited.mkdir()
        settings = inherited / "settings"
        settings.write_text('{"build-dir": "inherited-build"}')
        original = settings.read_bytes()
        result = self.run_make({"XDG_CONFIG_HOME": str(inherited)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        call = json.loads(self.log.read_text())
        self.assertEqual(call["env"]["XDG_CONFIG_HOME"], str(self.root / "home/.config/flutter"))
        self.assertEqual(settings.read_bytes(), original)
        self.assertFalse((self.root / "inherited-build").exists())

    def test_make_dry_run_does_not_run_flutter_or_preparation(self):
        result = self.run_make(flags=("-n",))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("build ipa --release --no-pub", result.stdout)
        for forbidden in ("ios-prepare", "ios-libs", "pod install", "pub get", "build_runner", "curl ", "fastforge package"):
            self.assertNotIn(forbidden, result.stdout)
        self.assertFalse(self.log.exists())
        self.assertFalse(self.unexpected.exists())
        self.assertFalse(os.path.lexists(self.attempt))
        self.assertFalse((self.root / "build").exists())


class WorkflowContractTests(unittest.TestCase):
    def test_release_callers_require_upstream_and_preserve_ci_filter(self):
        for name, condition in (
            ("ci.yml", "github.repository == 'hiddify/hiddify-app' && !contains(github.event.head_commit.message, 'release: version')"),
            ("release.yml", "github.repository == 'hiddify/hiddify-app'"),
        ):
            with self.subTest(workflow=name):
                text = (REPO / ".github/workflows" / name).read_text()
                self.assertEqual(text.count("uses: ./.github/workflows/build.yml"), 1)
                expression = "${{ " + condition + " }}"
                # The original CI filter contains a colon-space, so YAML needs quotes.
                if name == "ci.yml":
                    expression = '"' + expression + '"'
                self.assertIn("    if: " + expression + "\n", text)

    def test_safe_checks_only_trigger_for_prs_and_feature_pushes(self):
        text = (REPO / ".github/workflows/fork-checks.yml").read_text()
        triggers = text.split("on:\n", 1)[1].split("\npermissions:", 1)[0]
        self.assertEqual(triggers.strip(), "pull_request:\n  push:\n    branches:\n      - 'feat/**'\n      - 'feature/**'")
        self.assertIn("permissions:\n  contents: read\n", text)
        self.assertIn("persist-credentials: false", text)
        self.assertIn("submodules: false", text)
        for forbidden in ("secrets:", "secrets.", "write-all", "contents: write", "./.github/workflows/", "pull_request_target", "continue-on-error", "if:"):
            self.assertNotIn(forbidden, text)
        for suite in ("tool/ping0", "tool/ios"):
            self.assertIn("python3 -B -m unittest discover -s " + suite + " -p 'test_*.py' -v", text)


if __name__ == "__main__":
    unittest.main()
