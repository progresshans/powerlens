# Screenshot Assets

Public README screenshots live here.

- `popover.png` - menu bar popover while charging, with details shown
- `dashboard.png` - Dashboard Now page
- `dashboard-battery.png` - Dashboard Battery page
- `dashboard-history.png` - Dashboard History page with the 24-hour range
- `settings.png` - Settings General pane

Use real app screenshots rather than generated mockups so the README accurately
matches the current UI. Crop only the surrounding desktop or menu-bar chrome
when it distracts from the app.

## Capturing

A real Mac rarely shows every state at once, and its battery serial number must
not appear in a public image. Debug builds accept `--demo`, which replaces live
readings with a steady charging scenario and fills a temporary history database
with a month of scripted samples. The user's own history is not touched.

```bash
./script/build_and_run.sh
pkill -x PowerLens
open -n dist/PowerLens.app --args --demo -AppleLanguages '(en)' -AppleLocale en_US
```

The language and locale arguments keep text and chart dates in English without
changing saved preferences. Wait about ten seconds for the history to fill
before opening the History page.

Capture Dashboard and Settings windows with `screencapture -o -l <window-id>`.
A window covered by another window stops drawing, so bring PowerLens to the
front first. The popover's glass picks up whatever is behind it, so capture it
over a plain backdrop with `screencapture -R`, below the menu bar.
