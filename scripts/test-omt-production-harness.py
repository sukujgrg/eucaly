#!/usr/bin/env python3
"""Offline checks for the native/network evidence gates; starts no outputs."""
import copy
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("omt_production", Path(__file__).with_name("test-omt-production-stress.py"))
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)


class ProductionReadinessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="eucaly-readiness-test-")
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.control = self.folder / "control"; self.control.mkdir()
        self.evidence = self.folder / "evidence"; self.evidence.mkdir()
        self.now = datetime(2026, 10, 25, tzinfo=timezone.utc).timestamp()
        self.run_id = "isolated-run"
        self.identity = "Sun Oct 25 05:00:00 2026 /tmp/eucaly.app/Contents/Helpers/eucalyNetworkHelper"
        self.value = {"runID": self.run_id, "state": "running", "invariantViolations": [], "unexpectedRouterFailureCount": 0,
            "observedAtUTC": datetime.fromtimestamp(self.now, timezone.utc).isoformat(), "elapsedSeconds": 10,
            "hardDeadlineUnix": self.now + 600, "destinations": [{"id": "primary", "active": True}],
            "helpers": [{"destinationID": "primary", "generation": "old", "pid": 123, "ready": True,
                         "technology": "omt", "failure": "", "exited": False, "sourceName": "Isolated source"}]}
        harness.atomic_json(self.control / "run.json", {"runID": self.run_id, "sourceName": "Isolated source", "evidenceDirectory": str(self.evidence)})
        harness.atomic_json(self.evidence / "launch.json", {"runID": self.run_id,
            "environment": {"EUCALY_OMT_PRODUCTION_SECONDS": "120"}})
        self.save()

    def save(self):
        harness.atomic_json(self.control / "status.json", self.value)

    def verify(self, listeners="p123\nf7\nn*:6400\n", identities=None, during_lsof=None, watcher=None):
        def lsof(*args, **kwargs):
            if during_lsof: during_lsof()
            return SimpleNamespace(returncode=0, stdout=listeners)
        with patch.object(harness.time, "time", return_value=self.now), \
             patch.object(harness, "process_identity", side_effect=identities or [self.identity, self.identity]), \
             patch.object(harness.subprocess, "run", side_effect=lsof):
            return harness.verified_readiness(self.control, self.run_id, "192.168.1.27", 75, watcher)

    def test_actual_exact_pid_listener_overrides_stale_cached_port(self):
        harness.atomic_json(self.control / "endpoints.json", {"endpoint": "omt://192.168.1.27:6401"})
        proof = self.verify()
        self.assertTrue(proof["ready"])
        self.assertEqual(proof["endpoint"], "omt://192.168.1.27:6400")
        self.assertEqual(proof["pid"], 123)

    def test_missing_ambiguous_and_other_process_listeners_cannot_report_ready(self):
        for listeners in ("p123\n", "p123\nn*:6400\nn*:6401\n", "p999\nn*:6400\n"):
            with self.subTest(listeners=listeners), self.assertRaises(ValueError): self.verify(listeners)

    def test_reused_pid_cannot_report_ready(self):
        with self.assertRaises(ValueError): self.verify(identities=[self.identity, "another process identity"])

    def test_exact_helper_exit_cannot_report_ready(self):
        with patch.object(harness.time, "time", return_value=self.now), \
             patch.object(harness.subprocess, "run", return_value=SimpleNamespace(returncode=1, stdout="")) as run:
            with self.assertRaises(ValueError):
                harness.verified_readiness(self.control, self.run_id, "192.168.1.27", 75)
            self.assertEqual(len(run.call_args_list), 1)
            self.assertEqual(run.call_args.args[0][0], "/bin/ps")

    def test_secondary_source_cannot_authorize_commands_for_primary(self):
        self.value["helpers"][0]["sourceName"] = "Secondary source"; self.save()
        with self.assertRaises(ValueError): self.verify()

    def test_replacement_during_listener_inspection_cannot_report_ready(self):
        def replace():
            self.value["helpers"][0]["generation"] = "replacement"; self.save()
        with self.assertRaises(ValueError): self.verify(during_lsof=replace)

    def test_stale_stopped_wrong_run_and_insufficient_capture_time_are_rejected(self):
        original = copy.deepcopy(self.value)
        changes = ({"state": "complete"}, {"runID": "another-run"}, {"elapsedSeconds": 60},
            {"hardDeadlineUnix": self.now + 60},
            {"observedAtUTC": datetime.fromtimestamp(self.now - 6, timezone.utc).isoformat()})
        for change in changes:
            self.value = dict(copy.deepcopy(original), **change); self.save()
            with self.subTest(change=change), self.assertRaises(ValueError): self.verify()

    def test_dead_or_replaced_watcher_cannot_report_ready(self):
        watcher = self.folder / "watcher.json"
        source = self.verify()
        harness.atomic_json(watcher, {"state": "waitingForPlayback", "source": source,
                                     "pid": 999, "processIdentity": "expected watcher",
                                     "waitUntilHost100ns": harness.time.monotonic_ns() // 100 + 450_000_000})
        with self.assertRaises(ValueError):
            self.verify(identities=[self.identity, self.identity, "reused watcher PID"], watcher=watcher)
        good = self.verify(identities=[self.identity, self.identity, "expected watcher"], watcher=watcher)
        self.assertEqual(good["watcher"]["pid"], 999)
        value = harness.read_json(watcher); value["waitUntilHost100ns"] = 0; harness.atomic_json(watcher, value)
        with self.assertRaises(ValueError): self.verify(watcher=watcher)
        value = harness.read_json(watcher); value["state"] = "failed"; harness.atomic_json(watcher, value)
        with self.assertRaises(ValueError): self.verify(watcher=watcher)

    def test_small_regular_marker_must_match_run_and_watcher(self):
        marker = self.folder / "marker.json"
        harness.atomic_json(marker, {"runID": self.run_id, "watcherToken": "fresh-token"})
        harness.playback_marker(marker, self.run_id, "fresh-token")
        with self.assertRaises(ValueError): harness.playback_marker(marker, "another-run", "fresh-token")
        with self.assertRaises(ValueError): harness.playback_marker(marker, self.run_id, "stale-token")
        link = self.folder / "symlink"; link.symlink_to(marker)
        with self.assertRaises(OSError): harness.playback_marker(link, self.run_id, "fresh-token")

    def test_commands_reject_changed_run_before_writing_any_command(self):
        with self.assertRaises(ValueError): harness.submit(self.control, {"action": "stop"}, expected_run_id="another-run")
        self.assertFalse((self.control / "commands").exists())

    def watch(self, *, missing_shutdown=False, wrong_marker=False, replacement_while_waiting=False, replacement_after_ack=False, timeout=False):
        proof = self.verify()
        self.args = SimpleNamespace(control_dir=self.control, run_id=self.run_id, lan_host="192.168.1.27",
            minimum_remaining=75, marker=self.folder/"playback.json", ready_file=self.folder/"watcher.json",
            result_file=self.folder/"result.json", marker_timeout=1, outage_seconds=2)
        actions, sleeps = [], []
        def sleep(seconds):
            sleeps.append(seconds)
            if seconds == 0.02:
                waiting = harness.read_json(self.args.ready_file)
                harness.atomic_json(self.args.marker, {"runID": self.run_id,
                    "watcherToken": "wrong" if wrong_marker else waiting["watcherToken"]})
            else:
                self.assertEqual(actions, ["stop"], "The sleep must follow confirmed exact-child retirement")
        def submit(control, payload, wait=0, expected_run_id=None):
            self.assertEqual(expected_run_id, self.run_id)
            self.assertEqual(payload["expectedDestinationID"], proof["destinationID"])
            self.assertEqual(payload["expectedGeneration"], proof["generation"])
            actions.append(payload["action"])
            events = [{"generation": "old", "event": "exited", "host100ns": 200}]
            if not missing_shutdown: events.insert(0, {"generation": "old", "event": "shutdown-complete", "host100ns": 190})
            (self.evidence/"helper-events.jsonl").write_text("".join(json.dumps(e)+"\n" for e in events))
            return {"runID": self.run_id, "result": "completed", "resultGeneration": "new"}
        changed = dict(proof, generation="new", pid=124)
        proofs = [proof, changed if replacement_while_waiting else proof,
                  dict(changed, generation="unrelated") if replacement_after_ack else changed]
        with patch.object(harness, "verified_readiness", side_effect=proofs), \
             patch.object(harness, "process_identity", return_value="watcher identity"), \
             patch.object(harness, "submit", side_effect=submit), \
             patch("builtins.print"), \
             patch.object(harness.time, "sleep", side_effect=sleep), \
             patch.object(harness.time, "monotonic", side_effect=[0, 2] if timeout else None, return_value=0):
            try: harness.watch_outage(self.args)
            finally: self.actions, self.sleeps = actions, sleeps

    def test_marker_controls_stop_exact_exit_sleep_then_start(self):
        self.watch()
        self.assertEqual(self.actions, ["stop", "start"])
        self.assertEqual(self.sleeps, [0.02, 2])
        self.assertEqual(harness.read_json(self.args.ready_file)["state"], "complete")
        self.assertEqual(harness.read_json(self.args.result_file)["requestedSleepSeconds"], 2)

    def test_missing_shutdown_never_adds_grace_sleep_or_restarts(self):
        with self.assertRaises(ValueError): self.watch(missing_shutdown=True)
        self.assertEqual(self.actions, ["stop"])
        self.assertEqual(self.sleeps, [0.02])
        self.assertEqual(harness.read_json(self.args.ready_file)["state"], "failed")

    def test_replacement_after_start_ack_cannot_report_unrelated_generation_as_complete(self):
        with self.assertRaises(ValueError): self.watch(replacement_after_ack=True)
        self.assertEqual(self.actions, ["stop", "start"])
        self.assertFalse(self.args.result_file.exists())
        self.assertEqual(harness.read_json(self.args.ready_file)["state"], "failed")

    def test_wrong_marker_changed_source_and_timeout_never_stop_sender(self):
        for options in ({"wrong_marker": True}, {"replacement_while_waiting": True}, {"timeout": True}):
            with self.subTest(options=options):
                for name in ("playback.json", "watcher.json", "result.json"):
                    (self.folder/name).unlink(missing_ok=True)
                with self.assertRaises(ValueError): self.watch(**options)
                self.assertFalse(self.actions)
                self.assertEqual(harness.read_json(self.args.ready_file)["state"], "failed")


class ProductionEvidenceTests(unittest.TestCase):
    def test_explicit_run_deadline_is_future_and_within_thirty_minutes(self):
        now = datetime(2026, 10, 25, tzinfo=timezone.utc).timestamp()
        for offset in (46, 1800):
            value = datetime.fromtimestamp(now + offset, timezone.utc).isoformat()
            self.assertEqual(harness.run_deadline(value, now), now + offset)
        for offset in (-1, 45, 1801):
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                harness.run_deadline(datetime.fromtimestamp(now + offset, timezone.utc).isoformat(), now)

    def test_run_deadline_requires_timezone_and_rejects_stale_or_invalid_values(self):
        now = datetime(2026, 10, 25, tzinfo=timezone.utc).timestamp()
        for value in ("2026-10-25T00:02:00", "2026-10-24T21:41:36+11:00", "invalid"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                harness.run_deadline(value, now)

    def evaluate(self, value, complete=False):
        with tempfile.TemporaryDirectory(prefix="eucaly-evidence-test-") as directory:
            path = Path(directory)
            (path / "checkpoints.jsonl").write_text(json.dumps(value) + "\n")
            return harness.summarize(path, require_complete=complete)

    def checkpoint(self):
        return {"phase": "three-output", "state": "running", "host100ns": 100,
                "routerFailures": [], "destinations": [], "invariantViolations": []}

    def native(self):
        return {"id": "native", "name": "Native", "technology": "native", "active": True,
                "expectedOpen": True, "localPlayerVolume": 1, "expectedLocalPlayerVolume": 1,
                "playerIdentity": "shared-player", "playerItemIdentity": "shared-item", "playerTime": 100,
                "native": {"requestedPhysicalDisplayUUID": "selected-display", "programVideoReady": True,
                    "driver": {"windowNumber": 7, "windowVisible": True, "physicalDisplayUUID": "selected-display",
                               "nativePlayerIdentity": "shared-player", "nativePlayerItemIdentity": "shared-item"}}}

    def test_legacy_network_only_volume_gate_stays_strict(self):
        value = self.checkpoint()
        value["destinations"] = [{"id": "omt", "name": "OMT", "technology": "omt", "localPlayerVolume": 1}]
        self.assertTrue(self.evaluate(value)["invariantViolations"])
        value["destinations"][0]["localPlayerVolume"] = 0
        self.assertFalse(self.evaluate(value)["invariantViolations"])

    def test_normal_native_audio_does_not_become_a_network_only_failure(self):
        value = self.checkpoint()
        value["destinations"] = [self.native(), {"id": "omt", "name": "OMT", "technology": "omt",
            "localPlayerVolume": 1, "expectedLocalPlayerVolume": 1, "active": True}]
        result = self.evaluate(value)
        self.assertFalse(result["invariantViolations"])
        self.assertNotIn("native", result["phases"]["three-output"]["sources"])
        self.assertFalse(result["phases"]["three-output"]["nativeOutputs"]["native"]["presentedFrameCadenceMeasured"])

    def test_native_window_loss_and_wrong_physical_display_fail(self):
        for field, changed in (("windowVisible", False), ("physicalDisplayUUID", "another-display")):
            with self.subTest(field=field):
                value = self.checkpoint()
                native = self.native()
                native["native"]["driver"][field] = changed
                value["destinations"] = [native]
                self.assertTrue(self.evaluate(value)["invariantViolations"])

    def test_unready_or_independent_native_player_fails(self):
        original = self.native()
        for change in ("ready", "player", "item"):
            with self.subTest(change=change):
                native = copy.deepcopy(original)
                if change == "ready":
                    native["native"]["programVideoReady"] = False
                else:
                    key = "nativePlayerIdentity" if change == "player" else "nativePlayerItemIdentity"
                    native["native"]["driver"][key] = "another-resource"
                value = self.checkpoint()
                value["destinations"] = [native]
                self.assertTrue(self.evaluate(value)["invariantViolations"])

    def test_native_cleanup_is_required_in_addition_to_helper_exit(self):
        value = self.checkpoint()
        value.update(state="complete", allOwnedHelpersExited=True, activeOutputs=0, nativeOutputConfigured=True,
                     allOwnedNativeWindowsClosed=True, coordinatorHasActiveOutputs=False)
        self.assertFalse(self.evaluate(value, complete=True)["invariantViolations"])
        for field, bad in (("allOwnedNativeWindowsClosed", False), ("coordinatorHasActiveOutputs", True)):
            changed = dict(value, **{field: bad})
            self.assertTrue(self.evaluate(changed, complete=True)["invariantViolations"])

    def test_new_expected_audio_route_does_not_disable_volume_validation(self):
        for expected in (0, 1, 7):
            value = self.checkpoint()
            native = self.native()
            native["expectedLocalPlayerVolume"] = expected
            native["localPlayerVolume"] = 0 if expected == 1 else 1
            value["destinations"] = [native]
            self.assertTrue(self.evaluate(value)["invariantViolations"])

    def test_native_nonvideo_and_hidden_video_do_not_require_a_rendered_program_frame(self):
        for player in ("", "shared-player"):
            value = self.checkpoint()
            native = self.native()
            native.update(playerIdentity=player, expectedProgramVideoVisible=False)
            native["localPlayerVolume"] = 1 if player else 0
            native["native"]["programVideoReady"] = False
            value["destinations"] = [native]
            self.assertFalse(self.evaluate(value)["invariantViolations"])

    def test_visible_native_video_with_missing_player_fails(self):
        value = self.checkpoint()
        native = self.native()
        native.update(playerIdentity="", expectedProgramVideoVisible=True, localPlayerVolume=0)
        native["native"]["programVideoReady"] = False
        value["destinations"] = [native]
        self.assertTrue(self.evaluate(value)["invariantViolations"])


if __name__ == "__main__":
    unittest.main()
