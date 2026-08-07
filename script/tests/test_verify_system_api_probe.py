import copy
import json
import sys
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from verify_system_api_probe import validate_report  # noqa: E402


PROFILE_PATH = SCRIPT_DIR / "system-api-contracts" / "macos-26.json"


def profile():
    return json.loads(PROFILE_PATH.read_text(encoding="utf-8"))


def compatible_report(contract_profile):
    methods = []
    for contract_group in (
        contract_profile["requiredPowerUIMethods"],
        contract_profile["optionalPowerUIMethods"],
    ):
        for contract in contract_group:
            methods.append(
                {
                    **copy.deepcopy(contract),
                    "state": "compatible",
                    "actualTypeEncoding": (
                        f"return={contract['expectedReturnTypes'][0]};args="
                        + ",".join(contract["expectedArgumentTypes"])
                    ),
                }
            )

    return {
        "schemaVersion": 1,
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
            "methods": methods,
            "runtimeObservation": {
                "subsystem": "powerUI",
                "classification": "environmentUnavailable",
                "reason": "initializationFailed",
            },
        },
        "ioPowerSources": {
            "infoAvailable": False,
            "sourceCount": 0,
            "firstDescriptionAvailable": False,
            "expectedKeyTypes": {},
        },
        "externalPowerAdapter": {
            "dictionaryAvailable": False,
            "expectedKeyTypes": {},
        },
        "appleSmartBattery": {
            "serviceAvailable": False,
            "propertiesReadable": False,
            "expectedKeyTypes": {},
        },
        "appleSMC": {
            "serviceAvailable": False,
            "connectionState": "unavailable",
            "keys": [
                {"key": "SBAP", "state": "notAttempted"},
                {"key": "PDTR", "state": "notAttempted"},
                {"key": "PSTR", "state": "notAttempted"},
            ],
        },
    }


class VerifySystemAPIProbeTests(unittest.TestCase):
    def test_hosted_vm_hardware_absence_is_allowed(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)

        self.assertEqual(validate_report(report, contract_profile), [])

    def test_powerui_signature_mismatch_fails(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        method = next(
            item
            for item in report["powerUI"]["methods"]
            if item["selector"] == "isOBCEngaged:"
        )
        method["state"] = "incompatible"
        method["actualTypeEncoding"] = "return=i;args=@,:,^@"

        errors = validate_report(report, contract_profile)

        self.assertTrue(any("isOBCEngaged:" in error for error in errors))

    def test_optional_manual_selectors_may_be_absent(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        optional_selectors = {
            contract["selector"]
            for contract in contract_profile["optionalPowerUIMethods"]
        }
        for method in report["powerUI"]["methods"]:
            if method["selector"] in optional_selectors:
                method["state"] = "missing"
                method["actualTypeEncoding"] = None
        report["powerUI"]["runtimeObservation"]["classification"] = (
            "optionalCapabilityMissing"
        )

        self.assertEqual(validate_report(report, contract_profile), [])

    def test_optional_selector_incompatible_abi_fails(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        method = next(
            item
            for item in report["powerUI"]["methods"]
            if item["selector"] == "isMCLCurrentlyEnabled:"
        )
        method["state"] = "incompatible"
        method["actualTypeEncoding"] = "return=i;args=@,:,^@"

        errors = validate_report(report, contract_profile)

        self.assertTrue(
            any("isMCLCurrentlyEnabled:" in error for error in errors)
        )

    def test_optional_selector_must_still_have_a_probe_entry(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        report["powerUI"]["methods"] = [
            method
            for method in report["powerUI"]["methods"]
            if method["selector"] != "getMCLLimitWithError:"
        ]

        errors = validate_report(report, contract_profile)

        self.assertIn(
            "PowerUI method report is missing selector getMCLLimitWithError:",
            errors,
        )

    def test_missing_framework_fails(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        report["powerUI"]["frameworkLoaded"] = False

        errors = validate_report(report, contract_profile)

        self.assertIn("PowerUI framework did not load", errors)

    def test_wrong_runtime_major_fails(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        report["host"]["operatingSystemVersion"] = "27.0.0"

        errors = validate_report(report, contract_profile)

        self.assertTrue(any("major version" in error for error in errors))

    def test_contract_mismatch_runtime_classification_fails(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        report["powerUI"]["runtimeObservation"]["classification"] = (
            "contractMismatch"
        )

        errors = validate_report(report, contract_profile)

        self.assertTrue(any("runtime observation" in error for error in errors))

    def test_invalid_response_runtime_classification_fails(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        report["powerUI"]["runtimeObservation"]["classification"] = (
            "invalidResponse"
        )

        errors = validate_report(report, contract_profile)

        self.assertTrue(any("runtime observation" in error for error in errors))

    def test_hardware_probe_sections_are_required(self):
        contract_profile = profile()
        expected_errors = {
            "ioPowerSources": "IOPowerSources probe report is missing",
            "externalPowerAdapter": (
                "external power adapter probe report is missing"
            ),
            "appleSmartBattery": "AppleSmartBattery probe report is missing",
            "appleSMC": "AppleSMC probe report is missing",
        }

        for section, expected_error in expected_errors.items():
            with self.subTest(section=section):
                report = compatible_report(contract_profile)
                del report[section]

                errors = validate_report(report, contract_profile)

                self.assertIn(expected_error, errors)

    def test_hardware_probe_section_shapes_are_validated(self):
        contract_profile = profile()
        report = compatible_report(contract_profile)
        report["ioPowerSources"]["sourceCount"] = "0"
        report["appleSMC"]["keys"] = []

        errors = validate_report(report, contract_profile)

        self.assertIn(
            "IOPowerSources probe field sourceCount is missing or invalid",
            errors,
        )
        self.assertIn("AppleSMC key reports are incomplete", errors)


if __name__ == "__main__":
    unittest.main()
