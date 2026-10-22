#!/usr/bin/env python3
"""Run the opt-in NDI soak and retain test and descendant-process measurements."""
import argparse
import csv
import json
from datetime import datetime
import os
from pathlib import Path
import subprocess
import threading
import time


def sample_processes(parent, output, stop, errors):
    """Sample only this xcodebuild's process tree; never inspect unrelated args."""
    with output.open("w", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(("elapsed_seconds", "pid", "ppid", "rss_kib", "cpu_percent", "command"))
        start = time.monotonic()
        while not stop.is_set():
            try:
                result = subprocess.run(
                    ["/bin/ps", "-axo", "pid=,ppid=,rss=,%cpu=,comm="],
                    capture_output=True, text=True, check=True, timeout=5,
                )
            except (OSError, subprocess.SubprocessError) as error:
                message = f"Process measurements stopped: {error}"
                errors.append(message)
                (output.parent / "process-measurement-error.txt").write_text(message + "\n")
                return
            rows = [line.split(None, 4) for line in result.stdout.splitlines()]
            descendants = {parent}
            host = output.parent / "test-host.pid"
            if host.exists():
                descendants.add(int(host.read_text().strip()))
            while True:
                found = {int(row[0]) for row in rows if len(row) == 5 and int(row[1]) in descendants}
                if found <= descendants:
                    break
                descendants |= found
            for row in rows:
                if len(row) == 5 and int(row[0]) in descendants:
                    writer.writerow((round(time.monotonic() - start, 3), *row))
            stream.flush()
            stop.wait(5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=900)
    parser.add_argument("--mode", choices=("switches", "steady"), default="switches")
    parser.add_argument("--trace-audio", action="store_true", help="retain Debug-only audio hop timing CSVs")
    parser.add_argument("--source-name", help="explicit source name for an isolated steady diagnostic")
    parser.add_argument("--media", type=Path, help="read an existing movie unchanged instead of generating a steady-mode fixture")
    parser.add_argument("--observe-only", action="store_true", help="record actual-media audio gaps through the full run; not an audio qualification pass")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not 30 <= args.seconds <= 86400:
        parser.error("--seconds must be between 30 and 86400")
    if args.observe_only and (args.mode != "steady" or not args.media):
        parser.error("--observe-only requires --mode steady --media")
    if args.source_name and (args.mode != "steady" or not args.source_name.strip() or len(args.source_name.encode()) > 120
                             or any(ord(c) < 32 or ord(c) == 127 for c in args.source_name)):
        parser.error("--source-name requires steady mode and a nonempty name of at most 120 UTF-8 bytes without control characters")
    if args.media:
        if args.mode != "steady":
            parser.error("--media requires --mode steady")
        try:
            args.media = args.media.expanduser().resolve(strict=True)
            if not args.media.is_file():
                parser.error("--media must be a readable movie file")
            with args.media.open("rb") as media:
                if not media.read(1):
                    parser.error("--media must not be empty")
        except OSError as error:
            parser.error(f"cannot read --media: {error}")
    root = Path(__file__).resolve().parents[1]
    output = (args.output or root / "build" / "ndi-stress" / datetime.now().strftime("%Y%m%d-%H%M%S")).resolve()
    if output.exists():
        parser.error(f"refusing to overwrite existing evidence: {output}")
    output.mkdir(parents=True)
    env = os.environ.copy()
    # Xcode forwards TEST_RUNNER_ variables to the app test host without the prefix.
    env["TEST_RUNNER_EUCALY_NDI_STRESS_SECONDS"] = str(args.seconds)
    env["TEST_RUNNER_EUCALY_NDI_STRESS_MODE"] = args.mode
    env["TEST_RUNNER_EUCALY_NDI_STRESS_OBSERVE_ONLY"] = "1" if args.observe_only else "0"
    env["TEST_RUNNER_EUCALY_NDI_STRESS_REPORT"] = str(output / "checkpoints.jsonl")
    if args.trace_audio:
        env["TEST_RUNNER_EUCALY_NDI_AUDIO_TRACE_DIRECTORY"] = str(output)
    if args.source_name:
        env["TEST_RUNNER_EUCALY_NDI_STRESS_SOURCE_NAME"] = args.source_name
    if args.media:
        env["TEST_RUNNER_EUCALY_NDI_STRESS_MEDIA_PATH"] = str(args.media)
    else:
        env.pop("TEST_RUNNER_EUCALY_NDI_STRESS_MEDIA_PATH", None)
    method = "testSteadyVideoAndAudioForRemoteDiagnosis" if args.mode == "steady" else "testWorkspaceTransfersAndOutputRestarts"
    command = [
        "xcodebuild", "-project", "eucaly.xcodeproj", "-scheme", "eucaly",
        "-destination", "platform=macOS", "-configuration", "Debug",
        "-derivedDataPath", "build/DerivedData", "-resultBundlePath", str(output / "Stress.xcresult"),
        f"-only-testing:eucalyTests/NDISustainedStressTests/{method}", "-parallel-testing-enabled", "NO",
        "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", str(args.seconds + 300),
        "-default-test-execution-time-allowance", str(args.seconds + 120),
        "test", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "DEVELOPMENT_TEAM=",
    ]
    print(f"Running {args.seconds}s NDI stress test; evidence: {output}", flush=True)
    if args.observe_only:
        print("Observation only: audio gaps and receiver drops are retained without aborting; this is not audio qualification.", flush=True)
    stop = threading.Event()
    measurement_errors = []
    with (output / "xcodebuild.log").open("w") as log:
        process = subprocess.Popen(command, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
        monitor = threading.Thread(target=sample_processes,
                                   args=(process.pid, output / "processes.csv", stop, measurement_errors), daemon=True)
        monitor.start()
        try:
            status = process.wait(timeout=args.seconds + 600)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            process.terminate()
            try:
                status = process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
                status = process.wait(timeout=10)
            if status == 0:
                status = 1
        finally:
            stop.set()
            monitor.join(timeout=10)
    print(f"NDI stress exit code: {status}; log: {output / 'xcodebuild.log'}", flush=True)
    if measurement_errors:
        for message in measurement_errors:
            print(message, flush=True)
        if status == 0:
            print("The required process measurements are incomplete; this run is not a qualification pass.", flush=True)
            return 1
    if status == 0:
        checkpoint_file = output / "checkpoints.jsonl"
        last = None
        if checkpoint_file.exists():
            with checkpoint_file.open() as checkpoints:
                for line in checkpoints:
                    if line.strip():
                        last = json.loads(line)
        if not last or last.get("phase") != "complete" or last.get("elapsed", 0) < args.seconds:
            print("The requested soak did not complete; a skipped or partial test is not a pass.", flush=True)
            return 1
        if bool(last.get("observationOnly", False)) != args.observe_only:
            print("The test observation mode did not match the requested mode; this run is invalid.", flush=True)
            return 1
        if args.observe_only:
            print("Observation completed. Review recorded gaps and audio levels; successful collection is not an audio qualification pass.", flush=True)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
