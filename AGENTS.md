# Repository Guidelines
##Ensure you use and update lists when completing any task.


##Refer to liquidglassdocs.txt for info on how to work with the new MacOS26 liquid glass elements.


## Project Structure & Module Organization
Core SwiftUI sources sit in `agent-beta/`; view composition is split between `MimicContentView.swift`, reusable controls in `UIComponents.swift`, and sidebar chrome in `LuxSidebarView.swift`. State and persistence live in `ChatStore.swift` (chat history JSON under `~/Library/Application Support/agent-lux/`) and `AppPrefs.swift` (`UserDefaults`-backed settings). Tooling glue resides in `LLMRunner.swift`, `StreamFilter.swift`, and `WebSearchService.swift`; consult `LiquidGlassDocs.txt` for platform material guidance. Shared assets live under `Assets.xcassets`, while the Xcode target is defined in `../agent-beta.xcodeproj`.

## Build, Test, and Development Commands
- `open ../agent-beta.xcodeproj` — launch the macOS app target in Xcode for UI work.
- `xcodebuild -project ../agent-beta.xcodeproj -scheme agent-beta -configuration Debug build` — command-line build suitable for CI smoke checks.
- `xcodebuild -project ../agent-beta.xcodeproj -scheme agent-beta -destination 'platform=macOS' test` — runs the XCTest bundle once it exists; keep CI logs in `DerivedData` out of version control.

## Coding Style & Naming Conventions
Adopt four-space indentation and trailing whitespace-free files to match existing sources. Prefer `PascalCase` types (`ChatStore`), `camelCase` methods/properties (`appendAssistant`), and namespacing with extensions for helpers. Use `guard` for early exits and keep view builders declarative; colocate small helper structs/enums with the views that use them. Run Xcode’s “Editor > Structure > Re-Indent” or `swift-format` (if installed) before submitting.

## Testing Guidelines
Unit coverage is currently absent—new logic should ship with tests under `agent-betaTests/` using `XCTest`. Focus on isolating pure components such as `ChatStore` persistence, `StreamFilter` sanitization, and prompt assembly in `PromptTemplate`. Aim for fast macOS destinations (`platform=macOS`) and prefer fixture data over hitting the network; stub `WebSearchService` when possible.

## Commit & Pull Request Guidelines
History is not bundled with this export; follow Conventional Commits (`feat: sidebar filters`, `fix: persist threads`) so downstream automation stays predictable. Keep commits focused, include rationale in the body when touching async/process code, and update docs when behavior shifts. Pull requests should link any tracking issue, describe user-visible changes, call out migration steps (preferences, storage), and attach screenshots for UI updates. Mention manual verification (build, tests, smoke run) in the PR checklist.

## Agent Runtime Setup & Safety Notes
This app is MLX-only for LLM inference. Models ship bundled in the app (no user-configured model folder). `ChatStore` writes plaintext chat history—avoid committing sample data and redact sensitive logs. `WebSearchService` reaches DuckDuckGo HTML endpoints; respect rate limits and wrap new engines behind feature flags. When working with Liquid Glass, honor macOS accessibility toggles (`Reduce Transparency`, `Increase Contrast`) before merging.

## macOS 26 UI Targeting — Do Not Remove Liquid Glass
- This app targets macOS 26 exclusively for UI. All surfaces that use translucent/background styling must use the system Liquid Glass API via SwiftUI’s `glassEffect` modifier. Do not replace or remove Liquid Glass with fallback materials (e.g., `.ultraThinMaterial`) in the UI. If a compatibility layer is needed temporarily, isolate it behind a single helper and revert back to Liquid Glass.
