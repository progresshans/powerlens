#!/usr/bin/env python3
"""Validate a factual PowerLens system-API probe against an OS profile."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


SUPPORTED_PROFILE_SCHEMA_VERSION = 1
SANITIZED_TYPE_NAMES = {
    "array",
    "boolean",
    "data",
    "dictionary",
    "number",
    "other",
    "string",
}
SMC_ACCESS_STATES = {
    "available",
    "unavailable",
    "notAttempted",
    "keyMissing",
    "accessFailed",
    "readFailed",
}
EXPECTED_SMC_KEYS = {"SBAP", "PDTR", "PSTR"}
POWER_UI_RUNTIME_REASON_CODES = {
    "none",
    "frameworkLoadFailed",
    "clientClassMissing",
    "methodMissing",
    "methodSignatureMismatch",
    "initializationFailed",
    "queryFailed",
    "invalidManualChargeLimit",
}
POWER_UI_RUNTIME_OPTIONAL_FIELDS = {
    "component": str,
    "expectedTypeEncoding": str,
    "actualTypeEncoding": str,
    "errorDomain": str,
    "errorCode": int,
    "observedInteger": int,
}


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


def _matches_type(value: Any, expected_type: type) -> bool:
    if expected_type is int:
        return type(value) is int
    return isinstance(value, expected_type)


def _require_report_section(
    report: dict[str, Any],
    key: str,
    label: str,
    errors: list[str],
) -> dict[str, Any] | None:
    section = report.get(key)
    if not isinstance(section, dict):
        errors.append(f"{label} probe report is missing")
        return None
    return section


def _validate_section_fields(
    section: dict[str, Any],
    label: str,
    expected_fields: dict[str, type],
    errors: list[str],
) -> None:
    for field, expected_type in expected_fields.items():
        if field not in section or not _matches_type(
            section[field], expected_type
        ):
            errors.append(f"{label} probe field {field} is missing or invalid")


def _is_available_string(value: Any) -> bool:
    return (
        isinstance(value, str)
        and bool(value.strip())
        and value.strip().casefold() != "unknown"
    )


def _validate_expected_key_types(
    section: dict[str, Any],
    label: str,
    errors: list[str],
) -> None:
    values = section.get("expectedKeyTypes")
    if not isinstance(values, dict):
        return
    if not all(
        isinstance(key, str)
        and isinstance(value, str)
        and value in SANITIZED_TYPE_NAMES
        for key, value in values.items()
    ):
        errors.append(f"{label} expected-key type report is invalid")


def _validate_host_report(
    report: dict[str, Any],
    profile: dict[str, Any],
    errors: list[str],
) -> None:
    host = _require_report_section(report, "host", "host", errors)
    if host is None:
        return

    _validate_section_fields(
        host,
        "host",
        {
            "operatingSystemVersion": str,
            "operatingSystemBuild": str,
            "architecture": str,
        },
        errors,
    )

    version = host.get("operatingSystemVersion")
    if isinstance(version, str):
        try:
            major = int(version.split(".", maxsplit=1)[0])
        except ValueError:
            errors.append("host operating-system version is invalid")
        else:
            if major != profile.get("hostMacOSMajorVersion"):
                errors.append(
                    "host macOS major version does not match the contract profile"
                )

    build = host.get("operatingSystemBuild")
    if isinstance(build, str) and not _is_available_string(build):
        errors.append("host operating-system build is empty or unknown")

    architecture = host.get("architecture")
    if (
        isinstance(architecture, str)
        and architecture != profile.get("architecture")
    ):
        errors.append("host architecture does not match the contract profile")


def _validate_app_report(
    report: dict[str, Any],
    profile: dict[str, Any],
    errors: list[str],
    *,
    expected_version: str | None,
    expected_build: str | None,
) -> None:
    app = _require_report_section(report, "app", "app", errors)
    if app is None:
        return

    _validate_section_fields(
        app,
        "app",
        {
            "version": str,
            "build": str,
            "minimumMacOSVersion": str,
        },
        errors,
    )

    version = app.get("version")
    if isinstance(version, str):
        if not _is_available_string(version):
            errors.append("packaged app version is empty or unknown")
        elif expected_version is not None and version != expected_version:
            errors.append("packaged app version does not match the expected value")

    build = app.get("build")
    if isinstance(build, str):
        if not _is_available_string(build):
            errors.append("packaged app build is empty or unknown")
        elif expected_build is not None and build != expected_build:
            errors.append("packaged app build does not match the expected value")

    minimum_version = app.get("minimumMacOSVersion")
    if (
        isinstance(minimum_version, str)
        and minimum_version != profile.get("minimumMacOSVersion")
    ):
        errors.append("packaged app minimum macOS version is incorrect")


def _validate_powerui_runtime_observation(
    observation: dict[str, Any],
    profile: dict[str, Any],
    errors: list[str],
) -> None:
    if observation.get("subsystem") != "powerUI":
        errors.append(
            "PowerUI runtime observation subsystem is missing or invalid"
        )

    classification = observation.get("classification")
    if not isinstance(classification, str):
        errors.append(
            "PowerUI runtime observation classification is missing or invalid"
        )
    else:
        allowed = profile.get("allowedPowerUIRuntimeClassifications")
        if not isinstance(allowed, list) or not all(
            isinstance(value, str) for value in allowed
        ):
            errors.append(
                "contract profile has invalid allowed PowerUI runtime classifications"
            )
        elif classification not in allowed:
            errors.append(
                "PowerUI runtime observation indicates a contract mismatch"
            )

    reason = observation.get("reason")
    if (
        not isinstance(reason, str)
        or reason not in POWER_UI_RUNTIME_REASON_CODES
    ):
        errors.append("PowerUI runtime observation reason is missing or invalid")

    for field, expected_type in POWER_UI_RUNTIME_OPTIONAL_FIELDS.items():
        if field in observation and not _matches_type(
            observation[field], expected_type
        ):
            errors.append(f"PowerUI runtime observation field {field} is invalid")


def _validate_hardware_reports(
    report: dict[str, Any],
    errors: list[str],
) -> None:
    sections = [
        (
            "ioPowerSources",
            "IOPowerSources",
            {
                "infoAvailable": bool,
                "sourceCount": int,
                "firstDescriptionAvailable": bool,
                "expectedKeyTypes": dict,
            },
        ),
        (
            "externalPowerAdapter",
            "external power adapter",
            {
                "dictionaryAvailable": bool,
                "expectedKeyTypes": dict,
            },
        ),
        (
            "appleSmartBattery",
            "AppleSmartBattery",
            {
                "serviceAvailable": bool,
                "propertiesReadable": bool,
                "expectedKeyTypes": dict,
            },
        ),
    ]

    for key, label, expected_fields in sections:
        section = _require_report_section(report, key, label, errors)
        if section is None:
            continue
        _validate_section_fields(section, label, expected_fields, errors)
        _validate_expected_key_types(section, label, errors)

    smc = _require_report_section(report, "appleSMC", "AppleSMC", errors)
    if smc is None:
        return
    _validate_section_fields(
        smc,
        "AppleSMC",
        {
            "serviceAvailable": bool,
            "connectionState": str,
            "keys": list,
        },
        errors,
    )
    if smc.get("connectionState") not in SMC_ACCESS_STATES:
        errors.append("AppleSMC connection state is invalid")

    key_reports = smc.get("keys")
    if not isinstance(key_reports, list):
        return
    reported_keys: list[str] = []
    for key_report in key_reports:
        if not isinstance(key_report, dict):
            errors.append("AppleSMC key report is invalid")
            continue
        key = key_report.get("key")
        state = key_report.get("state")
        if not isinstance(key, str) or state not in SMC_ACCESS_STATES:
            errors.append("AppleSMC key report is invalid")
            continue
        reported_keys.append(key)

    if len(reported_keys) != len(EXPECTED_SMC_KEYS) or set(
        reported_keys
    ) != EXPECTED_SMC_KEYS:
        errors.append("AppleSMC key reports are incomplete")


def _validate_powerui_method(
    contract: Any,
    methods_by_selector: dict[str, dict[str, Any]],
    errors: list[str],
    *,
    optional: bool,
) -> None:
    if not isinstance(contract, dict):
        errors.append("contract profile contains an invalid method entry")
        return
    selector = contract.get("selector")
    if not isinstance(selector, str):
        errors.append("contract profile contains a method without a selector")
        return
    method = methods_by_selector.get(selector)
    if method is None:
        errors.append(f"PowerUI method report is missing selector {selector}")
        return
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

    state = method.get("state")
    # Optional describes runtime availability, not report/schema optionality:
    # the probe entry must exist, and an implementation must match when present.
    if optional and state == "missing":
        if method.get("actualTypeEncoding") is not None:
            errors.append(
                f"PowerUI optional selector {selector} has an invalid missing-state ABI"
            )
        return
    if state != "compatible":
        errors.append(f"PowerUI selector {selector} is not ABI-compatible")
        return
    if method.get("actualTypeEncoding") not in _actual_encodings(contract):
        errors.append(
            f"PowerUI selector {selector} actual ABI does not match the profile"
        )


def validate_report(
    report: dict[str, Any],
    profile: dict[str, Any],
    *,
    expected_app_version: str | None = None,
    expected_app_build: str | None = None,
) -> list[str]:
    errors: list[str] = []

    profile_schema_version = profile.get("profileSchemaVersion")
    if (
        not _matches_type(profile_schema_version, int)
        or profile_schema_version != SUPPORTED_PROFILE_SCHEMA_VERSION
    ):
        errors.append("unsupported contract profile schema version")
        return errors

    report_schema_version = report.get("schemaVersion")
    profile_probe_schema_version = profile.get("probeSchemaVersion")
    if (
        not _matches_type(report_schema_version, int)
        or not _matches_type(profile_probe_schema_version, int)
        or report_schema_version != profile_probe_schema_version
    ):
        errors.append("probe schema version does not match the contract profile")

    _validate_host_report(report, profile, errors)
    _validate_app_report(
        report,
        profile,
        errors,
        expected_version=expected_app_version,
        expected_build=expected_app_build,
    )

    # Hardware access may legitimately be unavailable on a hosted runner, but
    # every factual probe section must still be present and structurally valid.
    _validate_hardware_reports(report, errors)

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
    methods_by_selector: dict[str, dict[str, Any]] = {}
    for method in methods:
        if not isinstance(method, dict) or not isinstance(
            method.get("selector"), str
        ):
            continue
        selector = method["selector"]
        if selector in methods_by_selector:
            errors.append(f"PowerUI method report duplicates selector {selector}")
            continue
        methods_by_selector[selector] = method

    required_methods = profile.get("requiredPowerUIMethods")
    if not isinstance(required_methods, list):
        errors.append("contract profile has no required PowerUI methods")
        required_methods = []

    for contract in required_methods:
        _validate_powerui_method(
            contract,
            methods_by_selector,
            errors,
            optional=False,
        )

    optional_methods = profile.get("optionalPowerUIMethods")
    if not isinstance(optional_methods, list):
        errors.append("contract profile has no optional PowerUI methods")
        optional_methods = []

    for contract in optional_methods:
        _validate_powerui_method(
            contract,
            methods_by_selector,
            errors,
            optional=True,
        )

    runtime_observation = power_ui.get("runtimeObservation")
    if not isinstance(runtime_observation, dict):
        errors.append("PowerUI runtime observation is missing")
    else:
        _validate_powerui_runtime_observation(
            runtime_observation,
            profile,
            errors,
        )

    # Hardware-backed fields are deliberately observation-only. A hosted VM
    # may have no battery, external adapter, AppleSmartBattery, or AppleSMC.
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--expected-app-version")
    parser.add_argument("--expected-app-build")
    parser.add_argument("report", type=Path)
    arguments = parser.parse_args()

    try:
        profile = _load_json(arguments.profile)
        report = _load_json(arguments.report)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"ERROR: unable to read probe input: {error}")
        return 2

    errors = validate_report(
        report,
        profile,
        expected_app_version=arguments.expected_app_version,
        expected_app_build=arguments.expected_app_build,
    )
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
