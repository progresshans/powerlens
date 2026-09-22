import copy
import json
import sys
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from verify_system_api_probe import verification_result  # noqa: E402


class MacOS27ContractTests(unittest.TestCase):
    def setUp(self):
        # Sanitized probe from the failing Xcode 27 job, before the CI fix:
        # https://github.com/progresshans/powerlens/actions/runs/35546973487/job/106174516330
        self.report = json.loads(
            (SCRIPT_DIR / "tests/fixtures/macos-27-hosted.json").read_text()
        )
        self.profile = json.loads(
            (SCRIPT_DIR / "system-api-contracts/macos-27.json").read_text()
        )

    def test_captured_hosted_report_passes_only_its_os_profile(self):
        old_profile = json.loads(
            (SCRIPT_DIR / "system-api-contracts/macos-26.json").read_text()
        )
        self.assertIn(
            "host macOS major version does not match the profile",
            verification_result(self.report, old_profile, mode="hosted").errors,
        )
        result = verification_result(self.report, self.profile, mode="hosted")
        self.assertEqual(result.errors, ())
        self.assertTrue(result.warnings)

    def test_other_os_versions_are_not_silently_accepted(self):
        for version in ("26.7.0", "28.0.0"):
            with self.subTest(version=version):
                report = copy.deepcopy(self.report)
                report["host"]["operatingSystemVersion"] = version
                self.assertIn(
                    "host macOS major version does not match the profile",
                    verification_result(report, self.profile, mode="hosted").errors,
                )

    def test_changed_runtime_abi_is_still_rejected(self):
        report = copy.deepcopy(self.report)
        method = next(
            item for item in report["powerUI"]["methods"]
            if item["selector"] == "isOBCEngaged:"
        )
        method["actualTypeEncoding"] = "return=Q;args=@,:,^@"
        result = verification_result(report, self.profile, mode="hosted")
        self.assertTrue(any("actual ABI" in error for error in result.errors))

    def test_hosted_evidence_does_not_satisfy_physical_requirements(self):
        result = verification_result(self.report, self.profile, mode="physical")
        self.assertTrue(any("IOPowerSources" in error for error in result.errors))
        self.assertTrue(any("AppleSmartBattery" in error for error in result.errors))


if __name__ == "__main__":
    unittest.main()
