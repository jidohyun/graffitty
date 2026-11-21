# Reordering tabs keeps the session’s world location

## Open Bistro with labelled tabs

1. Open five tabs in one session and choose **View > World > Bistro**.
2. Select the second tab, label it BRAVO, and record its shell PID and the camera’s settled position.
3. Switch between tabs. Each tab uses the session’s current authored surface; tab order does not assign world locations.

## Move the shown tab

1. Drag BRAVO to the fourth position and release.
2. The tab bar shows BRAVO fourth and selected. Its surface and settled camera position remain unchanged; text is neither squeezed nor stretched.

## Verify the places

1. Run `echo $$` in BRAVO; its PID matches the recorded value.
2. Select the second tab, then BRAVO again. Both use the same session location.
3. Record before/after screenshots and verify no camera jump or unintended world travel. World travel belongs to switching sessions, covered by the Bistro session-flight cases.
4. Report PASS, FAIL or BLOCKED with the evidence.
