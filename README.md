# DLQ Monitor

A macOS menu bar app that watches the SQS dead-letter queues whose names match a configurable regular
expression. It shows how many messages each queue holds, how old the oldest one is, and whether the count
changed since the last refresh. No AWS console tab to keep signed in and refreshed.

```
Menu bar:  ⚠ 2,083

DLQ Monitor         default · us-east-1 · (dlq|dead[-_]?letter([-_]?queue)?)$  ⟳
DEAD-LETTER QUEUES                                     2,083 messages in 2 of 36
  orders-payment-failed-dlq                           ▲ 12      2,081     4d 19h
  invoices-dlq.fifo                                                 2    10h 24m
  ▸ 34 empty DLQs
────────────────────────────────────────────────────────────────────────────────
Refresh  [ 1m | 5m | 15m | 30m | Manual ]
                                                                Updated 11:27:03
☐ Launch at login                                              Settings…   Quit
```

- **Icon:** plain tray when every DLQ is empty, orange when one holds messages, red when one grew since the
  previous refresh or its oldest message is older than the warning age (default 72 h), grey when the last
  refresh failed. The number is the total across all DLQs.
- **Click a queue** to open it in the AWS console; **⌥-click** copies its name;
  right-click for more.
- **Row icons**, shown while the pointer is over a row: copy the queue name, open the queue in the AWS console.

## Install

Requirements: macOS 14+, the Xcode Command Line Tools (`xcode-select --install`; full Xcode not needed),
and an AWS profile in `~/.aws/config` that reaches the AWS account owning the queues.

The first build downloads the AWS SDK for Swift (about 1 GB of git history, several minutes) and compiles it
(about two minutes); later builds are quick.

```bash
make install     # builds "DLQ Monitor.app", copies it to ~/Applications and starts it
```

Tick *Launch at login* in the popover to keep it running.

The app is built on your own Mac rather than downloaded, so Gatekeeper does not block it even though it is
only ad-hoc signed. There are no prebuilt downloads and no auto-update. To update, pull and install again;
`make install` quits the running app, replaces it and starts the new build:

```bash
git pull && make install
```

## AWS access

The app calls SQS and CloudWatch with the official [AWS SDK for Swift](https://github.com/awslabs/aws-sdk-swift).
It reads the profile from `~/.aws/config` and `~/.aws/credentials` the way the AWS CLI does, so whatever works
for `aws --profile <name>` works here: static keys, `credential_process`, role assumption via `source_profile` +
`role_arn`, and SSO. The AWS CLI itself is not needed.

The credentials stay in the app's memory for at most 15 minutes and are never written to disk; then the profile
is resolved again, which runs its `credential_process` and assumes the role anew. The first call of a refresh
runs alone, so a credential source that asks for MFA asks only once.

When no credentials can be obtained, the popover says so. Sign in the way the profile expects; the next refresh
picks the new session up.

Apps started from Finder or at login get a minimal PATH, which may not contain the profile's
`credential_process` command. So at launch the app takes PATH from your login shell, as your shell profile sets
it up.

Read-only permissions needed: `sqs:ListQueues`, `sqs:GetQueueAttributes`,
`cloudwatch:GetMetricData`.

Profile, region and warning age can be changed under *Settings…*. The defaults are the AWS profile `default`
and an empty region, which means the profile's own `region` from `~/.aws/config`, as with the AWS CLI.

## Queue naming

Two regular expressions under *Settings…* decide how queue names are read. Both take effect on *Apply*. A
pattern that does not compile is flagged in red below its field, and the app keeps using the last valid one.

| Setting | Default | Meaning |
|---|---|---|
| DLQ pattern | `(?i)(dlq\|dead[-_]?letter([-_]?queue)?)(\.fifo)?$` | A queue whose name matches is monitored; every other queue in the account and region is ignored. The default takes names ending in `dlq`, `dead-letter`, `deadletterqueue` and the like, in any case, FIFO queues included. Narrow it to your own queues, e.g. `^orders-.*-dlq$`. |
| Tag pattern | empty | Matched against the full queue name. The named group `(?<service>…)` becomes the tag, and the optional `(?<purpose>…)` is shown instead of the full name. |

A name the tag pattern does not match, or any name when the tag pattern is empty, shows in full without a tag.
Example: with `^(?<service>[^-]+)-(?<purpose>.+)-dlq$`, `orders-payment-failed-dlq` shows as the tag `orders`
and the name `payment-failed`; for `orders.payment-failed.dlq`, use `^(?<service>[a-z]+)\.(?<purpose>[a-z-]+)`.

## How the numbers are obtained

| Value | Source | Freshness |
|---|---|---|
| Queue list | `sqs:ListQueues` for the whole account, filtered by the DLQ pattern | re-read every hour |
| Message count | `sqs:GetQueueAttributes`, available + in flight, one call per queue, ten at a time | live |
| Age of oldest message | CloudWatch `ApproximateAgeOfOldestMessage`, one `GetMetricData` call, **only for non-empty queues** | lags 1–5 min |

SQS has no attribute for message age, so the age has to come from CloudWatch. CloudWatch charges
$0.01 per 1,000 metrics requested, so the app asks it only about queues that hold messages. At a 1-minute
interval the app costs well under $1 a month. Reading every count from CloudWatch as well would cost around
$60 a month.

A queue that was idle for six hours stops publishing CloudWatch metrics for a while. Its age shows as
*pending* until a datapoint arrives.

Refreshing pauses while the Mac sleeps and runs again a few seconds after wake. After a failure the
interval doubles, up to 30 minutes, until a refresh succeeds.

## Command line

```bash
make once                # one refresh of the DLQs, printed as a table
```

## Development

```bash
make build   # debug build
make test    # unit tests (swift-testing)
make run     # build the .app and launch it from ./build
```

`Sources/DLQMonitorCore` holds everything that talks to AWS: the SDK clients and the queue service. It is unit-tested. `Sources/DLQMonitor` holds the SwiftUI menu bar app.
