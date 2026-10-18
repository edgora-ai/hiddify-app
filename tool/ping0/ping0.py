#!/usr/bin/env python3
"""Offline replay, or one explicitly acknowledged browser assessment capture."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import re
import secrets
import stat
import sys

import records

MAX_RUN_BYTES = 16 * 1024 * 1024
MAX_TASK_BYTES = 40 * 1024 * 1024
RESERVE_BYTES = 10 * 1024 * 1024 * 1024
ORIGINAL_REMAINING_BYTES = 48 * 1024 * 1024 * 1024
CONTRACT_PATH = Path(__file__).with_name("contract.json")


class StorageError(ValueError):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


@contextmanager
def directory(path):
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise StorageError("absolute_no_follow_directory_required")
    owned = []
    try:
        fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        owned.append(fd)
        for part in path.parts[1:]:
            fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            owned.append(fd)
        yield fd
    finally:
        for fd in reversed(owned):
            os.close(fd)


def read_at(parent, name, limit):
    if "/" in name or name in {".", ".."}:
        raise StorageError("single_file_name_required")
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or not 0 < before.st_size <= limit:
            raise StorageError("bounded_regular_file_required")
        data = os.pread(fd, before.st_size + 1, 0)
        after = os.fstat(fd)
        if len(data) != before.st_size or (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise StorageError("input_changed_during_read")
        return data
    finally:
        os.close(fd)


def read_file(path, limit=2 * 1024 * 1024):
    path = Path(os.path.abspath(path))
    with directory(path.parent) as parent:
        return read_at(parent, path.name, limit)


def tree_bytes(parent, *, depth=0):
    if depth > 4:
        raise StorageError("task_directory_depth_limit")
    total = 0
    names = os.listdir(parent)
    if len(names) > 128:
        raise StorageError("task_entry_limit")
    for name in names:
        info = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if stat.S_ISDIR(info.st_mode):
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            try:
                total += tree_bytes(child, depth=depth + 1)
            finally:
                os.close(child)
        elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
            total += info.st_size
        else:
            raise StorageError("unexpected_task_entry")
        if total > MAX_TASK_BYTES:
            raise StorageError("task_byte_limit")
    return total


class EvidenceStore:
    def __init__(self, path, fd, task_fd):
        self.path = Path(path)
        self.fd = fd
        self.task_fd = task_fd
        self.references = []

    def save(self, name, value):
        raw = records.canonical(value) if not isinstance(value, bytes) else value
        directory_limit = MAX_TASK_BYTES if self.fd == self.task_fd else MAX_RUN_BYTES
        if len(raw) > MAX_RUN_BYTES or tree_bytes(self.fd) + len(raw) > directory_limit:
            raise StorageError("run_byte_limit")
        if tree_bytes(self.task_fd) + len(raw) > MAX_TASK_BYTES:
            raise StorageError("task_byte_limit")
        if not re.fullmatch(r"[a-z0-9][a-z0-9_.-]{0,100}", name):
            raise StorageError("invalid_evidence_name")
        fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self.fd)
        try:
            before = os.fstat(fd)
            if before.st_nlink != 1 or stat.S_IMODE(before.st_mode) != 0o600:
                raise StorageError("private_evidence_required")
            view = memoryview(raw)
            while view:
                written = os.write(fd, view)
                if written <= 0:
                    raise StorageError("evidence_write_incomplete")
                view = view[written:]
            os.fsync(fd)
            if os.pread(fd, len(raw) + 1, 0) != raw:
                raise StorageError("held_readback_failed")
            if read_at(self.fd, name, MAX_RUN_BYTES) != raw:
                raise StorageError("independent_readback_failed")
            after = os.stat(name, dir_fd=self.fd, follow_symlinks=False)
            if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
                raise StorageError("evidence_identity_changed")
            os.fsync(self.fd)
        finally:
            os.close(fd)
        reference = {"path": str(self.path / name), "bytes": len(raw), "sha256": sha256(raw)}
        self.references.append(reference)
        return reference


def capture_storage_policy(environ=None):
    """Require the operator's local mount identity without publishing it in source."""
    source = os.environ if environ is None else environ
    policy = {}
    for key, variable in (
        ("volume_uuid", "PING0_VOLUME_UUID"),
        ("host_uuid", "PING0_HOST_UUID"),
    ):
        value = source.get(variable)
        if not isinstance(value, str) or not re.fullmatch(
            r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", value
        ):
            raise StorageError("explicit_storage_identity_required")
        policy[key] = value.upper()
    for key, variable in (
        ("volume_path", "PING0_VOLUME_PATH"),
        ("host_path", "PING0_HOST_PATH"),
    ):
        value = source.get(variable)
        if (not isinstance(value, str) or not value.startswith("/Volumes/")
                or os.path.normpath(value) != value or ".." in Path(value).parts
                or "\x00" in value):
            raise StorageError("explicit_storage_mount_required")
        policy[key] = value
    if policy["volume_uuid"] == policy["host_uuid"] or policy["volume_path"] == policy["host_path"]:
        raise StorageError("distinct_storage_identities_required")
    return policy


def validate_task(task_path, task_fd, gate_path):
    policy = capture_storage_policy()
    marker_raw = read_at(task_fd, "task.json", 65536)
    marker = records.decode(marker_raw)
    if not isinstance(marker, dict) or marker.get("directory") != str(task_path):
        raise StorageError("registered_task_required")
    if marker.get("volume_uuid") != policy["volume_uuid"] or marker.get("host_uuid") != policy["host_uuid"]:
        raise StorageError("task_volume_identity_mismatch")
    if marker.get("maximum_run_bytes") != MAX_RUN_BYTES or marker.get("maximum_task_bytes") != MAX_TASK_BYTES:
        raise StorageError("approved_byte_limits_required")
    if marker.get("maximum_live_rounds") != {"desktop": 1, "ipad": 1}:
        raise StorageError("approved_round_limits_required")
    expected_parent = Path(policy["volume_path"]) / "Temp" / "hiddify-app"
    if task_path.parent.parent != expected_parent or not re.fullmatch(r"ping0-evaluation-[0-9a-f]{12}", task_path.name):
        raise StorageError("approved_evidence_root_required")
    approval = marker.get("approved_plan", {})
    plan = read_file(approval.get("path", ""), 65536)
    if sha256(plan) != approval.get("sha256") or len(plan) != approval.get("bytes"):
        raise StorageError("approved_plan_changed")
    gate_path = Path(os.path.abspath(gate_path))
    if gate_path.parent != task_path:
        raise StorageError("gate_must_belong_to_this_task")
    receipt = records.decode(read_at(task_fd, gate_path.name, 65536))
    if not isinstance(receipt, dict) or not isinstance(receipt.get("result"), dict):
        raise StorageError("timestamped_gate_receipt_required")
    try:
        checked_at = datetime.fromisoformat(receipt["checked_at"])
        age = (datetime.now(timezone.utc) - checked_at).total_seconds()
    except (ValueError, TypeError, KeyError):
        raise StorageError("invalid_gate_time") from None
    if not 0 <= age <= 60:
        raise StorageError("fresh_storage_gate_required")
    gate = receipt["result"]
    initial_ref = marker.get("initial_storage_gate", {})
    initial_raw = read_at(task_fd, Path(initial_ref.get("path", "")).name, 65536)
    if sha256(initial_raw) != initial_ref.get("sha256"):
        raise StorageError("initial_gate_changed")
    initial = records.decode(initial_raw)
    observed = gate.get("observed", {})
    volume, host = observed.get("volume", {}), observed.get("host", {})
    if (volume.get("uuid") != policy["volume_uuid"] or host.get("uuid") != policy["host_uuid"]
            or volume.get("mountpoint") != policy["volume_path"] or host.get("mountpoint") != policy["host_path"]):
        raise StorageError("fresh_volume_identity_mismatch")
    if observed.get("image", {}).get("path") != marker.get("image"):
        raise StorageError("image_identity_changed")
    if gate.get("registry_sha256") != initial.get("registry_sha256") or gate.get("bootstrap_sha256") != initial.get("bootstrap_sha256"):
        raise StorageError("storage_control_changed")
    if gate.get("remaining_bytes", 0) < ORIGINAL_REMAINING_BYTES + MAX_TASK_BYTES:
        raise StorageError("original_allowance_must_be_preserved")
    if os.fstat(task_fd).st_dev != volume.get("st_dev") or volume.get("st_dev") != marker.get("volume_st_dev"):
        raise StorageError("task_not_on_verified_volume")
    for mount, expected_device in ((policy["volume_path"], volume.get("st_dev")), (policy["host_path"], host.get("st_dev"))):
        with directory(mount) as fd:
            if os.fstat(fd).st_dev != expected_device:
                raise StorageError("mount_device_changed")
            available = os.fstatvfs(fd)
            if available.f_bavail * available.f_frsize < ORIGINAL_REMAINING_BYTES + MAX_TASK_BYTES + RESERVE_BYTES:
                raise StorageError("space_reserve_not_available")
    if tree_bytes(task_fd) >= MAX_TASK_BYTES:
        raise StorageError("task_byte_limit")
    return marker, {"path": str(gate_path), "bytes": len(records.canonical(receipt)), "sha256": sha256(read_at(task_fd, gate_path.name, 65536))}


def validate_additional_approval(approval, task_path, marker, authorization_raw, prior_attempt_raw, prior_manifest_raw):
    """Validate local evidence of separate user approval; this does not grant it."""
    task_path = Path(task_path)
    if (not task_path.is_absolute() or ".." in task_path.parts or not isinstance(marker, dict)
            or marker.get("directory") != str(task_path)
            or marker.get("maximum_live_rounds") != {"desktop": 1, "ipad": 1}
            or any(type(marker["maximum_live_rounds"][kind]) is not int for kind in ("desktop", "ipad"))
            or any(type(marker.get(key)) is not int for key in ("maximum_run_bytes", "maximum_task_bytes"))
            or marker.get("maximum_run_bytes") != MAX_RUN_BYTES
            or marker.get("maximum_task_bytes") != MAX_TASK_BYTES):
        raise StorageError("original_task_limits_required")
    control = marker.get("control_directory")
    if not isinstance(control, str) or not Path(control).is_absolute() or ".." in Path(control).parts:
        raise StorageError("absolute_authorization_control_directory_required")
    expected = {
        "schema_version": 1,
        "action": "additional-desktop-round",
        "task_directory": str(task_path),
        "run_name": "desktop-a2",
        "additional_rounds": 1,
        "maximum_navigations": 1,
        "deadline_seconds": 90,
        "cleanup_only_seconds": 5,
        "maximum_run_bytes": MAX_RUN_BYTES,
        "maximum_task_bytes": MAX_TASK_BYTES,
        "original_remaining_bytes_preserved": ORIGINAL_REMAINING_BYTES,
        "automatic_retry": False,
    }
    if not isinstance(approval, dict) or approval.get("automatic_retry") is not False or any(
            type(approval.get(key)) is not type(value) or approval.get(key) != value
            for key, value in expected.items()):
        raise StorageError("additional_desktop_a2_approval_required")
    authorization = approval.get("user_authorization")
    if (not isinstance(authorization, dict) or authorization.get("kind") != "user-message"
            or not isinstance(authorization.get("text"), str) or not authorization["text"].strip()
            or authorization.get("sha256") != sha256(authorization["text"].encode("utf-8"))):
        raise StorageError("additional_user_message_evidence_required")
    references = {}
    for key, path, raw in (
        ("authorization_record", Path(control) / "additional-desktop-a2-authorization.md", authorization_raw),
        ("prior_attempt", task_path / "desktop-attempt.json", prior_attempt_raw),
        ("prior_manifest", task_path / "desktop-a1" / "manifest.json", prior_manifest_raw),
    ):
        reference = approval.get(key)
        if (not isinstance(raw, bytes) or not raw or not isinstance(reference, dict)
                or reference.get("path") != str(path) or type(reference.get("bytes")) is not int
                or reference["bytes"] != len(raw) or reference.get("sha256") != sha256(raw)):
            raise StorageError("additional_approval_reference_mismatch")
        references[key] = {"path": str(path), "bytes": len(raw), "sha256": sha256(raw)}
    prior_attempt = records.decode(prior_attempt_raw)
    prior_manifest = records.decode(prior_manifest_raw)
    if (not isinstance(prior_attempt, dict) or not isinstance(prior_manifest, dict)
            or prior_attempt.get("run_directory") != str(task_path / "desktop-a1")
            or not isinstance(prior_attempt.get("scope_id"), str) or not prior_attempt["scope_id"]
            or prior_manifest.get("scope_id") != prior_attempt["scope_id"]):
        raise StorageError("matching_prior_desktop_a1_evidence_required")
    return {
        **expected,
        "user_authorization": {"kind": "user-message", "sha256": authorization["sha256"]},
        **references,
    }


def _append_index(marker, run_path, summary):
    # Use the existing physical control index, never a test symlink or a new registry.
    storage = Path.home() / ".claude" / "storage"
    control = Path(marker["control_directory"])
    if storage not in control.parents:
        raise StorageError("control_index_scope_mismatch")
    event_id = "ping0-evaluation-" + run_path.parent.name.removeprefix("ping0-evaluation-") + "-" + run_path.name + "-result"
    entry = {
        "schema_version": 1,
        "event_id": event_id,
        "project": "hiddify-app",
        "directory": str(run_path.parent),
        "run_directory": str(run_path),
        "readme": str(run_path.parent / "README.md"),
        "status": summary["status"],
        "manifest": summary["manifest"],
        "no_VPN_acceptance_claim": True,
    }
    lines = {
        "tasks.jsonl": records.canonical(entry),
        "INDEX.md": ("\n- Event `" + event_id + "`; manifest `" + summary["manifest"]["path"] + "` SHA `" + summary["manifest"]["sha256"] + "`; diagnosis `" + summary["status"] + "`; private bounded capture, no VPN acceptance claim.\n").encode(),
    }
    import fcntl

    with directory(storage) as parent:
        for name, line in lines.items():
            fd = os.open(name, os.O_RDWR | os.O_APPEND | os.O_NOFOLLOW, dir_fd=parent)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX)
                before = os.fstat(fd)
                limit = 16 * 1024 * 1024
                if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_uid != os.geteuid() or before.st_size > limit:
                    raise StorageError("regular_control_index_required")
                previous = os.pread(fd, before.st_size, 0)
                if event_id.encode() in previous:
                    raise StorageError("duplicate_index_event")
                written = os.write(fd, line)
                if written != len(line):
                    raise StorageError("index_append_incomplete")
                os.fsync(fd)
                held = os.pread(fd, os.fstat(fd).st_size, 0)
                independent = read_at(parent, name, limit)
                if not held.startswith(previous) or line not in held or line not in independent:
                    raise StorageError("index_readback_failed")
                os.fsync(parent)
            finally:
                fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)


def capture_desktop(args, contract, contract_raw):
    if not args.ack_site_disclosure:
        raise StorageError("site_disclosure_ack_required")
    run_path = Path(os.path.abspath(args.run_dir))
    if run_path.name not in {"desktop-a1", "desktop-a2"}:
        raise StorageError("approved_desktop_a1_or_a2_directory_required")
    task_path = run_path.parent
    additional_path = getattr(args, "additional_approval", None)
    approval_path = task_path / "approval-a2" / "approval.json"
    if run_path.name == "desktop-a1" and additional_path is not None:
        raise StorageError("additional_approval_only_for_desktop_a2")
    if run_path.name == "desktop-a2" and additional_path != str(approval_path):
        raise StorageError("explicit_task_desktop_a2_approval_path_required")
    with directory(task_path) as task_fd:
        marker, gate_ref = validate_task(task_path, task_fd, args.gate_receipt)
        additional_fields = {}
        if run_path.name == "desktop-a2":
            approval_raw = read_file(approval_path, 65536)
            validated = validate_additional_approval(
                records.decode(approval_raw), task_path, marker,
                read_file(Path(marker["control_directory"]) / "additional-desktop-a2-authorization.md", 65536),
                read_file(task_path / "desktop-attempt.json", 65536),
                read_file(task_path / "desktop-a1" / "manifest.json"),
            )
            additional_fields["additional_approval"] = {
                "path": str(approval_path), "bytes": len(approval_raw), "sha256": sha256(approval_raw),
                **validated,
            }
        # Claim before opening a browser transport; ambiguity never causes an automatic retry.
        task_store = EvidenceStore(task_path, task_fd, task_fd)
        scope_id = "run-" + secrets.token_hex(8)
        source_refs = []
        for name in ("ping0.py", "records.py", "desktop_cdp.py", "contract.json"):
            raw = read_file(Path(__file__).parent / name, 256 * 1024)
            source_refs.append({"name": name, "bytes": len(raw), "sha256": sha256(raw)})
        claim_name = "desktop-a2-attempt.json" if run_path.name == "desktop-a2" else "desktop-attempt.json"
        task_store.save(claim_name, {
            "scope_id": scope_id,
            "run_directory": str(run_path),
            "created_at": datetime.now(timezone.utc).isoformat(),
            "sources": source_refs,
            "fresh_gate": gate_ref,
            "automatic_retry": False,
            "maximum_navigations": 1,
            **additional_fields,
        })
        os.mkdir(run_path.name, 0o700, dir_fd=task_fd)
        os.fsync(task_fd)
        with directory(run_path) as run_fd:
            store = EvidenceStore(run_path, run_fd, task_fd)
            store.save("invocation.json", {
                "schema_version": 1,
                "scope_id": scope_id,
                "subject": "desktop-cdp",
                "contract_sha256": sha256(contract_raw),
                "fresh_gate": gate_ref,
                "deadline_seconds": 90,
                "cleanup_only_seconds": 5,
                "sources": source_refs,
                "site_disclosure_acknowledged": True,
                "sensitive_endpoint_path_not_retained": True,
                **additional_fields,
            })
            count = 0

            def checkpoint(kind, details):
                nonlocal count
                count += 1
                store.save(str(count).zfill(2) + "-" + kind.replace("_", "-") + ".json", {
                    "scope_id": scope_id, "phase": kind, "details": details,
                    "at": datetime.now(timezone.utc).isoformat(),
                })

            from desktop_cdp import collect

            capture = collect(args.cdp, contract, scope_id, checkpoint=checkpoint)
            capture_ref = store.save("capture.json", capture)
            report = records.diagnose(capture, contract)
            report_ref = store.save("report.json", report)
            markdown_ref = store.save("report.md", records.render_markdown(report).encode())
            manifest_ref = store.save("manifest.json", {
                "schema_version": 1,
                "scope_id": scope_id,
                "status": report.get("status", "unknown"),
                "artifacts": list(store.references),
                "source_contract_sha256": sha256(contract_raw),
                "capture": capture_ref,
                "report": report_ref,
                "markdown": markdown_ref,
                "store_readback": "held_and_independent_bytes_verified",
                "no_VPN_acceptance_claim": True,
            })
            summary = {"status": report.get("status", "unknown"), "manifest": manifest_ref, "capture": capture_ref, "report": report_ref}
            _append_index(marker, run_path, summary)
            summary["index_readback_and_search"] = True
            print(records.canonical(summary).decode(), end="")
            # A successfully retained diagnosis is not a successful VPN test.
            return 0 if capture["observation"]["end_reason"] == "site_result_captured" and all(capture["observation"]["cleanup"].values()) else 2


def parser():
    result = argparse.ArgumentParser(description="Replay a saved ping0 observation or capture one acknowledged site run")
    commands = result.add_subparsers(dest="command", required=True)
    replay = commands.add_parser("replay", help="Analyze saved evidence without accessing a browser or device")
    replay.add_argument("capture")
    replay.add_argument("--format", choices=("json", "markdown"), default="json")
    online = commands.add_parser("capture-desktop", help="One site run sends IP and fingerprint data to the site and its third parties")
    online.add_argument("--cdp", required=True)
    online.add_argument("--run-dir", required=True)
    online.add_argument("--gate-receipt", required=True)
    online.add_argument("--additional-approval", help="Required only for desktop-a2: TASK/approval-a2/approval.json")
    online.add_argument("--ack-site-disclosure", action="store_true")
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        contract_raw = read_file(CONTRACT_PATH, 256 * 1024)
        contract = records.decode(contract_raw)
        if args.command == "replay":
            capture = records.decode(read_file(args.capture))
            report = records.diagnose(capture, contract)
            print(records.render_markdown(report) if args.format == "markdown" else records.canonical(report).decode(), end="")
            return 0
        return capture_desktop(args, contract, contract_raw)
    except (Exception, KeyboardInterrupt) as error:
        # Do not echo arbitrary provider errors, paths from page text, or raw payloads.
        code = getattr(error, "code", type(error).__name__)
        if not isinstance(code, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,120}", code):
            code = "operation_failed"
        print(records.canonical({"status": "blocked_or_failed_retained", "error_kind": code, "automatic_retry": False}).decode(), end="", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
