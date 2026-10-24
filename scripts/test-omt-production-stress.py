#!/usr/bin/env python3
"""Coordinate an opt-in genuine eucaly OMT sender and retain sender-side evidence.

The source initially holds one movie. All disruptive phases require explicit
file commands. Apple TV control and receiver measurements belong to its agent.
"""
import argparse
import csv
from datetime import datetime, timezone
import ipaddress
import json
import math
import os
from pathlib import Path
import signal
import stat
import subprocess
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
CONTROL = Path("/tmp/eucaly-omt-production-stress-20261024")
ACTIONS = ("stablehold", "hold", "marker", "status", "lyrics", "slides", "video", "generated", "image", "pdf",
           "preview", "loadpreview", "select", "next", "hide", "show", "clear", "pause", "play", "seek", "transfer",
           "start", "retry", "restart", "stop", "enable", "disable", "fault", "music", "musicstop", "position", "finish")


def read_json(path):
    return json.loads(path.read_text())


def atomic_json(path, value):
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    temporary.write_text(json.dumps(value, sort_keys=True) + "\n")
    temporary.replace(path)


def process_identity(pid):
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart=,comm="],
                            capture_output=True, text=True, timeout=5, check=False)
    if result.returncode != 0 or not result.stdout.strip():
        raise ValueError(f"Exact process {pid} is no longer alive")
    return result.stdout.strip()


def source_snapshot(control, expected_run_id, minimum_remaining, now):
    manifest = read_json(control / "run.json")
    value = read_json(control / "status.json")
    launch = read_json(Path(manifest["evidenceDirectory"]) / "launch.json")
    if any(item.get("runID") != expected_run_id for item in (manifest, value, launch)):
        raise ValueError("Source run identity changed; readiness is stale")
    if value.get("state") != "running" or value.get("invariantViolations") or value.get("unexpectedRouterFailureCount"):
        raise ValueError("The isolated source is not running without errors")
    observed = datetime.fromisoformat(value["observedAtUTC"].replace("Z", "+00:00")).timestamp()
    elapsed = float(value["elapsedSeconds"])
    duration = float(launch["environment"]["EUCALY_OMT_PRODUCTION_SECONDS"])
    remaining = min(duration - elapsed, float(value["hardDeadlineUnix"]) - now - 30) - max(0, now - observed)
    if not all(math.isfinite(x) for x in (now, elapsed, duration, remaining)) or elapsed < 0 or not 30 <= duration <= 1800 or not -1 <= now - observed <= 5 or remaining < minimum_remaining:
        raise ValueError("Source status is stale or lacks the remaining capture budget")
    rows = {row["id"]: row for row in value.get("destinations", [])}
    helpers = [helper for helper in value.get("helpers", []) if helper.get("technology") == "omt"
               and helper.get("sourceName") == manifest["sourceName"]
               and not helper.get("exited") and helper.get("ready") and not helper.get("failure")
               and rows.get(helper.get("destinationID"), {}).get("active")]
    if len(helpers) != 1 or int(helpers[0].get("pid", 0)) <= 0:
        raise ValueError("Readiness requires the one live primary OMT source")
    helper = helpers[0]
    return {"runID": expected_run_id, "destinationID": helper["destinationID"],
            "generation": helper["generation"], "pid": int(helper["pid"]),
            "sourceName": helper["sourceName"], "remainingSeconds": remaining,
            "evidenceDirectory": manifest["evidenceDirectory"]}


def listener_port(output, pid):
    current, ports = None, set()
    for line in output.splitlines():
        if line.startswith("p"):
            current = int(line[1:])
        elif line.startswith("n"):
            if current != pid:
                raise ValueError("Listener evidence belongs to another process")
            port = int(line.rsplit(":", 1)[-1])
            if not 1 <= port <= 65535:
                raise ValueError("Invalid listener port")
            ports.add(port)
    if ports and len(ports) == 1:
        return ports.pop()
    raise ValueError("The exact helper must have one unambiguous TCP listener")


def verified_readiness(control, run_id, lan_host, minimum_remaining, watcher_ready=None):
    ipaddress.IPv4Address(lan_host)
    if not math.isfinite(minimum_remaining) or not 1 <= minimum_remaining <= 1800:
        raise ValueError("A finite remaining capture budget is required")
    first = source_snapshot(control, run_id, minimum_remaining, time.time())
    identity = process_identity(first["pid"])
    if Path(identity.rsplit(None, 1)[-1]).name != "eucalyNetworkHelper":
        raise ValueError("The exact PID is not the bundled network helper")
    result = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(first["pid"]),
                             "-iTCP", "-sTCP:LISTEN", "-Fpn"],
                            capture_output=True, text=True, timeout=5, check=False)
    if result.returncode != 0:
        raise ValueError("Could not verify the exact helper's current TCP listener")
    port = listener_port(result.stdout, first["pid"])
    second = source_snapshot(control, run_id, minimum_remaining, time.time())
    if any(first[key] != second[key] for key in ("runID", "generation", "pid", "destinationID")) or process_identity(first["pid"]) != identity:
        raise ValueError("Source changed during endpoint verification")
    proof = dict(second, ready=True, endpoint=f"omt://{lan_host}:{port}", port=port,
                 processIdentity=identity, verifiedUnixSeconds=time.time(), host100ns=time.monotonic_ns() // 100)
    if watcher_ready:
        watcher = read_json(watcher_ready)
        if watcher.get("state") != "waitingForPlayback" or any(watcher["source"].get(key) != proof[key]
                for key in ("runID", "generation", "pid", "endpoint")):
            raise ValueError("The outage watcher is not waiting for this exact source")
        if watcher.get("waitUntilHost100ns", 0) <= time.monotonic_ns() // 100:
            raise ValueError("The outage watcher's playback window has expired")
        if process_identity(watcher["pid"]) != watcher["processIdentity"]:
            raise ValueError("The outage watcher process was replaced")
        if read_json(watcher_ready) != watcher:
            raise ValueError("The outage watcher changed during verification")
        proof["watcher"] = watcher
    return proof


def playback_marker(path, run_id, token):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 16_384:
            raise ValueError("Playback marker must be a small regular JSON file")
        value = json.loads(stream.read(16_385))
    if value.get("runID") != run_id or value.get("watcherToken") != token:
        raise ValueError("Playback marker does not match the waiting source/watcher")
    return value


def watch_outage(args):
    if not 0.1 <= args.outage_seconds <= 10 or not 1 <= args.marker_timeout <= 90:
        raise ValueError("Outage must be 0.1–10 seconds; marker wait must be 1–90 seconds")
    if os.path.lexists(args.marker):
        raise ValueError("Refusing an existing playback marker")
    source = verified_readiness(args.control_dir, args.run_id, args.lan_host, args.minimum_remaining)
    wait_seconds = min(args.marker_timeout, source["remainingSeconds"] - args.outage_seconds - 15)
    state = {"state": "waitingForPlayback", "pid": os.getpid(), "processIdentity": process_identity(os.getpid()),
             "watcherToken": str(uuid.uuid4()), "source": source, "marker": str(args.marker),
             "createdUnixSeconds": time.time(), "waitUntilHost100ns": time.monotonic_ns() // 100 + int(wait_seconds * 10_000_000)}
    atomic_json(args.ready_file, state)
    try:
        end = time.monotonic() + wait_seconds
        while not os.path.lexists(args.marker):
            if time.monotonic() >= end:
                raise ValueError("Fresh playback marker did not arrive within the source budget")
            time.sleep(0.02)
        marker = playback_marker(args.marker, args.run_id, state["watcherToken"])
        current = verified_readiness(args.control_dir, args.run_id, args.lan_host, args.minimum_remaining)
        if any(current[key] != source[key] for key in ("runID", "generation", "pid", "endpoint")):
            raise ValueError("The source changed while the watcher waited for playback")
        state["state"] = "performingOutage"; atomic_json(args.ready_file, state)
        began = {"unixSeconds": time.time(), "host100ns": time.monotonic_ns() // 100}
        expected = {"expectedDestinationID": source["destinationID"], "expectedGeneration": source["generation"]}
        stop = submit(args.control_dir, dict(expected, action="stop", source="primary", phase="synchronized-outage-stop"),
                      wait=10, expected_run_id=args.run_id)
        if stop.get("result") != "completed" or stop.get("runID") != args.run_id:
            raise ValueError("Exact sender retirement was not acknowledged")
        events = [json.loads(line) for line in (Path(source["evidenceDirectory"]) / "helper-events.jsonl").read_text().splitlines()]
        old = {event["event"]: event for event in events if event.get("generation") == source["generation"]}
        if not all(key in old for key in ("shutdown-complete", "exited")):
            raise ValueError("Sender exit did not establish graceful SDK shutdown")
        time.sleep(args.outage_seconds)
        start = submit(args.control_dir, dict(expected, action="start", source="primary", phase="synchronized-outage-start"),
                       wait=10, expected_run_id=args.run_id)
        if start.get("result") != "completed" or start.get("runID") != args.run_id:
            raise ValueError("Replacement source was not acknowledged")
        replacement = verified_readiness(args.control_dir, args.run_id, args.lan_host, 5)
        if (replacement["endpoint"] != source["endpoint"] or replacement["destinationID"] != source["destinationID"]
                or replacement["generation"] == source["generation"] or replacement["generation"] != start.get("resultGeneration")):
            raise ValueError("Replacement does not match the exact acknowledged Start generation/endpoint")
        result = {"marker": marker, "began": began, "oldSource": source, "newSource": replacement,
                  "requestedSleepSeconds": args.outage_seconds, "stopAck": stop, "startAck": start,
                  "sdkShutdownComplete": old["shutdown-complete"], "exactExit": old["exited"],
                  "finishedUnixSeconds": time.time()}
        atomic_json(args.result_file, result)
        state["state"] = "complete"; atomic_json(args.ready_file, state)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except BaseException as error:
        state.update(state="failed", error=str(error)); atomic_json(args.ready_file, state)
        raise


def submit(control, payload, wait=0, expected_run_id=None):
    manifest = read_json(control / "run.json")
    if expected_run_id is not None and manifest.get("runID") != expected_run_id:
        raise ValueError("Source run changed before command admission")
    identifier = str(uuid.uuid4()).upper()
    value = dict(payload, id=identifier, runID=manifest["runID"])
    commands = control / "commands"
    commands.mkdir(exist_ok=True)
    atomic_json(commands / f"{time.time_ns():020d}-{identifier}.json", value)
    acknowledgement = control / "acks" / f"{identifier}.json"
    end = time.monotonic() + wait
    while wait > 0 and time.monotonic() < end:
        if acknowledgement.exists():
            return read_json(acknowledgement)
        time.sleep(0.1)
    return {"id": identifier, "runID": manifest["runID"], "result": "queued", "acknowledgement": str(acknowledgement)}


def measure_processes(parent, output, control, lan_host, stop, errors, identities):
    """Record only this launch's tree and exact test-host PID, never process args."""
    with (output / "processes.csv").open("w", newline="") as stream, (output / "other-eucaly-processes.jsonl").open("w") as other_stream:
        writer = csv.writer(stream)
        writer.writerow(("elapsed_seconds", "pid", "ppid", "rss_kib", "cpu_percent", "command"))
        start = time.monotonic()
        while not stop.is_set():
            try:
                listing = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,rss=,%cpu=,comm="],
                                         capture_output=True, text=True, check=True, timeout=5)
                rows = [line.split(None, 4) for line in listing.stdout.splitlines()]
                owned = {parent}
                pid_file = output / "test-host.pid"
                if pid_file.exists():
                    host = int(pid_file.read_text().strip())
                    owned.add(host)
                    if host not in identities:
                        identity = subprocess.run(["/bin/ps", "-p", str(host), "-o", "lstart=,comm="],
                                                  capture_output=True, text=True, check=False, timeout=5)
                        if identity.returncode == 0 and identity.stdout.strip():
                            identities[host] = identity.stdout.strip()
                while True:
                    children = {int(row[0]) for row in rows if len(row) == 5 and int(row[1]) in owned}
                    if children <= owned:
                        break
                    owned |= children
                for row in rows:
                    if len(row) == 5 and int(row[0]) in owned:
                        writer.writerow((round(time.monotonic() - start, 3), *row))
                stream.flush()
                # Reuse this exact process snapshot to record competing app/test
                # work without extra polling, arguments or environment data.
                unrelated = [{"pid": int(row[0]), "ppid": int(row[1]), "executable": row[4]}
                             for row in rows if len(row) == 5 and int(row[0]) not in owned
                             and Path(row[4]).name in ("eucaly", "eucalyNetworkHelper", "xcodebuild", "swift-frontend", "swiftc", "clang")]
                other_stream.write(json.dumps({"observedAtUTC": datetime.now(timezone.utc).isoformat(),
                    "elapsedSeconds": round(time.monotonic() - start, 3), "processes": unrelated}, sort_keys=True) + "\n")
                other_stream.flush()
                status_file = output / "status.json"
                if status_file.exists():
                    status = read_json(status_file)
                    helpers = {int(item["pid"]): item for item in status.get("helpers", [])
                               if item.get("technology") == "omt" and int(item.get("pid", 0)) in owned}
                    endpoints = []
                    if helpers:
                        sockets = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", ",".join(map(str, helpers)),
                                                  "-iTCP", "-sTCP:LISTEN", "-Fpn"],
                                                 capture_output=True, text=True, check=False, timeout=5)
                        if sockets.returncode not in (0, 1):
                            raise RuntimeError("lsof could not inspect the owned source listeners: " + sockets.stderr.strip())
                        current = None
                        for line in sockets.stdout.splitlines():
                            if line.startswith("p"):
                                current = int(line[1:])
                            elif line.startswith("n") and current in helpers:
                                raw = line[1:]
                                port = raw.rsplit(":", 1)[-1]
                                if port.isdigit():
                                    info = helpers[current]
                                    host = f"[{lan_host}]" if ":" in lan_host else lan_host
                                    endpoints.append({"pid": current, "generation": info.get("generation"),
                                                      "destinationID": info.get("destinationID"), "sourceName": info.get("sourceName"),
                                                      "listener": raw, "endpoint": f"omt://{host}:{port}"})
                    endpoint_value = {"runID": status.get("runID"), "observedAtUTC": datetime.now(timezone.utc).isoformat(),
                                      "hostProvidedByCoordinator": lan_host, "sources": endpoints}
                    atomic_json(output / "endpoints.json", endpoint_value)
                    atomic_json(control / "endpoints.json", endpoint_value)
            except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
                message = f"Required source process measurement failed: {error}"
                errors.append(message)
                (output / "process-measurement-error.txt").write_text(message + "\n")
                return
            stop.wait(2)


def end_owned_host(identities, output):
    """Last-resort cleanup verifies the exact previously sampled PID identity."""
    cleanup = []
    for pid, expected in identities.items():
        actual = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart=,comm="],
                                capture_output=True, text=True, check=False, timeout=5)
        if actual.returncode == 0 and actual.stdout.strip() == expected:
            os.kill(pid, signal.SIGTERM)
            cleanup.append({"pid": pid, "identity": expected, "signal": "SIGTERM"})
    atomic_json(output / "forced-host-cleanup.json", {"processes": cleanup})


def summarize(output, require_complete=False):
    """Evaluate sender invariants without conflating AAC silence with lost PCM."""
    violations, warnings = set(), set()
    latest, observations, phases = {}, 0, {}
    router_observation = False
    checkpoints = output / "checkpoints.jsonl"
    if not checkpoints.exists():
        violations.add("No sender checkpoints were retained")
    else:
        with checkpoints.open() as stream:
            for line in stream:
                if not line.strip():
                    continue
                value = json.loads(line)
                latest = value
                observations += 1
                phase = value.get("phase", "unknown")
                item = phases.setdefault(phase, {"observations": 0, "firstHost100ns": value.get("host100ns"),
                                                  "lastHost100ns": value.get("host100ns"), "sources": {}})
                item["observations"] += 1
                item["lastHost100ns"] = value.get("host100ns")
                violations.update(value.get("invariantViolations", []))
                if "routerFailures" in value:
                    router_observation = True
                if value.get("unexpectedRouterFailureCount", 0):
                    violations.add("Unexpected app-side router failure was observed")
                for failure in value.get("routerFailures", []):
                    if not failure.get("expectedInjected", False):
                        violations.add("Unexpected app-side router failure: " + failure.get("message", "unknown"))
                for coverage in value.get("knownPositionCoverage", []):
                    if not coverage.get("passed", False) or coverage.get("blocks", 0) < coverage.get("minimumBlocks", 1):
                        violations.add("Strict position/silence coverage was insufficient: " + coverage.get("destinationID", "unknown"))
                totals = value.get("audioOracle", {}).get("totals", {})
                for key in ("invalidBlocks", "nonFiniteSamples", "outOfRangeSamples", "stableTimestampGaps", "duplicateTimestamps",
                            "timestampRegressions", "overlappingTimestamps", "expectationFailures"):
                    if totals.get(key, 0):
                        violations.add(f"PCM {key} detected")
                expected = set(value.get("expectedFailureGenerations", []))
                for helper in value.get("helpers", []):
                    if helper.get("revisionRegressions", 0):
                        violations.add("Sender revision regressed: " + helper.get("sourceName", ""))
                    if helper.get("staleEpochOffers", 0):
                        violations.add("Stale owner reached sender: " + helper.get("sourceName", ""))
                    if helper.get("failure") and helper.get("generation") not in expected:
                        violations.add("Unexpected source failure: " + helper["failure"])
                for source in value.get("destinations", []):
                    sdk = source.get("sdk", {})
                    if source.get("failureReason") and not source.get("failureIsExplicitInjectedFault", False):
                        violations.add("Unexpected app-side router failure: " + source["failureReason"])
                    if source.get("playerError"):
                        violations.add("Program player failed: " + source["playerError"])
                    if sdk.get("surfacePoolHighWaterMark", 0) > 4:
                        violations.add("GPU pool exceeded four leases: " + source.get("name", ""))
                    expected_volume = source.get("expectedLocalPlayerVolume", 0)
                    has_program_player = bool(source["playerIdentity"]) if "playerIdentity" in source else True
                    if expected_volume not in (0, 1) or (has_program_player and source.get("localPlayerVolume", 0) != expected_volume):
                        violations.add("Program player violated local route policy: " + source.get("name", ""))
                    if "expectedMusicLocalVolume" in source and source.get("musicLocalVolume", 0) != source["expectedMusicLocalVolume"]:
                        violations.add("Background music violated local route policy: " + source.get("name", ""))
                    if source.get("technology") == "native":
                        native = source.get("native", {})
                        driver = native.get("driver", {})
                        if source.get("expectedOpen"):
                            if not source.get("active") or not driver.get("windowVisible"):
                                violations.add("Expected native projection was not visible")
                            if driver.get("physicalDisplayUUID") != native.get("requestedPhysicalDisplayUUID"):
                                violations.add("Native projection used a different physical display")
                            if source.get("expectedProgramVideoVisible", bool(source.get("playerIdentity"))) and (not native.get("programVideoReady")
                                    or driver.get("nativePlayerIdentity") != source.get("playerIdentity")
                                    or driver.get("nativePlayerItemIdentity") != source.get("playerItemIdentity")):
                                violations.add("Native projection did not retain the shared ready program player")
                        if source.get("active"):
                            native_phase = item.setdefault("nativeOutputs", {}).setdefault(source["id"], {
                                "observations": 0, "firstPlayerTime": source.get("playerTime"),
                                "lastPlayerTime": source.get("playerTime"), "windowNumbers": [],
                                "physicalDisplayUUID": driver.get("physicalDisplayUUID"),
                                "presentedFrameCadenceMeasured": False})
                            native_phase["observations"] += 1
                            native_phase["lastPlayerTime"] = source.get("playerTime")
                            number = driver.get("windowNumber")
                            if number and number not in native_phase["windowNumbers"]:
                                native_phase["windowNumbers"].append(number)
                        continue
                    if not source.get("active"):
                        continue
                    source_phase = item["sources"].setdefault(source["id"], {"sourceName": source.get("sourceName"),
                        "firstFrames": sdk.get("submittedFrames", 0), "lastFrames": 0,
                        "firstHost100ns": value.get("host100ns", 0), "lastHost100ns": value.get("host100ns", 0),
                        "minimumSDKFPS": None, "maximumPool": 0, "maximumAudioSubmissionAgeMs": 0, "slowCadenceObservations": 0})
                    source_phase["lastFrames"] = sdk.get("submittedFrames", 0)
                    source_phase["lastHost100ns"] = value.get("host100ns", 0)
                    fps = sdk.get("effectiveFramesPerSecond")
                    if fps is not None:
                        before = source_phase["minimumSDKFPS"]
                        source_phase["minimumSDKFPS"] = fps if before is None else min(before, fps)
                    source_phase["maximumPool"] = max(source_phase["maximumPool"], sdk.get("surfacePoolHighWaterMark", 0))
                    source_phase["maximumAudioSubmissionAgeMs"] = max(source_phase["maximumAudioSubmissionAgeMs"], sdk.get("audioSubmissionAgeMilliseconds", 0))
                    source_phase["slowCadenceObservations"] += bool(sdk.get("slowCadence"))
    for phase, item in phases.items():
        for source in item["sources"].values():
            elapsed = (source["lastHost100ns"] - source["firstHost100ns"]) / 10_000_000
            frames = source["lastFrames"] - source["firstFrames"]
            source["observedSDKSubmissionFPS"] = frames / elapsed if elapsed > 0 and frames >= 0 else None
            if elapsed >= 10 and source["observedSDKSubmissionFPS"] is not None and source["observedSDKSubmissionFPS"] < 29:
                warnings.add(f"Phase {phase}: {source['sourceName']} averaged {source['observedSDKSubmissionFPS']:.3f} SDK submissions/s")
    for failure in latest.get("unexpectedSourceFailures", []):
        violations.add("Unexpected source failure: " + failure)
    if not router_observation:
        warnings.add("This harness version lacks durable typed app-router failure observation; helper failures and player errors alone cannot establish that gate")
    if require_complete:
        if latest.get("state") != "complete":
            violations.add("The sender run did not reach complete")
        if not latest.get("allOwnedHelpersExited", False) or latest.get("activeOutputs", 1) != 0:
            violations.add("Exact-child cleanup was not established")
        if latest.get("nativeOutputConfigured") and (not latest.get("allOwnedNativeWindowsClosed", False)
                or latest.get("coordinatorHasActiveOutputs", True)):
            violations.add("Native output cleanup was not established")
    return {"observations": observations, "senderState": latest.get("state", "no status"),
            "runID": latest.get("runID"), "invariantViolations": sorted(violations), "performanceWarnings": sorted(warnings),
            "audioTotals": latest.get("audioOracle", {}).get("totals", {}), "phases": phases,
            "knownPositionBlocks": latest.get("knownPositionBlocks", 0),
            "knownPositionCoverage": latest.get("knownPositionCoverage", []),
            "durableRouterFailureObservation": router_observation,
            "qualification": "Sender invariants and workload observations only; receiver delivery, physical picture/audio and sustained qualification are separate"}


def run_deadline(value, now):
    """Require a fresh explicit window; naive local dates cannot authorize a run."""
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("--deadline must include its UTC offset")
    deadline = parsed.timestamp()
    if not now + 45 < deadline <= now + 1800:
        raise ValueError("--deadline must be more than 45 seconds and at most 30 minutes from launch")
    return deadline


def run(args):
    if not 30 <= args.seconds <= 1800:
        raise ValueError("--seconds must be between 30 and 1800")
    deadline = run_deadline(args.deadline, time.time())
    ipaddress.ip_address(args.lan_host)
    media = args.media.expanduser().resolve(strict=True) if args.media else None
    if media and (not media.is_file() or not os.access(media, os.R_OK)):
        raise ValueError("--media must be a readable file; the fixture never rewrites it")
    output, control = args.output.resolve(), args.control_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    control.mkdir(parents=True, exist_ok=True)
    if (output / "launch.json").exists() or (output / "checkpoints.jsonl").exists():
        raise ValueError("Refusing to overwrite a previous run's evidence; select a new --output directory")
    if (control / "status.json").exists():
        previous = read_json(control / "status.json")
        if previous.get("state") in ("running", "command", "finishing"):
            try:
                os.kill(int(previous["testHostPID"]), 0)
            except ProcessLookupError:
                pass
            else:
                raise ValueError("The shared control directory still belongs to a live source; finish it before another launch")
    run_id = str(uuid.uuid4()).upper()
    env = os.environ.copy()
    settings = {"EUCALY_OMT_PRODUCTION_ENABLE": "1", "EUCALY_OMT_PRODUCTION_RUN_ID": run_id,
                "EUCALY_OMT_PRODUCTION_SECONDS": str(args.seconds), "EUCALY_OMT_PRODUCTION_DEADLINE": str(deadline),
                "EUCALY_OMT_PRODUCTION_DIRECTORY": str(output), "EUCALY_OMT_STRESS_CONTROL_DIR": str(control)}
    if args.audio_trace:
        trace_directory = output / "audio-traces"
        trace_directory.mkdir(exist_ok=False)
        settings["EUCALY_NDI_AUDIO_TRACE_DIRECTORY"] = str(trace_directory)
    else:
        env.pop("EUCALY_NDI_AUDIO_TRACE_DIRECTORY", None)
        env.pop("TEST_RUNNER_EUCALY_NDI_AUDIO_TRACE_DIRECTORY", None)
    if args.video_diagnostics:
        settings["EUCALY_OMT_VIDEO_DIAGNOSTICS"] = "1"
    else:
        env.pop("EUCALY_OMT_VIDEO_DIAGNOSTICS", None)
        env.pop("TEST_RUNNER_EUCALY_OMT_VIDEO_DIAGNOSTICS", None)
    if args.video_trace:
        trace_directory = output / "video-traces"
        trace_directory.mkdir(exist_ok=False)
        settings["EUCALY_NETWORK_VIDEO_TRACE_DIRECTORY"] = str(trace_directory)
    else:
        env.pop("EUCALY_NETWORK_VIDEO_TRACE_DIRECTORY", None)
        env.pop("TEST_RUNNER_EUCALY_NETWORK_VIDEO_TRACE_DIRECTORY", None)
    if args.native_display_uuid:
        settings["EUCALY_OMT_PRODUCTION_NATIVE_DISPLAY_UUID"] = str(uuid.UUID(args.native_display_uuid)).upper()
    else:
        env.pop("EUCALY_OMT_PRODUCTION_NATIVE_DISPLAY_UUID", None)
        env.pop("TEST_RUNNER_EUCALY_OMT_PRODUCTION_NATIVE_DISPLAY_UUID", None)
    if media:
        settings["EUCALY_OMT_PRODUCTION_MEDIA_PATH"] = str(media)
    else:
        env.pop("TEST_RUNNER_EUCALY_OMT_PRODUCTION_MEDIA_PATH", None)
    for key, value in settings.items():
        env["TEST_RUNNER_" + key] = value
    command = ["xcodebuild", "-project", "eucaly.xcodeproj", "-scheme", "eucaly", "-destination", "platform=macOS",
               "-configuration", "Debug", "-derivedDataPath", str(args.derived_data.resolve()),
               "-resultBundlePath", str(output / "ProductionStress.xcresult"),
               "-only-testing:eucalyTests/OMTProductionStressTests/testControlledProductionSource",
               "-parallel-testing-enabled", "NO", "-test-timeouts-enabled", "YES",
               "-maximum-test-execution-time-allowance", str(args.seconds + 120),
               "-default-test-execution-time-allowance", str(args.seconds + 120),
               "test-without-building" if args.without_building else "test", "SWIFT_OPTIMIZATION_LEVEL=-O",
               "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "DEVELOPMENT_TEAM="]
    atomic_json(output / "launch.json", {"runID": run_id, "command": command, "environment": settings,
                "optimization": "-O, Debug/test hooks retained", "mediaReadOnly": str(media) if media else "generated fixture",
                "deadlineUTC": datetime.fromtimestamp(deadline, timezone.utc).isoformat(),
                "sourceName": "eucaly Production Stress", "automaticTransitions": False,
                "evidenceScope": "Sender-only; Apple TV metrics and physical observations collected independently"})
    print(f"Starting genuine eucaly production path; stablehold only. Evidence: {output}; controls: {control}", flush=True)
    stop = threading.Event()
    errors, identities = [], {}
    forced = False
    with (output / "xcodebuild.log").open("w") as log:
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        monitor = threading.Thread(target=measure_processes, args=(process.pid, output, control, args.lan_host, stop, errors, identities), daemon=True)
        monitor.start()
        try:
            # The source begins normal teardown at deadline - 30. Reserve the
            # last 20 seconds for exact-owned-process containment if it stalls.
            status = process.wait(timeout=max(1, min(args.seconds + 120, deadline - time.time() - 20)))
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            forced = True
            try:
                if read_json(control / "run.json").get("runID") == run_id:
                    submit(control, {"action": "finish", "phase": "launcher-cleanup"})
                status = process.wait(timeout=5)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                end_owned_host(identities, output)
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    status = process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    status = process.wait(timeout=3)
        finally:
            stop.set(); monitor.join(timeout=10)
    latest = read_json(output / "status.json") if (output / "status.json").exists() else {}
    evaluation = summarize(output, require_complete=True)
    atomic_json(output / "sender-summary.json", evaluation)
    complete = status == 0 and not forced and not errors and latest.get("runID") == run_id and not evaluation["invariantViolations"]
    atomic_json(output / "collection-result.json", {"runID": run_id, "xcodebuildExitCode": status, "forcedCleanup": forced,
                "processMeasurementErrors": errors, "senderCollectionComplete": complete,
                "senderState": latest.get("state", "no status"), "finishReason": latest.get("finishReason", ""),
                "receiverQualification": "Separate receiver/physical evidence required"})
    print(f"Sender collection {'completed' if complete else 'incomplete'}; xcodebuild={status}; {output / 'status.json'}", flush=True)
    return 0 if complete else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    launch = modes.add_parser("run", help="launch the genuine source; hold its initial movie until explicit commands")
    launch.add_argument("--seconds", type=int, default=1200)
    launch.add_argument("--deadline", required=True, help="explicit ISO 8601 cutoff with UTC offset, at most 30 minutes from launch")
    launch.add_argument("--output", type=Path, default=ROOT / "build/OMTProductionStress-20261024")
    launch.add_argument("--control-dir", type=Path, default=CONTROL)
    launch.add_argument("--derived-data", type=Path, default=ROOT / "build/DerivedDataOMTProduction")
    launch.add_argument("--media", type=Path)
    launch.add_argument("--lan-host", default="192.168.1.3")
    launch.add_argument("--without-building", action="store_true", help="use already built optimized Debug tests; performs no compilation")
    launch.add_argument("--audio-trace", action="store_true", help="enable bounded existing per-block app/helper timing traces in this run's evidence directory")
    launch.add_argument("--video-diagnostics", action="store_true", help="retain bounded exact-call OMT video zero-return/drop observations")
    launch.add_argument("--video-trace", action="store_true", help="retain complete bounded SDK-wrapper timing traces, exported after owned sender cleanup")
    launch.add_argument("--native-display-uuid", help="allow an isolated native output only on this explicitly selected physical display; start it with a separate command")
    send = modes.add_parser("command", help="queue one explicit phase and wait for its acknowledgement")
    send.add_argument("action", choices=ACTIONS)
    send.add_argument("--control-dir", type=Path, default=CONTROL)
    send.add_argument("--workspace", choices=("Home", "Online"))
    send.add_argument("--source", choices=("primary", "second", "ndi", "native"))
    send.add_argument("--path", type=Path)
    send.add_argument("--phase")
    send.add_argument("--text")
    send.add_argument("--index", type=int)
    send.add_argument("--seconds", type=float)
    send.add_argument("--fault", choices=("sdk-crash", "sdk-stall", "audio-stall"))
    send.add_argument("--wait", type=float, default=30)
    report = modes.add_parser("status", help="read latest sender and listener status")
    report.add_argument("--control-dir", type=Path, default=CONTROL)
    readiness = modes.add_parser("ready", help="verify current exact-PID endpoint and optional waiting watcher; launches nothing")
    watcher = modes.add_parser("watch-outage", help="wait for a run/token-fenced playback marker, then stop/sleep/start once")
    for mode in (readiness, watcher):
        mode.add_argument("--control-dir", type=Path, required=True)
        mode.add_argument("--run-id", required=True)
        mode.add_argument("--lan-host", required=True)
        mode.add_argument("--minimum-remaining", type=float, default=75)
    readiness.add_argument("--watcher-ready", type=Path)
    watcher.add_argument("--marker", type=Path, required=True)
    watcher.add_argument("--ready-file", type=Path, required=True)
    watcher.add_argument("--result-file", type=Path, required=True)
    watcher.add_argument("--marker-timeout", type=float, default=45)
    watcher.add_argument("--outage-seconds", type=float, default=2)
    check = modes.add_parser("check", help="evaluate retained sender invariants and phase counters without starting anything")
    check.add_argument("--output", type=Path, default=ROOT / "build/OMTProductionStress-20261024")
    check.add_argument("--require-complete", action="store_true")
    args = parser.parse_args()
    try:
        if args.mode == "ready":
            value = verified_readiness(args.control_dir, args.run_id, args.lan_host, args.minimum_remaining, args.watcher_ready)
            print(json.dumps(value, indent=2, sort_keys=True))
            return 0
        if args.mode == "watch-outage":
            return watch_outage(args)
        if args.mode == "run":
            return run(args)
        if args.mode == "check":
            value = summarize(args.output.resolve(), require_complete=args.require_complete)
            print(json.dumps(value, indent=2, sort_keys=True))
            return 1 if value["invariantViolations"] else 0
        if args.mode == "status":
            value = {"status": read_json(args.control_dir / "status.json")}
            if (args.control_dir / "endpoints.json").exists():
                value["endpoints"] = read_json(args.control_dir / "endpoints.json")
        else:
            payload = {"action": args.action}
            for key in ("workspace", "source", "phase", "text", "index", "seconds", "fault"):
                if getattr(args, key) is not None:
                    payload[key] = getattr(args, key)
            if args.path is not None:
                payload["path"] = str(args.path.expanduser().resolve(strict=True))
            value = submit(args.control_dir, payload, wait=args.wait)
        print(json.dumps(value, indent=2, sort_keys=True))
        return 1 if value.get("result") == "rejected" else 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    raise SystemExit(main())
