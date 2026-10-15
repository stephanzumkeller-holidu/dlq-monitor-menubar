# dlq-monitor-menubar

macOS menu bar app (AppKit `NSStatusItem` + `NSPopover` hosting SwiftUI, Swift 6, SwiftPM, macOS 14+) showing message counts and
oldest-message age of the SQS dead-letter queues whose names match a regex; other queues are deliberately not
shown. It is a general tool with generic defaults: the `default` profile, the profile's own region
(`AWSConfigFile`), a DLQ pattern for common DLQ names (`QueueNaming.defaultDLQPattern`) and no tag pattern. Keep
company- or account-specific values out of the code; they belong in the user's settings (`MonitorSettings`). Select DLQs and read names only through `QueueNaming`
(`settings.naming`). Its DLQ regex and optional tag regex are user settings, so never test for `_dlq` or a
prefix directly. There is no queue prefix: `ListQueues` lists the account and the DLQ regex filters it.

## Build constraints

- Must build with the **Command Line Tools alone**, no Xcode. Consequences:
  - No `@State`: in the macOS 27 SDK it is a macro whose plugin (`SwiftUIMacros`) only ships with Xcode. Keep
    view state in `@Observable` classes (`PopoverState`) and use `@Bindable` / `Bindable(x).prop`.
  - Tests use swift-testing; its macro plugin sits in a directory SwiftPM does not search, so run them with
    `make test`, which passes `-plugin-path`.
- The only dependency is the official AWS SDK for Swift (`awslabs/aws-sdk-swift`, pinned in `Package.resolved`).
  Add no others. Its first resolve downloads about 1 GB and takes minutes; its first build about two.

## AWS access

`AWSClients` builds `SQSClient` and `CloudWatchClient` of the AWS SDK for Swift. Credentials come from
`ProfileAWSCredentialIdentityResolver(profileName:)`, which reads `~/.aws/config` like the AWS CLI
(`credential_process`, `source_profile` + `role_arn`, SSO). It resolves the whole chain on every call, so it is
wrapped in `CachedAWSCredentialIdentityResolver` (15 minutes); credentials live only in memory. Gotchas:

- The SDK runs `credential_process` through the shell with the app's PATH. `Entry.main` calls
  `LoginShell.adoptPATH()` first, or a Finder launch cannot find tools from the user's shell profile.
- SDK errors have useless `localizedDescription`s; show `AWSErrorMessage.describe(error)`.
- `QueueService.concurrentMap` runs the first call alone, so parallel calls do not each resolve credentials
  (and each ask for MFA) before the cache is filled.
- Use the `…ClientConfig` structs; the `…ClientConfiguration` classes are deprecated. Their initializers need
  the explicit type: `.init(…)` is ambiguous.
- There is no sign-in button: the user signs in the way the profile expects.

## Why not `MenuBarExtra`

The SwiftUI `MenuBarExtra(.window)` window did not track its content's size: it rendered taller than the
content, with empty transparent glass above and below. `StatusItemController` uses an `NSPopover` whose
`NSHostingController` has `sizingOptions = [.preferredContentSize]`, so the popover always fits its content.

## Layout

- `Sources/DLQMonitorCore`: `AWSClients` (SDK clients, credentials, error messages), `QueueService` (SQS counts + CloudWatch ages),
  `QueueNaming` (DLQ regex, service tag), `LoginShell` (PATH for Finder launches), formatting. No AppKit/SwiftUI; unit-tested in `Tests/DLQMonitorCoreTests`.
- `Sources/DLQMonitor`: `StatusItemController` (menu bar item, popover), `QueueMonitor` (schedule, refresh, deltas), `MonitorSettings`
  (UserDefaults), SwiftUI views, and the `--once` CLI mode in `DLQMonitorApp.swift`.

## Verifying changes

`make test`, then `make once` for a live end-to-end read. The bare binary and the app share the UserDefaults
domain `DLQMonitor` (the bundle id is the executable name on purpose), so `make once` sees the app's settings. It reads its argument domain too, so a setting
can be tried without storing it:
`"$(swift build --show-bin-path)/DLQMonitor" --once -dlqPattern '_dlq$'`. To reproduce the minimal
environment a Finder launch gets, run
`env -i HOME="$HOME" "build/DLQ Monitor.app/Contents/MacOS/DLQMonitor" --once`.

## Queue rows

`QueueRow` is a plain `Button` (click opens the console, ⌥-click copies the name) next to the action icons,
not around them: buttons nested in a button do not get their clicks. The icons keep their space when hidden
(opacity, not `if`), so the count and age columns do not shift on hover.

## Cost guard

CloudWatch `GetMetricData` is billed per metric. Query ages only for non-empty queues; take counts from SQS.
