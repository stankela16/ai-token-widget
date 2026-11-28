# Contributing to Milkit

Thanks for your interest in contributing! This project aims to stay fast, minimal, 100% offline, and deeply native to macOS.

## Development Setup

1. Install Xcode (Swift 6.0+) and optionally [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
2. Clone the repository:
   ```bash
   git clone https://github.com/stankela16/milkit.git
   cd milkit
   ```
3. Build and run tests:
   ```bash
   xcodebuild test -project Milkit.xcodeproj -scheme Milkit -destination 'platform=macOS'
   ```
4. The default build uses ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`), so no Apple Developer account is required. If you want to sign locally with your own team, create a git-ignored `LocalSigning.xcconfig` file or override signing flags on the `xcodebuild` command line — never commit personal Team IDs or private workspace aliases.

## Project Guidelines

- **Zero External Dependencies**: Stick to Apple system frameworks (`SwiftUI`, `AppKit`, `Carbon`, `AVFoundation`, `SQLite3`).
- **100% Offline & Read-Only**: Never add network telemetry, remote pricing fetches, or write access to third-party tool files.
- **Zero-Lag UI**: Keep `View.body` purely declarative (no disk I/O, JSON decoding, or regexes in `body`) and ensure animations auto-pause so idle CPU stays at `0.0%`.
- **Swift 6 Strict Concurrency**: All code must compile cleanly with `SWIFT_STRICT_CONCURRENCY = complete` and zero compiler warnings.
- **Tests**: Add unit tests in `Tests/UsageEngineTests.swift` for any new parser, pricing rule, or rollup store logic.
