import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CI_WORKFLOW_PATH = REPOSITORY_ROOT / ".github" / "workflows" / "ci.yml"


def workflow_step(name):
    lines = CI_WORKFLOW_PATH.read_text(encoding="utf-8").splitlines()
    step_start = lines.index(f"      - name: {name}")
    next_step = next(
        (
            index
            for index in range(step_start + 1, len(lines))
            if lines[index].startswith("      - name: ")
        ),
        len(lines),
    )
    return lines[step_start:next_step]


class CIWorkflowTests(unittest.TestCase):
    def test_probe_report_upload_runs_after_verification_failure(self):
        upload_step = workflow_step("Upload system API probe report")

        self.assertIn(
            "        if: ${{ always() && "
            "hashFiles('release/system-api-probe/*.json') != '' }}",
            upload_step,
        )

    def test_probe_verifier_checks_packaged_app_provenance(self):
        probe_step = workflow_step("Probe macOS system API contracts")

        self.assertIn(
            "            --expected-app-version 0.0.0-ci \\",
            probe_step,
        )
        self.assertIn(
            '            --expected-app-build "${{ github.run_number }}" \\',
            probe_step,
        )

    def test_probe_verifier_uses_explicit_hosted_policy_and_summary(self):
        probe_step = workflow_step("Probe macOS system API contracts")

        self.assertIn("            --mode hosted \\", probe_step)
        self.assertIn(
            '            --summary-file "$GITHUB_STEP_SUMMARY" \\',
            probe_step,
        )


if __name__ == "__main__":
    unittest.main()
