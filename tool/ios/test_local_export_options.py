"""Pure plist/CLI tests using only small, disposable local fixtures."""

import contextlib
import io
from pathlib import Path
import plistlib
import tempfile
import unittest

import local_export_options as export


TEAM = "AB12CD34EF"  # Synthetic, not a signing identity.


class ExportOptionsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ios-export-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = self.root / "local export.plist"

    def assert_cli_error(self, argv):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as result:
            export.main(argv)
        self.assertEqual(result.exception.code, 2)

    def test_both_local_methods_round_trip_and_check_without_modification(self):
        for method in export.METHODS:
            with self.subTest(method=method):
                output = self.root / (method + ".plist")
                export.write_options(str(output), TEAM, method)
                raw = output.read_bytes()
                self.assertEqual(plistlib.loads(raw), export.local_options(TEAM, method))
                self.assertEqual(output.stat().st_mode & 0o777, 0o600)
                self.assertEqual(export.main(["--check", str(output)]), 0)
                self.assertEqual(output.read_bytes(), raw)

    def test_default_is_debugging_with_no_upload_or_version_management(self):
        self.assertEqual(export.main(["--team-id", TEAM, "--output", str(self.output)]), 0)
        options = plistlib.loads(self.output.read_bytes())
        self.assertEqual(options, {
            "destination": "export", "method": "debugging", "teamID": TEAM,
            "signingStyle": "automatic", "uploadSymbols": False,
            "manageAppVersionAndBuildNumber": False,
        })

    def test_team_is_required_and_strict(self):
        for team in (None, "", "abc1234567", " AB12CD34EF", "AB12CD34EF\n", "AB12CD34E", "AB12CD34EF0", "AB12CD34E-", "ＡB12CD34EF", 1234567890):
            with self.subTest(team=team), self.assertRaises(ValueError):
                export.write_options(str(self.output), team)
        self.assertFalse(self.output.exists())
        self.assert_cli_error(["--output", str(self.output)])

    def test_distribution_methods_are_rejected_before_writing(self):
        for method in ("app-store", "app-store-connect", "ad-hoc", "release-testing", "enterprise", "debug", "", None):
            with self.subTest(method=method), self.assertRaises(ValueError):
                export.write_options(str(self.output), TEAM, method)
        self.assertFalse(self.output.exists())
        self.assert_cli_error(["--team-id", TEAM, "--output", str(self.output), "--method", "app-store"])

    def test_output_requires_absolute_plain_plist_path(self):
        for path in ("local.plist", "", str(self.root / "local.json"), str(self.root) + "/../local.plist", str(self.root / "bad\n.plist"), str(self.root / "bad\x00.plist")):
            with self.subTest(path=path), self.assertRaises(ValueError):
                export.write_options(path, TEAM)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_existing_output_is_never_overwritten(self):
        self.output.write_bytes(b"preserved original options")
        with self.assertRaises(FileExistsError):
            export.write_options(str(self.output), TEAM)
        self.assertEqual(self.output.read_bytes(), b"preserved original options")
        self.assert_cli_error(["--team-id", TEAM, "--output", str(self.output)])
        self.assertEqual(self.output.read_bytes(), b"preserved original options")

    def test_output_symlinks_are_refused_without_following_them(self):
        # The targets are inside this fixture, never external files.
        for name, exists in (("existing.plist", True), ("absent.plist", False)):
            with self.subTest(exists=exists):
                target = self.root / name
                if exists:
                    target.write_bytes(b"original")
                link = self.root / ("link-" + name)
                link.symlink_to(target.name)
                with self.assertRaises(FileExistsError):
                    export.write_options(str(link), TEAM)
                self.assertTrue(link.is_symlink())
                self.assertEqual(target.exists(), exists)
                if exists:
                    self.assertEqual(target.read_bytes(), b"original")

    def test_missing_parent_is_not_created(self):
        output = self.root / "not-prepared" / "local.plist"
        with self.assertRaises(FileNotFoundError):
            export.write_options(str(output), TEAM)
        self.assertFalse(output.parent.exists())

    def test_validator_rejects_upload_signing_and_type_changes(self):
        for key, value in (
            ("uploadSymbols", True), ("uploadSymbols", 0),
            ("manageAppVersionAndBuildNumber", True), ("manageAppVersionAndBuildNumber", 0),
            ("destination", "upload"), ("signingStyle", "manual"),
            ("method", "app-store"), ("teamID", "invalid"),
            ("provisioningProfiles", {}), ("signingCertificate", "synthetic certificate"),
            ("unknownOption", False),
        ):
            with self.subTest(key=key, value=value):
                options = export.local_options(TEAM)
                options[key] = value
                with self.assertRaises(ValueError):
                    export.validate_options(options)
        for options in ([], None, {}, {"method": "debugging", "teamID": TEAM}):
            with self.subTest(options=options), self.assertRaises(ValueError):
                export.validate_options(options)

    def test_check_rejects_symlinks_and_does_not_write(self):
        self.output.symlink_to("never-created.plist")
        self.assert_cli_error(["--check", str(self.output)])
        self.assertTrue(self.output.is_symlink())
        self.assertFalse((self.root / "never-created.plist").exists())
        self.assert_cli_error(["--check", str(self.root / "missing.plist")])
        self.assertFalse((self.root / "missing.plist").exists())

    def test_malformed_or_non_dictionary_plist_has_a_cli_error_without_writing(self):
        for raw in (b"not a plist", b"<?xml version='1.0'?><plist><dict>", plistlib.dumps([])):
            with self.subTest(raw=raw):
                self.output.write_bytes(raw)
                self.assert_cli_error(["--check", str(self.output)])
                self.assertEqual(self.output.read_bytes(), raw)

    def test_cli_refuses_missing_conflicting_and_ignored_parameters(self):
        for argv in (
            [], ["--team-id", TEAM],
            ["--output", str(self.output), "--check", str(self.output)],
            ["--check", str(self.output), "--team-id", TEAM],
            ["--check", str(self.output), "--method", "development"],
        ):
            with self.subTest(argv=argv):
                self.assert_cli_error(argv)
        self.assertFalse(self.output.exists())

    def test_legacy_app_store_plist_is_rejected_and_unchanged(self):
        legacy = Path(__file__).parents[2] / "ios" / "exportOptions.plist"
        original = legacy.read_bytes()
        with self.assertRaises(ValueError):
            export.check_options(str(legacy))
        self.assertEqual(legacy.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
