import plistlib
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
INFO_PLIST_PATH = REPOSITORY_ROOT / "Packaging" / "Info.plist"
RESOURCES_PATH = REPOSITORY_ROOT / "Sources" / "PowerLens" / "Resources"


class InfoPlistLocalizationTests(unittest.TestCase):
    def test_declared_localizations_match_bundled_strings(self):
        # App strings live in the SwiftPM resource bundle, so macOS localizes
        # system menus and panels only for the languages declared here.
        with INFO_PLIST_PATH.open("rb") as plist_file:
            info = plistlib.load(plist_file)
        bundled = {path.stem for path in RESOURCES_PATH.glob("*.lproj")}

        self.assertEqual(set(info["CFBundleLocalizations"]), bundled)
        self.assertIn(info["CFBundleDevelopmentRegion"], bundled)


if __name__ == "__main__":
    unittest.main()
