# ControllerCore

The Swift package contains controller profiles, import/export codecs, input ownership and timing, Practice input, and the SCX1/SCX2 bridge protocol. The iPhone interface and transport share the state engine in this package.

From the repository root, run `swift test --package-path Packages/ControllerCore`. Use `bash scripts/check.sh` for the executable and app-model checks. The packet tests read the [wire fixtures](../../bridge/fixtures).
