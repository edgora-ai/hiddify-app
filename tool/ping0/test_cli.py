"""Synthetic approval validation and rejected preflight tests; no evidence I/O or capture."""

import copy
import hashlib
import json
from pathlib import Path
import unittest

import ping0


def packed(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8")


def reference(path, raw):
    return {"path": str(path), "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}


class StoragePolicyTests(unittest.TestCase):
    def setUp(self):
        self.environ = {
            "PING0_VOLUME_UUID": "11111111-1111-4111-8111-111111111111",
            "PING0_HOST_UUID": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "PING0_VOLUME_PATH": "/Volumes/SyntheticBuild",
            "PING0_HOST_PATH": "/Volumes/SyntheticHost",
        }

    def test_explicit_policy_is_detached_and_normalizes_uuid_case(self):
        original = dict(self.environ)
        policy = ping0.capture_storage_policy(self.environ)
        self.assertEqual(policy["volume_path"], self.environ["PING0_VOLUME_PATH"])
        self.assertEqual(policy["host_path"], self.environ["PING0_HOST_PATH"])
        self.assertEqual(policy["host_uuid"], self.environ["PING0_HOST_UUID"].upper())
        policy["volume_path"] = "/Volumes/Other"
        self.assertEqual(self.environ, original)

    def test_missing_identity_or_mount_cannot_use_a_machine_default(self):
        for key in self.environ:
            with self.subTest(key=key):
                values = dict(self.environ)
                del values[key]
                with self.assertRaises(ping0.StorageError):
                    ping0.capture_storage_policy(values)
        with self.assertRaises(ping0.StorageError):
            ping0.capture_storage_policy({})

    def test_malformed_uuid_values_are_rejected(self):
        for key in ("PING0_VOLUME_UUID", "PING0_HOST_UUID"):
            for value in (None, False, 1, "", "invalid", " " + self.environ[key], self.environ[key] + "\n"):
                with self.subTest(key=key, value=value):
                    values = dict(self.environ)
                    values[key] = value
                    with self.assertRaises(ping0.StorageError):
                        ping0.capture_storage_policy(values)

    def test_mounts_are_explicit_normalized_volume_paths(self):
        for key in ("PING0_VOLUME_PATH", "PING0_HOST_PATH"):
            for value in (None, False, "relative", "/", "/Volumes", "/Volumes/", "/Volumes/A/../B", "/Volumes//A", "/Volumes/A/", "/Volumes/A" + chr(0)):
                with self.subTest(key=key, value=value):
                    values = dict(self.environ)
                    values[key] = value
                    with self.assertRaises(ping0.StorageError):
                        ping0.capture_storage_policy(values)

    def test_host_and_build_volume_must_have_distinct_identities(self):
        for first, second in (("PING0_VOLUME_UUID", "PING0_HOST_UUID"), ("PING0_VOLUME_PATH", "PING0_HOST_PATH")):
            with self.subTest(field=first):
                values = dict(self.environ)
                values[second] = values[first]
                with self.assertRaises(ping0.StorageError):
                    ping0.capture_storage_policy(values)


class AdditionalApprovalTests(unittest.TestCase):
    def setUp(self):
        self.task = Path("/synthetic/ping0-task")
        self.marker = {
            "directory": str(self.task),
            "control_directory": "/synthetic/control",
            "maximum_live_rounds": {"desktop": 1, "ipad": 1},
            "maximum_run_bytes": 16777216,
            "maximum_task_bytes": 41943040,
        }
        text = "Synthetic user message permitting exactly one additional desktop round."
        self.authorization_raw = ("# Synthetic authorization\n\n" + text + "\n").encode("utf-8")
        self.prior_attempt_raw = packed({
            "scope_id": "run-synthetic-a1", "run_directory": str(self.task / "desktop-a1"),
            "automatic_retry": False, "maximum_navigations": 1,
        })
        self.prior_manifest_raw = packed({"schema_version": 1, "scope_id": "run-synthetic-a1"})
        self.approval = {
            "schema_version": 1,
            "action": "additional-desktop-round",
            "task_directory": str(self.task),
            "run_name": "desktop-a2",
            "additional_rounds": 1,
            "maximum_navigations": 1,
            "deadline_seconds": 90,
            "cleanup_only_seconds": 5,
            "maximum_run_bytes": 16777216,
            "maximum_task_bytes": 41943040,
            "original_remaining_bytes_preserved": 51539607552,
            "automatic_retry": False,
            "user_authorization": {
                "kind": "user-message", "text": text,
                "sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
            },
            "authorization_record": reference(
                Path(self.marker["control_directory"]) / "additional-desktop-a2-authorization.md",
                self.authorization_raw,
            ),
            "prior_attempt": reference(self.task / "desktop-attempt.json", self.prior_attempt_raw),
            "prior_manifest": reference(self.task / "desktop-a1" / "manifest.json", self.prior_manifest_raw),
        }

    def validate(self, approval=None, **changes):
        return ping0.validate_additional_approval(
            self.approval if approval is None else approval,
            changes.get("task_path", self.task), changes.get("marker", self.marker),
            changes.get("authorization_raw", self.authorization_raw),
            changes.get("prior_attempt_raw", self.prior_attempt_raw),
            changes.get("prior_manifest_raw", self.prior_manifest_raw),
        )

    def test_valid_approval_returns_detached_summary_without_mutating_inputs(self):
        before = copy.deepcopy((self.approval, self.marker))
        result = self.validate()
        self.assertEqual(result["run_name"], "desktop-a2")
        self.assertEqual(result["additional_rounds"], 1)
        self.assertIs(result["automatic_retry"], False)
        self.assertEqual(result["original_remaining_bytes_preserved"], 51539607552)
        for key in ("authorization_record", "prior_attempt", "prior_manifest"):
            self.assertEqual(result[key], self.approval[key])
        self.assertEqual(result["user_authorization"]["sha256"], self.approval["user_authorization"]["sha256"])
        self.assertNotIn("text", result["user_authorization"])
        result["prior_attempt"]["path"] = "/synthetic/not-evidence"
        self.assertEqual((self.approval, self.marker), before)

    def test_receipt_scope_schema_and_action_are_exact(self):
        for key, value in (
            ("schema_version", 2), ("schema_version", True), ("schema_version", 1.0),
            ("action", "desktop-round"), ("task_directory", "/synthetic/other-task"),
            ("run_name", "desktop-a1"), ("run_name", "desktop-a3"),
            ("run_name", "other/desktop-a2"), ("run_name", "ipad-a2"),
        ):
            with self.subTest(key=key, value=value):
                approval = copy.deepcopy(self.approval)
                approval[key] = value
                with self.assertRaises(ping0.StorageError):
                    self.validate(approval)
        with self.assertRaises(ping0.StorageError):
            self.validate([])

    def test_rounds_budgets_deadlines_and_retry_cannot_change(self):
        for key, value in (
            ("additional_rounds", 0), ("additional_rounds", 2), ("additional_rounds", -1),
            ("additional_rounds", True), ("additional_rounds", 1.0), ("additional_rounds", "1"),
            ("maximum_navigations", 2), ("maximum_navigations", True),
            ("deadline_seconds", 91), ("deadline_seconds", 90.0), ("cleanup_only_seconds", 6),
            ("maximum_run_bytes", 16777217), ("maximum_run_bytes", 16777215),
            ("maximum_task_bytes", 41943041), ("original_remaining_bytes_preserved", 51539607551),
            ("original_remaining_bytes_preserved", 51539607553),
            ("automatic_retry", True), ("automatic_retry", 0), ("automatic_retry", None),
        ):
            with self.subTest(key=key, value=value):
                approval = copy.deepcopy(self.approval)
                approval[key] = value
                with self.assertRaises(ping0.StorageError):
                    self.validate(approval)

    def test_original_marker_limits_and_absolute_paths_are_required(self):
        for key, value in (
            ("directory", "/synthetic/other-task"),
            ("maximum_live_rounds", {"desktop": 2, "ipad": 1}),
            ("maximum_live_rounds", {"desktop": True, "ipad": 1}),
            ("maximum_live_rounds", {"desktop": 1, "ipad": 1.0}),
            ("maximum_run_bytes", 16777217), ("maximum_task_bytes", 41943041),
            ("maximum_run_bytes", 16777216.0), ("maximum_task_bytes", 41943040.0),
            ("control_directory", "synthetic/control"),
            ("control_directory", "/synthetic/control/../other"),
        ):
            with self.subTest(key=key, value=value):
                marker = copy.deepcopy(self.marker)
                marker[key] = value
                with self.assertRaises(ping0.StorageError):
                    self.validate(marker=marker)
        with self.assertRaises(ping0.StorageError):
            self.validate(task_path=Path("synthetic/ping0-task"))

    def test_user_message_kind_text_and_utf8_sha_are_required(self):
        for key, value in (
            ("kind", "receipt"), ("kind", None), ("text", ""), ("text", " \n\t"),
            ("text", None), ("text", 1), ("text", "Different synthetic message"),
            ("sha256", "0" * 64),
        ):
            with self.subTest(key=key, value=value):
                approval = copy.deepcopy(self.approval)
                approval["user_authorization"][key] = value
                if key == "text" and isinstance(value, str) and not value.strip():
                    approval["user_authorization"]["sha256"] = hashlib.sha256(value.encode("utf-8")).hexdigest()
                with self.assertRaises(ping0.StorageError):
                    self.validate(approval)

    def test_all_references_require_exact_path_bytes_and_sha(self):
        for key in ("authorization_record", "prior_attempt", "prior_manifest"):
            for field, value in (
                ("path", self.approval[key]["path"] + ".old"),
                ("bytes", self.approval[key]["bytes"] + 1), ("bytes", True),
                ("bytes", float(self.approval[key]["bytes"])), ("sha256", "0" * 64),
            ):
                with self.subTest(key=key, field=field):
                    approval = copy.deepcopy(self.approval)
                    approval[key][field] = value
                    with self.assertRaises(ping0.StorageError):
                        self.validate(approval)

    def test_changed_authorization_old_claim_or_manifest_bytes_are_rejected(self):
        for key, raw in (
            ("authorization_raw", self.authorization_raw + b"changed"),
            ("prior_attempt_raw", packed({"scope_id": "run-old-claim"})),
            ("prior_manifest_raw", self.prior_manifest_raw + b"changed"),
        ):
            with self.subTest(key=key):
                with self.assertRaises(ping0.StorageError):
                    self.validate(**{key: raw})

    def test_rehashed_claim_still_must_match_a1_task_and_manifest_scope(self):
        for field, value in (
            ("run_directory", str(self.task / "desktop-a2")),
            ("run_directory", "/synthetic/other-task/desktop-a1"),
            ("scope_id", "run-old-claim"), ("scope_id", ""),
        ):
            with self.subTest(field=field, value=value):
                claim = json.loads(self.prior_attempt_raw)
                claim[field] = value
                raw = packed(claim)
                approval = copy.deepcopy(self.approval)
                approval["prior_attempt"] = reference(self.task / "desktop-attempt.json", raw)
                with self.assertRaises(ping0.StorageError):
                    self.validate(approval, prior_attempt_raw=raw)

    def args_for(self, run_name, additional=None):
        argv = ["capture-desktop", "--cdp", "synthetic-unused", "--run-dir", str(self.task / run_name),
                "--gate-receipt", str(self.task / "synthetic-gate.json"), "--ack-site-disclosure"]
        if additional is not None:
            argv += ["--additional-approval", additional]
        return ping0.parser().parse_args(argv)

    def test_parser_preserves_a1_default_and_accepts_explicit_a2_flag(self):
        self.assertIsNone(self.args_for("desktop-a1").additional_approval)
        path = str(self.task / "approval-a2" / "approval.json")
        self.assertEqual(self.args_for("desktop-a2", path).additional_approval, path)

    def test_invalid_capture_scope_fails_before_any_evidence_or_transport_access(self):
        path = str(self.task / "approval-a2" / "approval.json")
        for run_name, additional in (
            ("desktop-a3", path), ("other", path), ("desktop-a1", path),
            ("desktop-a2", None), ("desktop-a2", "approval-a2/approval.json"),
            ("desktop-a2", str(self.task / "approval-a1" / "approval.json")),
            ("desktop-a2", "/synthetic/other-task/approval-a2/approval.json"),
            ("desktop-a2", str(self.task) + "/approval-a2/../approval-a2/approval.json"),
        ):
            with self.subTest(run_name=run_name, additional=additional):
                with self.assertRaises(ping0.StorageError):
                    ping0.capture_desktop(self.args_for(run_name, additional), {}, b"{}")


if __name__ == "__main__":
    unittest.main()
