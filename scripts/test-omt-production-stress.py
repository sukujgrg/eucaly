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
import os
from pathlib import Path
import signal
import subprocess
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
CONTROL = Path("/tmp/eucaly-omt-production-stress-20261024")
# Renewed by the operator for the coordinated wired audio-warning investigation.
CUTOFF = datetime.fromisoformat("2026-10-24T13:00:00+11:00").timestamp()
ACTIONS = ("stablehold", "hold", "marker", "status", "lyrics", "slides", "video", "generated", "image", "pdf",
           "preview", "loadpreview", "select", "next", "hide", "show", "clear", "pause", "play", "seek", "transfer",
           "start", "retry", "restart", "stop", "enable", "disable", "fault", "music", "musicstop", "position", "finish")


def read_json(path):
    return json.loads(path.read_text())


def atomic_json(path, value):
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    temporary.write_text(json.dumps(value, sort_keys=True) + "\n")
    temporary.replace(path)


def submit(control, payload, wait=0):
    manifest = read_json(control / "run.json")
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
    with (output / "processes.csv").open("w", newline="") as stream:
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
                    if source.get("localPlayerVolume", 0) != 0:
                        violations.add("Network-only player became audible locally: " + source.get("name", ""))
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
    return {"observations": observations, "senderState": latest.get("state", "no status"),
            "runID": latest.get("runID"), "invariantViolations": sorted(violations), "performanceWarnings": sorted(warnings),
            "audioTotals": latest.get("audioOracle", {}).get("totals", {}), "phases": phases,
            "knownPositionBlocks": latest.get("knownPositionBlocks", 0),
            "knownPositionCoverage": latest.get("knownPositionCoverage", []),
            "durableRouterFailureObservation": router_observation,
            "qualification": "Sender invariants and workload observations only; receiver delivery, physical picture/audio and sustained qualification are separate"}


def run(args):
    if not 30 <= args.seconds <= 10800:
        raise ValueError("--seconds must be between 30 and 10800")
    deadline = datetime.fromisoformat(args.deadline).timestamp()
    if not time.time() + 45 < deadline <= CUTOFF:
        raise ValueError("Run deadline must be future and no later than 2026-10-24 13:00 Sydney")
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
            status = process.wait(timeout=max(30, min(args.seconds + 600, deadline - time.time() + 10)))
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            forced = True
            try:
                if read_json(control / "run.json").get("runID") == run_id:
                    submit(control, {"action": "finish", "phase": "launcher-cleanup"}, wait=10)
                status = process.wait(timeout=15)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                end_owned_host(identities, output)
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    status = process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    status = process.wait(timeout=10)
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
    launch.add_argument("--seconds", type=int, default=7200)
    launch.add_argument("--deadline", default="2026-10-24T13:00:00+11:00")
    launch.add_argument("--output", type=Path, default=ROOT / "build/OMTProductionStress-20261024")
    launch.add_argument("--control-dir", type=Path, default=CONTROL)
    launch.add_argument("--derived-data", type=Path, default=ROOT / "build/DerivedDataOMTProduction")
    launch.add_argument("--media", type=Path)
    launch.add_argument("--lan-host", default="192.168.1.3")
    launch.add_argument("--without-building", action="store_true", help="use already built optimized Debug tests; performs no compilation")
    launch.add_argument("--audio-trace", action="store_true", help="enable bounded existing per-block app/helper timing traces in this run's evidence directory")
    send = modes.add_parser("command", help="queue one explicit phase and wait for its acknowledgement")
    send.add_argument("action", choices=ACTIONS)
    send.add_argument("--control-dir", type=Path, default=CONTROL)
    send.add_argument("--workspace", choices=("Home", "Online"))
    send.add_argument("--source", choices=("primary", "second", "ndi"))
    send.add_argument("--path", type=Path)
    send.add_argument("--phase")
    send.add_argument("--text")
    send.add_argument("--index", type=int)
    send.add_argument("--seconds", type=float)
    send.add_argument("--fault", choices=("sdk-crash", "sdk-stall", "audio-stall"))
    send.add_argument("--wait", type=float, default=30)
    report = modes.add_parser("status", help="read latest sender and listener status")
    report.add_argument("--control-dir", type=Path, default=CONTROL)
    check = modes.add_parser("check", help="evaluate retained sender invariants and phase counters without starting anything")
    check.add_argument("--output", type=Path, default=ROOT / "build/OMTProductionStress-20261024")
    check.add_argument("--require-complete", action="store_true")
    args = parser.parse_args()
    try:
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
