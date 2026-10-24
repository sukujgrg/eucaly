#!/usr/bin/env python3
"""Offline checks for the native/network evidence gates; starts no outputs."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("omt_production", Path(__file__).with_name("test-omt-production-stress.py"))
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)


class ProductionEvidenceTests(unittest.TestCase):
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
