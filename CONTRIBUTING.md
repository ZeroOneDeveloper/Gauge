# Contributing to Gauge

Gauge is a native SwiftUI macOS app with no third-party Swift package dependencies.
You need macOS 14 or later and a Swift 6 toolchain (Xcode or Command Line Tools).

```sh
git clone https://github.com/ZeroOneDeveloper/Gauge.git
cd Gauge
swift build
swift test
./scripts/build.sh
open dist/Gauge.app
```

Open an issue for a bug or feature proposal, or submit a pull request. Keep changes
focused and describe the resulting behavior and how you verified it. Run
`swift test` when changing parsing, authentication, storage, or quota calculations.
For layout changes, build and visually verify the dashboard and menu popover.

Use synthetic accounts and tokens in tests. Never include local account files,
personal usage screenshots, tokens, signing keys, or credentials in a contribution.
See [SECURITY.md](SECURITY.md) for private vulnerability reports.

Release instructions are in [docs/RELEASING.md](docs/RELEASING.md).
