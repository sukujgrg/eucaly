#!/usr/bin/env python3
"""Check source ownership at the network SDK boundaries without loading SDKs."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / "eucalyNetworkHelper"
APP = ROOT / "eucaly/Output/Network"


def code_without_comments(source):
    # Retain quoted strings while removing comments, including embedded shader
    # sources. This check is about declared dependencies, not SDK execution.
    tokens = r'"""[\s\S]*?"""|"(?:\\.|[^"\\])*"|/\*[\s\S]*?\*/|//[^\n]*'
    return re.sub(tokens, lambda match: "" if match[0].startswith(("//", "/*")) else match[0], source)


def main():
    errors = []
    sources = sorted(path for folder in (APP, HELPER) for path in folder.rglob("*")
                     if path.suffix in {".swift", ".c", ".h"})
    for path in sources:
        relative = path.relative_to(ROOT).as_posix()
        code = code_without_comments(path.read_text())
        adapter = next((technology for technology in ("NDI", "OMT")
                        if f"/Transports/{technology}/" in f"/{relative}"), None)
        for sdk in ("ndi", "omt"):
            if re.search(rf"\beucaly_{sdk}_\w+", code) and adapter != sdk.upper():
                errors.append(f"{relative}: {sdk.upper()} bridge API outside its adapter")
        if adapter:
            peer = "OMT" if adapter == "NDI" else "NDI"
            if re.search(rf"\b{peer}(?:Runtime|SDKBridge)\b|Vendor/{peer}/", code):
                errors.append(f"{relative}: {adapter} adapter depends on {peer}")
        else:
            if re.search(r"\b(?:class|struct|enum|protocol)\s+(?:NDI|OMT)[A-Z]\w*", code):
                errors.append(f"{relative}: protocol-owned declaration in the shared layer")
        if re.search(r"\btypealias\s+(?:NDI|OMT|NetworkOutput)\w*\s*=", code):
            errors.append(f"{relative}: protocol compatibility alias")
        if "Core/NetworkSubmissionWorker.swift" in relative:
            if re.search(r"\b(?:NDI|OMT)[A-Z]\w*", code):
                errors.append(f"{relative}: common submission worker depends on a protocol type")

    for retired in ("eucaly/NDI", "eucalyNDIHelper", "eucalyTests/NDI"):
        if (ROOT / retired).exists():
            errors.append(f"{retired}: retired hierarchy still present")
    for path in (ROOT / "eucalyTests/Network/Shared").rglob("*.swift"):
        code = code_without_comments(path.read_text())
        if re.search(r"\b(?:class|struct|enum)\s+(?:NDI|OMT)[A-Z]\w*", code):
            errors.append(f"{path.relative_to(ROOT)}: protocol-owned fixture in shared tests")
    if errors:
        raise SystemExit("FAIL: network architecture\n" + "\n".join(errors))
    print(f"PASS: {len(sources)} network sources respect shared/NDI/OMT ownership")
    print("PASS: independent SDK adapters and no protocol compatibility aliases")


if __name__ == "__main__":
    main()
