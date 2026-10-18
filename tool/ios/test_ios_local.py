"""Make contract tests: only a fake Flutter executable runs, never build tools."""

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

import local_export_options as export


REPO = Path(__file__).parents[2]
TEAM = "AB12CD34EF"


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
        self.flutter = self.root / "bin/private flutter"
        self.flutter.write_text(
            "#!" + sys.executable + "\n"
            "import json, os, pathlib, sys\n"
            "config = pathlib.Path(os.environ['XCODE_XCCONFIG_FILE'])\n"
            "row = {'argv': sys.argv[1:], 'config_path': str(config), 'config': config.read_text(), "
            "'config_mode': config.stat().st_mode & 0o777, "
            "'env': {k: os.environ[k] for k in ('HOME', 'PUB_CACHE', 'TMPDIR', 'FLUTTER_SUPPRESS_ANALYTICS')}}\n"
            "with open(os.environ['FAKE_LOG'], 'a') as stream: stream.write(json.dumps(row) + '\\n')\n"
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
        environment.update({"FAKE_LOG": str(self.log), "UNEXPECTED_COMMANDS": str(self.unexpected),
                            "PATH": str(self.root / "bin") + os.pathsep + os.environ.get("PATH", "")})
        return subprocess.run(
            ["make", "--no-print-directory", *flags, "-f", str(REPO / "Makefile"), "-C", str(self.root), "ios-local", *assignments],
            env=environment, capture_output=True, text=True, timeout=20, check=False,
        )

    def assert_blocked(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.log.exists(), result.stdout + result.stderr)
        self.assertFalse(self.unexpected.exists())
        self.assertEqual(self.core.read_bytes(), self.core_bytes)
        self.assertEqual(list((self.root / "tmp").iterdir()), [])

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
        })
        self.assertEqual(call["config"], "FLUTTER_BUILD_NUMBER = 60001\nCURRENT_PROJECT_VERSION = 60001\n")
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
        self.assertEqual(call["config"], "FLUTTER_BUILD_NUMBER = 60002\nCURRENT_PROJECT_VERSION = 60002\n")

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

    def test_flutter_failure_propagates_and_only_own_config_is_removed(self):
        result = self.run_make({"FAKE_FLUTTER_EXIT": "9"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Error 9", result.stderr)
        call = json.loads(self.log.read_text())
        self.assertFalse(Path(call["config_path"]).exists())
        self.assertEqual(self.core.read_bytes(), self.core_bytes)
        self.assertTrue(self.options.exists())
        self.assertFalse(self.unexpected.exists())

    def test_make_dry_run_does_not_run_flutter_or_preparation(self):
        result = self.run_make(flags=("-n",))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("build ipa --release --no-pub", result.stdout)
        for forbidden in ("ios-prepare", "ios-libs", "pod install", "pub get", "build_runner", "curl ", "fastforge package"):
            self.assertNotIn(forbidden, result.stdout)
        self.assertFalse(self.log.exists())
        self.assertFalse(self.unexpected.exists())


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
