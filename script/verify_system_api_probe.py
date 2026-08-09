#!/usr/bin/env python3
"""Validate a factual PowerLens system-API probe against an OS profile."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from system_api_probe_contract import VerificationResult, verify_report


def _load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if type(value) is not dict:
        raise ValueError(f"{path} must contain a JSON object")
    return value


def verification_result(
    report: dict[str, Any],
    profile: dict[str, Any],
    *,
    mode: str = "hosted",
    expected_app_version: str | None = None,
    expected_app_build: str | None = None,
) -> VerificationResult:
    return verify_report(
        report,
        profile,
        mode=mode,
        expected_app_version=expected_app_version,
        expected_app_build=expected_app_build,
    )


def validate_report(
    report: dict[str, Any],
    profile: dict[str, Any],
    *,
    mode: str = "hosted",
    expected_app_version: str | None = None,
    expected_app_build: str | None = None,
) -> list[str]:
    """Compatibility wrapper for callers that only need blocking errors."""
    return list(
        verification_result(
            report,
            profile,
            mode=mode,
            expected_app_version=expected_app_version,
            expected_app_build=expected_app_build,
        ).errors
    )


def _summary_value(value: Any) -> str:
    if type(value) is bool:
        return "available" if value else "unavailable"
    if value is None:
        return "unavailable"
    return str(value).replace("|", "\\|").replace("\n", " ")


def _write_summary(
    path: Path,
    *,
    report: dict[str, Any],
    profile: dict[str, Any],
    mode: str,
    result: VerificationResult,
) -> None:
    powerui = report.get("powerUI")
    if type(powerui) is not dict:
        powerui = {}
    runtime = powerui.get("runtimeObservation")
    if type(runtime) is not dict:
        runtime = {}
    iops = report.get("ioPowerSources")
    if type(iops) is not dict:
        iops = {}
    adapter = report.get("externalPowerAdapter")
    if type(adapter) is not dict:
        adapter = {}
    battery = report.get("appleSmartBattery")
    if type(battery) is not dict:
        battery = {}
    smc = report.get("appleSMC")
    if type(smc) is not dict:
        smc = {}

    static_abi_failed = any(
        message.startswith("PowerUI selector")
        or message.startswith("PowerUI method")
        or message.startswith("PowerUI optional capability")
        or message in {
            "PowerUI framework did not load",
            "PowerUISmartChargeClient was not found",
        }
        for message in result.errors
    )
    schema_failed = any(
        message.startswith("profile.")
        or message.startswith("report.")
        or message.startswith("probe schema version")
        for message in result.errors
    )
    if schema_failed:
        static_abi_status = "NOT VERIFIED"
    elif static_abi_failed:
        static_abi_status = "FAIL"
    else:
        static_abi_status = "PASS"
    lines = [
        "### PowerLens system API compatibility probe",
        "",
        f"Profile: `{_summary_value(profile.get('profileName'))}`  ",
        f"Mode: `{mode}`  ",
        f"Result: `{'FAIL' if result.errors else 'PASS'}`",
        "",
        "| Scope | Observation |",
        "| --- | --- |",
        f"| PowerUI static ABI | {static_abi_status} |",
        "| PowerUI runtime | "
        f"{_summary_value(runtime.get('classification'))} "
        f"({_summary_value(runtime.get('reason'))}) |",
        "| IOPowerSources description | "
        f"{_summary_value(iops.get('firstDescriptionAvailable'))} |",
        "| External adapter dictionary | "
        f"{_summary_value(adapter.get('dictionaryAvailable'))} |",
        "| AppleSmartBattery properties | "
        f"{_summary_value(battery.get('propertiesReadable'))} |",
        "| AppleSMC connection | "
        f"{_summary_value(smc.get('connectionState'))} |",
        "",
    ]
    if result.warnings:
        lines.extend(["Warnings:", ""])
        lines.extend(f"- {_summary_value(item)}" for item in result.warnings)
        lines.append("")
    if result.errors:
        lines.extend(["Errors:", ""])
        lines.extend(f"- {_summary_value(item)}" for item in result.errors)
        lines.append("")
    if mode == "hosted":
        lines.extend(
            [
                "> Hosted mode validates packaging, schema, and static ABI. "
                "Unavailable VM hardware is reported as a warning and is not "
                "evidence of physical sensor coverage.",
                "",
            ]
        )

    with path.open("a", encoding="utf-8") as handle:
        handle.write("\n".join(lines))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument(
        "--mode", choices=("hosted", "physical"), required=True
    )
    parser.add_argument("--expected-app-version")
    parser.add_argument("--expected-app-build")
    parser.add_argument("--summary-file", type=Path)
    parser.add_argument("report", type=Path)
    arguments = parser.parse_args()

    try:
        profile = _load_json(arguments.profile)
        report = _load_json(arguments.report)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"ERROR: unable to read probe input: {error}")
        return 2

    result = verification_result(
        report,
        profile,
        mode=arguments.mode,
        expected_app_version=arguments.expected_app_version,
        expected_app_build=arguments.expected_app_build,
    )
    for warning in result.warnings:
        print(f"WARNING: {warning}")
    for error in result.errors:
        print(f"ERROR: {error}")

    if arguments.summary_file is not None:
        try:
            _write_summary(
                arguments.summary_file,
                report=report,
                profile=profile,
                mode=arguments.mode,
                result=result,
            )
        except OSError as error:
            print(f"ERROR: unable to write probe summary: {error}")
            return 2

    if result.errors:
        return 1

    print(
        f"System API probe satisfies profile "
        f"{profile.get('profileName', 'unknown')} in {arguments.mode} mode"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
