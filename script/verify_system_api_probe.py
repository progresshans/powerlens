#!/usr/bin/env python3
"""Validate a factual PowerLens system-API probe against an OS profile."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


SUPPORTED_PROFILE_SCHEMA_VERSION = 1


def _load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def _actual_encodings(contract: dict[str, Any]) -> set[str]:
    arguments = contract.get("expectedArgumentTypes")
    returns = contract.get("expectedReturnTypes")
    if not isinstance(arguments, list) or not isinstance(returns, list):
        return set()
    argument_text = ",".join(str(value) for value in arguments)
    return {
        f"return={return_type};args={argument_text}"
        for return_type in returns
    }


def validate_report(
    report: dict[str, Any],
    profile: dict[str, Any],
) -> list[str]:
    errors: list[str] = []

    if profile.get("profileSchemaVersion") != SUPPORTED_PROFILE_SCHEMA_VERSION:
        errors.append("unsupported contract profile schema version")
        return errors

    if report.get("schemaVersion") != profile.get("probeSchemaVersion"):
        errors.append("probe schema version does not match the contract profile")

    host = report.get("host")
    if not isinstance(host, dict):
        errors.append("probe host report is missing")
    else:
        version = host.get("operatingSystemVersion")
        try:
            major = int(str(version).split(".", maxsplit=1)[0])
        except (TypeError, ValueError):
            errors.append("host operating-system version is invalid")
        else:
            if major != profile.get("hostMacOSMajorVersion"):
                errors.append(
                    "host macOS major version does not match the contract profile"
                )
        if host.get("architecture") != profile.get("architecture"):
            errors.append("host architecture does not match the contract profile")

    app = report.get("app")
    if not isinstance(app, dict):
        errors.append("probe app report is missing")
    elif app.get("minimumMacOSVersion") != profile.get("minimumMacOSVersion"):
        errors.append("packaged app minimum macOS version is incorrect")

    power_ui = report.get("powerUI")
    if not isinstance(power_ui, dict):
        errors.append("PowerUI probe report is missing")
        return errors

    if power_ui.get("frameworkLoaded") is not True:
        errors.append("PowerUI framework did not load")
    if power_ui.get("clientClassFound") is not True:
        errors.append("PowerUISmartChargeClient was not found")

    methods = power_ui.get("methods")
    if not isinstance(methods, list):
        errors.append("PowerUI method report is missing")
        methods = []
    methods_by_selector = {
        method.get("selector"): method
        for method in methods
        if isinstance(method, dict) and isinstance(method.get("selector"), str)
    }

    required_methods = profile.get("requiredPowerUIMethods")
    if not isinstance(required_methods, list):
        errors.append("contract profile has no required PowerUI methods")
        required_methods = []

    for contract in required_methods:
        if not isinstance(contract, dict):
            errors.append("contract profile contains an invalid method entry")
            continue
        selector = contract.get("selector")
        method = methods_by_selector.get(selector)
        if method is None:
            errors.append(f"PowerUI method report is missing selector {selector}")
            continue
        if method.get("dispatch") != contract.get("dispatch"):
            errors.append(f"PowerUI selector {selector} has the wrong dispatch kind")
        if method.get("expectedReturnTypes") != contract.get(
            "expectedReturnTypes"
        ):
            errors.append(f"PowerUI selector {selector} changed expected return ABI")
        if method.get("expectedArgumentTypes") != contract.get(
            "expectedArgumentTypes"
        ):
            errors.append(f"PowerUI selector {selector} changed expected argument ABI")
        if method.get("state") != "compatible":
            errors.append(f"PowerUI selector {selector} is not ABI-compatible")
        if method.get("actualTypeEncoding") not in _actual_encodings(contract):
            errors.append(
                f"PowerUI selector {selector} actual ABI does not match the profile"
            )

    runtime_observation = power_ui.get("runtimeObservation")
    if not isinstance(runtime_observation, dict):
        errors.append("PowerUI runtime observation is missing")
    else:
        allowed = profile.get("allowedPowerUIRuntimeClassifications", [])
        if runtime_observation.get("classification") not in allowed:
            errors.append("PowerUI runtime observation indicates a contract mismatch")

    # Hardware-backed fields are deliberately observation-only. A hosted VM
    # may have no battery, external adapter, AppleSmartBattery, or AppleSMC.
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("report", type=Path)
    arguments = parser.parse_args()

    try:
        profile = _load_json(arguments.profile)
        report = _load_json(arguments.report)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"ERROR: unable to read probe input: {error}")
        return 2

    errors = validate_report(report, profile)
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1

    print(
        f"System API probe satisfies profile {profile.get('profileName', 'unknown')}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
