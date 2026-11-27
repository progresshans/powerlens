import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from generate_update_notes import main, update_notes  # noqa: E402


REPOSITORY = "progresshans/powerlens"
PULL = "https://github.com/progresshans/powerlens/pull"


def linked(line):
    return update_notes(line, REPOSITORY).rstrip("\n")


class LinkTests(unittest.TestCase):
    def test_contributor_line_links_the_person_and_every_pull_request(self):
        self.assertEqual(
            linked("- @fordpiggy1 made their first contributions (#60, #63)."),
            "- [@fordpiggy1](https://github.com/fordpiggy1) made their first "
            f"contributions ([#60]({PULL}/60), [#63]({PULL}/63)).",
        )

    def test_mention_at_the_start_and_end_of_a_sentence(self):
        self.assertEqual(
            linked("@first-name fixed it. Thanks, @second."),
            "[@first-name](https://github.com/first-name) fixed it. "
            "Thanks, [@second](https://github.com/second).",
        )

    def test_text_that_only_looks_like_a_mention_stays(self):
        for line in (
            "Write to security@example.com.",
            "Ask @example/maintainers.",
            "The icon@2x.png asset changed.",
            "Install @types/node.",
            "See @name.example for details.",
            "An @under_score name is not a GitHub name.",
            "An @trailing- hyphen is not a GitHub name.",
            "An @" + "a" * 40 + " name is too long.",
        ):
            with self.subTest(line=line):
                self.assertEqual(linked(line), line)

    def test_text_that_only_looks_like_a_number_stays(self):
        for line in (
            "## Fixed",
            "It&#39;s fixed.",
            "The color is abc#123.",
            "Step #1a is gone.",
            "Open docs/#12 instead.",
        ):
            with self.subTest(line=line):
                self.assertEqual(linked(line), line)

    def test_code_stays_as_written(self):
        for line in (
            "- Adopt `@MainActor` and `#60` in `code (#61)`.",
            "- Double ticks: ``@name and `#62` inside``.",
        ):
            with self.subTest(line=line):
                self.assertEqual(linked(line), line)

    def test_code_fence_stays_as_written(self):
        notes = "Before #1.\n\n```swift\n@MainActor // #2\n```\n\nAfter #3.\n"
        self.assertEqual(
            update_notes(notes, REPOSITORY),
            f"Before [#1]({PULL}/1).\n\n```swift\n@MainActor // #2\n```\n\n"
            f"After [#3]({PULL}/3).\n",
        )

    def test_existing_links_and_urls_stay_as_written(self):
        for line in (
            "- See [#60](https://example.com/60) and [@name](https://example.com).",
            "- See https://example.com/page#12 and https://example.com/@name.",
            "- See <https://example.com/#13>.",
            "- An image: ![#14 @name](https://example.com/a.png).",
        ):
            with self.subTest(line=line):
                self.assertEqual(linked(line), line)

    def test_text_next_to_code_is_still_linked(self):
        self.assertEqual(
            linked("- `code` (#60) by @name"),
            f"- `code` ([#60]({PULL}/60)) by [@name](https://github.com/name)",
        )


class DocumentTests(unittest.TestCase):
    def test_title_is_dropped_and_sections_are_kept(self):
        notes = (
            "# PowerLens 1.2.3\n\n"
            "## Fixed\n\n"
            "- A fix.\n\n"
            "## Contributors\n\n"
            "- @name helped (#7).\n"
        )
        self.assertEqual(
            update_notes(notes, REPOSITORY),
            "## Fixed\n\n"
            "- A fix.\n\n"
            "## Contributors\n\n"
            f"- [@name](https://github.com/name) helped ([#7]({PULL}/7)).\n",
        )

    def test_alpha_notice_is_kept(self):
        notes = "# PowerLens 1.2.3-alpha.1\n\n> Alpha preview: it may change.\n\nA note.\n"
        self.assertEqual(
            update_notes(notes, REPOSITORY),
            "> Alpha preview: it may change.\n\nA note.\n",
        )

    def test_notes_without_a_title_are_kept_whole(self):
        self.assertEqual(update_notes("## Fixed\n\n- A fix.\n", REPOSITORY), "## Fixed\n\n- A fix.\n")

    def test_notes_with_only_a_title_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "no content"):
            update_notes("# PowerLens 1.2.3\n\n", REPOSITORY)

    def test_invalid_repository_is_rejected(self):
        for repository in ("", "powerlens", "owner/name/extra", "owner name/repo", "-owner/repo"):
            with self.subTest(repository=repository):
                with self.assertRaisesRegex(ValueError, "invalid repository"):
                    update_notes("A note.\n", repository)


class CommandTests(unittest.TestCase):
    def test_command_writes_the_update_notes(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "release-notes.md"
            destination = Path(directory) / "nested" / "update-notes.md"
            source.write_text("# PowerLens 1.2.3\n\n- A fix (#7).\n", encoding="utf-8")

            self.assertEqual(main([str(source), str(destination), REPOSITORY]), 0)
            self.assertEqual(
                destination.read_text(encoding="utf-8"),
                f"- A fix ([#7]({PULL}/7)).\n",
            )

    def test_command_fails_without_writing_empty_notes(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "release-notes.md"
            destination = Path(directory) / "update-notes.md"
            source.write_text("# PowerLens 1.2.3\n", encoding="utf-8")

            self.assertEqual(main([str(source), str(destination), REPOSITORY]), 1)
            self.assertFalse(destination.exists())

    def test_command_requires_three_arguments(self):
        self.assertEqual(main(["only-one"]), 2)


if __name__ == "__main__":
    unittest.main()
