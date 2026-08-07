import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CI_WORKFLOW_PATH = REPOSITORY_ROOT / ".github" / "workflows" / "ci.yml"


class CIWorkflowTests(unittest.TestCase):
    def test_probe_report_upload_runs_after_verification_failure(self):
        lines = CI_WORKFLOW_PATH.read_text(encoding="utf-8").splitlines()
        step_start = lines.index("      - name: Upload system API probe report")
        next_step = next(
            index
            for index in range(step_start + 1, len(lines))
            if lines[index].startswith("      - name: ")
        )
        upload_step = lines[step_start:next_step]

        self.assertIn(
            "        if: ${{ always() && "
            "hashFiles('release/system-api-probe/*.json') != '' }}",
            upload_step,
        )


if __name__ == "__main__":
    unittest.main()
