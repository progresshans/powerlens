import copy
import json
import sys
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from verify_system_api_probe import (  # noqa: E402
    validate_report,
    verification_result,
)


PROFILE_PATH = SCRIPT_DIR / "system-api-contracts" / "macos-26.json"


def profile():
    return json.loads(PROFILE_PATH.read_text(encoding="utf-8"))


def method_contracts(contract_profile):
    methods = list(contract_profile["powerUI"]["requiredMethods"])
    for capability in contract_profile["powerUI"]["optionalCapabilities"]:
        methods.extend(capability["methods"])
    return methods


def compatible_method(contract):
    return {
        **copy.deepcopy(contract),
        "state": "compatible",
        "actualTypeEncoding": (
            f"return={contract['expectedReturnTypes'][0]};args="
            + ",".join(contract["expectedArgumentTypes"])
        ),
    }


def unavailable_key_observations(key_contracts):
    return [
        {"path": contract["path"], "state": "notAttempted"}
        for contract in key_contracts
    ]


def available_key_observations(key_contracts):
    return [
        {
            "path": contract["path"],
            "state": "available",
            "observedType": contract["allowedTypes"][0],
        }
        for contract in key_contracts
    ]


def compatible_report(contract_profile):
    hardware = contract_profile["hardware"]
    return {
        "schemaVersion": 2,
        "host": {
            "operatingSystemVersion": "26.5.2",
            "operatingSystemBuild": "25F90",
            "architecture": "arm64",
        },
        "app": {
            "version": "0.0.0-ci",
            "build": "1",
            "minimumMacOSVersion": "26.0",
        },
        "powerUI": {
            "frameworkLoaded": True,
            "clientClassFound": True,
            "methods": [
                compatible_method(contract)
                for contract in method_contracts(contract_profile)
            ],
            "runtimeObservation": {
                "subsystem": "powerUI",
                "classification": "compatible",
                "reason": "none",
            },
        },
        "ioPowerSources": {
            "infoAvailable": False,
            "sourceCount": 0,
            "firstDescriptionAvailable": False,
            "keys": unavailable_key_observations(
                hardware["ioPowerSources"]["keys"]
            ),
        },
        "externalPowerAdapter": {
            "dictionaryAvailable": False,
            "keys": unavailable_key_observations(
                hardware["externalPowerAdapter"]["keys"]
            ),
        },
        "appleSmartBattery": {
            "serviceAvailable": False,
            "propertiesReadable": False,
            "keys": unavailable_key_observations(
                hardware["appleSmartBattery"]["keys"]
            ),
        },
        "appleSMC": {
            "serviceAvailable": False,
            "connectionState": "unavailable",
            "keys": [
                {"key": contract["key"], "state": "notAttempted"}
                for contract in hardware["appleSMC"]["keys"]
            ],
        },
    }


def physical_report(contract_profile):
    report = compatible_report(contract_profile)
    hardware = contract_profile["hardware"]
    report["ioPowerSources"] = {
        "infoAvailable": True,
        "sourceCount": 1,
        "firstDescriptionAvailable": True,
        "keys": available_key_observations(
            hardware["ioPowerSources"]["keys"]
        ),
    }
    report["externalPowerAdapter"] = {
        "dictionaryAvailable": True,
        "keys": available_key_observations(
            hardware["externalPowerAdapter"]["keys"]
        ),
    }
    report["appleSmartBattery"] = {
        "serviceAvailable": True,
        "propertiesReadable": True,
        "keys": available_key_observations(
            hardware["appleSmartBattery"]["keys"]
        ),
    }
    report["appleSMC"] = {
        "serviceAvailable": True,
        "connectionState": "available",
        "keys": [
            {
                "key": contract["key"],
                "state": "available",
                "observedDataType": contract["expectedDataType"],
                "observedDataSize": contract["expectedDataSize"],
            }
            for contract in hardware["appleSMC"]["keys"]
        ],
    }
    return report


def observation(report, section, path):
    return next(item for item in report[section]["keys"] if item["path"] == path)


def method(report, selector):
    return next(
        item for item in report["powerUI"]["methods"]
        if item["selector"] == selector
    )


class VerifySystemAPIProbeTests(unittest.TestCase):
    def test_hosted_vm_hardware_absence_is_allowed_but_visible(self):
        contract_profile = profile()
        result = verification_result(
            compatible_report(contract_profile),
            contract_profile,
            mode="hosted",
        )

        self.assertEqual(result.errors, ())
        self.assertTrue(any("IOPowerSources" in item for item in result.warnings))
        self.assertTrue(
            any("AppleSmartBattery" in item for item in result.warnings)
        )

    def test_physical_mode_requires_battery_backed_providers(self):
        contract_profile = profile()
        errors = validate_report(
            compatible_report(contract_profile),
            contract_profile,
            mode="physical",
        )

        self.assertTrue(any("IOPowerSources" in item for item in errors))
        self.assertTrue(any("AppleSmartBattery" in item for item in errors))

    def test_physical_hardware_report_satisfies_physical_mode(self):
        contract_profile = profile()

        self.assertEqual(
            validate_report(
                physical_report(contract_profile),
                contract_profile,
                mode="physical",
            ),
            [],
        )

    def test_schema_versions_require_exact_integers(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        report["schemaVersion"] = True

        self.assertTrue(
            any(
                "schemaVersion: expected integer" in item
                for item in validate_report(report, contract_profile)
            )
        )

        contract_profile = profile()
        contract_profile["profileSchemaVersion"] = True
        report = compatible_report(profile())
        self.assertTrue(
            any(
                "profileSchemaVersion: expected integer" in item
                for item in validate_report(report, contract_profile)
            )
        )

        contract_profile = profile()
        report = compatible_report(contract_profile)
        contract_profile["probeSchemaVersion"] = 999
        self.assertTrue(
            any(
                "unsupported probe schema version" in item
                for item in validate_report(report, contract_profile)
            )
        )

    def test_profile_minimum_system_version_is_numeric(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        contract_profile["app"]["minimumMacOSVersion"] = "macOS 26"

        self.assertTrue(
            any(
                "expected numeric version" in item
                for item in validate_report(report, contract_profile)
            )
        )

    def test_report_and_profile_reject_unknown_structural_fields(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        report["host"]["futureField"] = "value"

        self.assertTrue(
            any(
                "host.futureField: unknown field" in item
                for item in validate_report(report, contract_profile)
            )
        )

        report = compatible_report(contract_profile)
        contract_profile["powerUI"]["futureField"] = []
        self.assertTrue(
            any(
                "powerUI.futureField: unknown field" in item
                for item in validate_report(report, contract_profile)
            )
        )

    def test_required_report_sections_and_fields_are_enforced(self):
        contract_profile = profile()
        cases = [
            ((), "host"),
            (("host",), "operatingSystemVersion"),
            (("app",), "version"),
            (("powerUI",), "runtimeObservation"),
            (("ioPowerSources",), "keys"),
            (("externalPowerAdapter",), "keys"),
            (("appleSmartBattery",), "keys"),
            (("appleSMC",), "keys"),
        ]

        for parent_path, field in cases:
            with self.subTest(path=parent_path, field=field):
                report = compatible_report(contract_profile)
                parent = report
                for component in parent_path:
                    parent = parent[component]
                del parent[field]

                self.assertTrue(validate_report(report, contract_profile))

    def test_malformed_runtime_version_fails(self):
        contract_profile = profile()

        for version in ("26.invalid", "26", "26.0.0-extra"):
            with self.subTest(version=version):
                report = compatible_report(contract_profile)
                report["host"]["operatingSystemVersion"] = version

                self.assertIn(
                    "host operating-system version must be major.minor.patch",
                    validate_report(report, contract_profile),
                )

    def test_wrong_runtime_major_fails(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        report["host"]["operatingSystemVersion"] = "27.0.0"

        self.assertTrue(
            any("major version" in item for item in validate_report(report, contract_profile))
        )

    def test_app_provenance_is_strict_and_matches_expected_values(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)

        for field, invalid in (("version", "unknown"), ("build", True)):
            with self.subTest(field=field):
                candidate = copy.deepcopy(report)
                candidate["app"][field] = invalid
                self.assertTrue(validate_report(candidate, contract_profile))

        self.assertEqual(
            validate_report(
                report,
                contract_profile,
                expected_app_version="0.0.0-ci",
                expected_app_build="1",
            ),
            [],
        )
        errors = validate_report(
            report,
            contract_profile,
            expected_app_version="other",
            expected_app_build="2",
        )
        self.assertTrue(any("version does not match" in item for item in errors))
        self.assertTrue(any("build does not match" in item for item in errors))

    def test_every_observed_hardware_key_uses_its_profile_type(self):
        contract_profile = profile()
        section_names = (
            "ioPowerSources",
            "externalPowerAdapter",
            "appleSmartBattery",
        )

        for section in section_names:
            for key_contract in contract_profile["hardware"][section]["keys"]:
                with self.subTest(section=section, path=key_contract["path"]):
                    report = physical_report(contract_profile)
                    item = observation(report, section, key_contract["path"])
                    item["observedType"] = (
                        "string"
                        if "string" not in key_contract["allowedTypes"]
                        else "number"
                    )

                    errors = validate_report(report, contract_profile)
                    self.assertTrue(
                        any(key_contract["path"] in error for error in errors)
                    )

    def test_required_hardware_keys_cannot_disappear(self):
        contract_profile = profile()
        required = (
            ("ioPowerSources", "Current Capacity"),
            ("ioPowerSources", "Power Source State"),
            ("appleSmartBattery", "Voltage"),
            ("appleSmartBattery", "Amperage"),
        )

        for section, path in required:
            with self.subTest(section=section, path=path):
                report = physical_report(contract_profile)
                item = observation(report, section, path)
                item["state"] = "keyMissing"
                del item["observedType"]

                self.assertTrue(
                    any(
                        f"{path} is required" in error
                        for error in validate_report(report, contract_profile)
                    )
                )

    def test_hardware_key_observation_set_is_exact(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        report["ioPowerSources"]["keys"].pop()
        report["externalPowerAdapter"]["keys"].append(
            {"path": "Unexpected", "state": "notAttempted"}
        )
        report["appleSmartBattery"]["keys"].append(
            copy.deepcopy(report["appleSmartBattery"]["keys"][0])
        )

        errors = validate_report(report, contract_profile)
        self.assertTrue(any("missing key observations" in item for item in errors))
        self.assertTrue(any("unexpected key observations" in item for item in errors))
        self.assertTrue(any("duplicates key path" in item for item in errors))

    def test_key_state_and_observed_type_must_be_coherent(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        report["ioPowerSources"]["keys"][0] = {
            "path": "Current Capacity",
            "state": "available",
        }
        self.assertTrue(validate_report(report, contract_profile))

        report = compatible_report(contract_profile)
        report["ioPowerSources"]["keys"][0]["observedType"] = "number"
        self.assertTrue(validate_report(report, contract_profile))

    def test_nested_observation_requires_an_available_dictionary_parent(self):
        contract_profile = profile()
        report = physical_report(contract_profile)
        parent = observation(report, "appleSmartBattery", "PowerTelemetryData")
        parent["state"] = "keyMissing"
        del parent["observedType"]

        errors = validate_report(report, contract_profile)
        self.assertTrue(any("parent is unavailable" in item for item in errors))

    def test_hardware_availability_flags_are_coherent(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        report["ioPowerSources"]["sourceCount"] = 1
        report["appleSmartBattery"]["propertiesReadable"] = True

        errors = validate_report(report, contract_profile)
        self.assertTrue(any("IOPowerSources availability" in item for item in errors))
        self.assertTrue(any("without a service" in item for item in errors))

    def test_unavailable_dictionary_cannot_report_available_keys(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        report["externalPowerAdapter"]["keys"] = available_key_observations(
            contract_profile["hardware"]["externalPowerAdapter"]["keys"]
        )

        self.assertTrue(
            any(
                "without an available container" in item
                for item in validate_report(report, contract_profile)
            )
        )

    def test_smc_type_and_size_are_validated(self):
        contract_profile = profile()

        for field, value in (
            ("observedDataType", "ui16"),
            ("observedDataSize", 8),
        ):
            with self.subTest(field=field):
                report = physical_report(contract_profile)
                report["appleSMC"]["keys"][0][field] = value
                self.assertTrue(
                    any(
                        "data type does not match" in item
                        for item in validate_report(report, contract_profile)
                    )
                )

        report = physical_report(contract_profile)
        report["appleSMC"]["keys"][0]["state"] = "typeMismatch"
        self.assertTrue(
            any(
                "incompatible data type" in item
                for item in validate_report(report, contract_profile)
            )
        )

        report = physical_report(contract_profile)
        report["appleSMC"]["keys"][0].update(
            {
                "state": "readFailed",
                "observedDataType": "ui16",
                "observedDataSize": 4,
            }
        )
        self.assertTrue(
            any(
                "data type does not match" in item
                for item in validate_report(report, contract_profile)
            )
        )

    def test_smc_service_connection_and_key_states_are_coherent(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        report["appleSMC"]["connectionState"] = "available"

        errors = validate_report(report, contract_profile)
        self.assertTrue(any("without a service" in item for item in errors))
        self.assertTrue(any("not attempted with a connection" in item for item in errors))

    def test_powerui_signature_mismatch_fails(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        observed = method(report, "isOBCEngaged:")
        observed["state"] = "incompatible"
        observed["actualTypeEncoding"] = "return=i;args=@,:,^@"

        self.assertTrue(
            any(
                "isOBCEngaged:" in item
                for item in validate_report(report, contract_profile)
            )
        )

    def test_manual_charge_selectors_are_an_all_or_none_capability(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        observed = method(report, "getMCLLimitWithError:")
        observed["state"] = "missing"
        del observed["actualTypeEncoding"]

        self.assertIn(
            "PowerUI optional capability manualChargeLimit must be all compatible or all missing",
            validate_report(report, contract_profile),
        )

    def test_optional_manual_capability_may_be_entirely_absent(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        selectors = {
            item["selector"]
            for item in contract_profile["powerUI"]["optionalCapabilities"][0][
                "methods"
            ]
        }
        for observed in report["powerUI"]["methods"]:
            if observed["selector"] in selectors:
                observed["state"] = "missing"
                del observed["actualTypeEncoding"]
        report["powerUI"]["runtimeObservation"] = {
            "subsystem": "powerUI",
            "classification": "optionalCapabilityMissing",
            "reason": "methodMissing",
            "component": "isMCLCurrentlyEnabled:",
        }

        result = verification_result(
            report, contract_profile, mode="hosted"
        )
        self.assertEqual(result.errors, ())
        self.assertTrue(
            any("manualChargeLimit" in item for item in result.warnings)
        )

    def test_optional_capability_absence_does_not_mask_runtime_failures(self):
        contract_profile = profile()
        optional_selectors = {
            item["selector"]
            for item in contract_profile["powerUI"]["optionalCapabilities"][0][
                "methods"
            ]
        }
        runtime_failures = [
            {
                "subsystem": "powerUI",
                "classification": "transientFailure",
                "reason": "queryFailed",
                "component": "isOBCEngaged:",
                "errorDomain": "PowerUISmartChargingErrorDomain",
                "errorCode": 4,
            },
            {
                "subsystem": "powerUI",
                "classification": "environmentUnavailable",
                "reason": "initializationFailed",
                "component": "PowerUISmartChargeClient",
            },
        ]

        for runtime in runtime_failures:
            with self.subTest(classification=runtime["classification"]):
                report = physical_report(contract_profile)
                for observed in report["powerUI"]["methods"]:
                    if observed["selector"] in optional_selectors:
                        observed["state"] = "missing"
                        del observed["actualTypeEncoding"]
                report["powerUI"]["runtimeObservation"] = runtime

                hosted = verification_result(
                    report, contract_profile, mode="hosted"
                )
                physical = verification_result(
                    report, contract_profile, mode="physical"
                )

                self.assertEqual(hosted.errors, ())
                self.assertTrue(
                    any(
                        "manualChargeLimit" in item
                        for item in hosted.warnings
                    )
                )
                self.assertTrue(
                    any(
                        runtime["classification"] in item
                        for item in hosted.warnings
                    )
                )
                self.assertEqual(
                    physical.errors,
                    (
                        "PowerUI runtime classification "
                        f"{runtime['classification']} is not allowed in physical mode",
                    ),
                )

    def test_runtime_observation_matches_optional_capability_availability(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        optional_selectors = {
            item["selector"]
            for item in contract_profile["powerUI"]["optionalCapabilities"][0][
                "methods"
            ]
        }
        for observed in report["powerUI"]["methods"]:
            if observed["selector"] in optional_selectors:
                observed["state"] = "missing"
                del observed["actualTypeEncoding"]

        self.assertTrue(
            any(
                "must report optionalCapabilityMissing" in item
                for item in validate_report(report, contract_profile)
            )
        )

        report = compatible_report(contract_profile)
        report["powerUI"]["runtimeObservation"] = {
            "subsystem": "powerUI",
            "classification": "optionalCapabilityMissing",
            "reason": "methodMissing",
            "component": "isMCLCurrentlyEnabled:",
        }
        self.assertTrue(
            any(
                "every capability is ABI-compatible" in item
                for item in validate_report(report, contract_profile)
            )
        )

    def test_malformed_method_entries_are_not_ignored(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        report["powerUI"]["methods"].append({"selector": "malformed"})

        self.assertTrue(validate_report(report, contract_profile))

    def test_method_observation_set_is_exact_and_unique(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        report["powerUI"]["methods"].append(
            copy.deepcopy(report["powerUI"]["methods"][0])
        )

        self.assertTrue(
            any(
                "duplicates" in item
                for item in validate_report(report, contract_profile)
            )
        )

    def test_runtime_classification_and_reason_must_be_coherent(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        report["powerUI"]["runtimeObservation"] = {
            "subsystem": "powerUI",
            "classification": "compatible",
            "reason": "queryFailed",
            "component": "isOBCEngaged:",
            "errorDomain": "PowerUI",
            "errorCode": 4,
        }

        errors = validate_report(report, contract_profile)
        self.assertTrue(any("incoherent" in item for item in errors))
        self.assertTrue(any("compatible PowerUI" in item for item in errors))

    def test_runtime_diagnostic_details_are_reason_specific(self):
        contract_profile = profile()
        cases = [
            {
                "subsystem": "powerUI",
                "classification": "transientFailure",
                "reason": "queryFailed",
                "component": "isOBCEngaged:",
            },
            {
                "subsystem": "powerUI",
                "classification": "invalidResponse",
                "reason": "invalidManualChargeLimit",
                "component": "getMCLLimitWithError:",
            },
        ]

        for runtime in cases:
            with self.subTest(reason=runtime["reason"]):
                report = compatible_report(contract_profile)
                report["powerUI"]["runtimeObservation"] = runtime
                self.assertTrue(validate_report(report, contract_profile))

    def test_hosted_transient_runtime_failure_is_warning_not_success_claim(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        report["powerUI"]["runtimeObservation"] = {
            "subsystem": "powerUI",
            "classification": "transientFailure",
            "reason": "queryFailed",
            "component": "isOBCEngaged:",
            "errorDomain": "PowerUISmartChargingErrorDomain",
            "errorCode": 4,
        }

        hosted = verification_result(report, contract_profile, mode="hosted")
        physical = verification_result(report, contract_profile, mode="physical")
        self.assertEqual(hosted.errors, ())
        self.assertTrue(any("transientFailure" in item for item in hosted.warnings))
        self.assertTrue(any("not allowed" in item for item in physical.errors))

    def test_runtime_observation_rejects_wrong_types_and_unknown_fields(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        report["powerUI"]["runtimeObservation"]["errorCode"] = True
        self.assertTrue(validate_report(report, contract_profile))

        report = compatible_report(contract_profile)
        report["powerUI"]["runtimeObservation"]["description"] = "raw error"
        self.assertTrue(validate_report(report, contract_profile))

    def test_profile_rejects_duplicate_selectors_and_key_paths(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        contract_profile["powerUI"]["requiredMethods"].append(
            copy.deepcopy(contract_profile["powerUI"]["requiredMethods"][0])
        )
        self.assertTrue(validate_report(report, contract_profile))

        contract_profile = profile()
        report = compatible_report(contract_profile)
        contract_profile["hardware"]["ioPowerSources"]["keys"].append(
            copy.deepcopy(
                contract_profile["hardware"]["ioPowerSources"]["keys"][0]
            )
        )
        self.assertTrue(validate_report(report, contract_profile))


if __name__ == "__main__":
    unittest.main()
