# Contributing

Please test with a spare Raspberry Pi and a **spare restore medium**. Changes to exclusion handling must update both the Pi helper's size calculation and its backup implementations, plus the archive `exclusions.txt`. Always add a regression test for any failure/abort handling change. Open pull requests with test results and Pi model, OS release, partition layout and macOS version (not private hostnames). Never commit backup archives, secrets, or identifiable production logs. See the included smoke test and GitHub workflow.
