#!/usr/bin/env python3
"""Validate the repository's Codex roles and their source references (Python 3.11+).

This offline check does not make model requests. Native role discovery and
automatic delegation also require live smoke tests using a current Codex client.
"""

from pathlib import Path
import re
import tomllib


ROOT = Path(__file__).resolve().parent.parent
EXPECTED_ROLES = {
    "presentation_core",
    "media_engine",
    "ndi_transport",
    "library_editing",
    "macos_interface",
    "independent_reviewer",
}
REQUIRED_FIELDS = {"name", "description", "developer_instructions"}
SHARED_CONTRACT_LINK = "[Shared Completion Contract](../../AGENTS.md#shared-completion-contract)"
INHERITED_FIELDS = {
    "model", "model_reasoning_effort", "sandbox_mode", "approval_policy",
    "model_provider", "mcp_servers",
}
SOURCE_REFERENCE = re.compile(
    r"\b(?:docs/|eucaly/|eucalyNetworkHelper/|eucalyTests/)[A-Za-z0-9_./-]+"
    r"\.(?:swift|md|c|h)\b"
)


def require(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")


def main():
    guide = (ROOT / "AGENTS.md").read_text()
    require(
        "\n## Shared Completion Contract\n" in guide,
        "AGENTS.md must define the shared completion contract linked by every role",
    )
    config = tomllib.loads((ROOT / ".codex/config.toml").read_text())
    require(config.get("agents", {}).get("enabled") is True, "project agents must be enabled")
    require(
        config.get("project_doc_max_bytes", 32768) >= len(guide.encode("utf-8")),
        "project instruction budget would truncate AGENTS.md",
    )
    paths = sorted((ROOT / ".codex/agents").glob("*.toml"))
    require({path.stem for path in paths} == EXPECTED_ROLES, "expected five specialists and one reviewer")
    test_suites = {path.stem for path in (ROOT / "eucalyTests").rglob("*.swift")}
    references = set()
    suites = set()
    for path in paths:
        role = tomllib.loads(path.read_text())
        require(REQUIRED_FIELDS <= role.keys(), f"{path.name}: missing required role fields")
        require(role["name"] == path.stem, f"{path.name}: name must match the dispatch identity")
        require(
            all(isinstance(role[field], str) and role[field].strip() for field in REQUIRED_FIELDS),
            f"{path.name}: required role fields must be nonempty strings",
        )
        require(not INHERITED_FIELDS.intersection(role), f"{path.name}: preserve inherited model/permissions")
        require(
            SHARED_CONTRACT_LINK in role["developer_instructions"],
            f"{path.name}: must link to the shared completion contract",
        )
        link = f"[{role['name']}](.codex/agents/{path.name})"
        require(link in guide, f"{path.name}: missing AGENTS.md dispatch entry")
        for reference in SOURCE_REFERENCE.findall(role["developer_instructions"]):
            require((ROOT / reference).is_file(), f"{path.name}: missing source {reference}")
            references.add(reference)
        for suite in re.findall(r"\b[A-Z][A-Za-z0-9]+Tests\b", role["developer_instructions"]):
            require(suite in test_suites, f"{path.name}: missing test suite {suite}")
            suites.add(suite)
    print(f"PASS: {len(paths)} roles, dispatch entries and inherited configuration")
    print("PASS: every role links to the shared completion contract")
    print(f"PASS: {len(references)} source/document references and {len(suites)} test suites")
    print("PASS: complete AGENTS.md fits the project instruction budget")


if __name__ == "__main__":
    main()
