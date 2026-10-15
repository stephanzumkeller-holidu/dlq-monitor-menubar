import AWSSDKIdentity
import AWSSQS
import Foundation
import Testing
@testable import DLQMonitorCore

struct QueueNameTests {
    @Test func buildsConsoleURL() {
        let url = QueueName.consoleURL(
            queueURL: "https://sqs.us-east-1.amazonaws.com/123456789012/shop-orders-internal-bookings_dlq",
            region: "us-east-1"
        )
        #expect(url?.absoluteString == "https://us-east-1.console.aws.amazon.com/sqs/v3/home?region=us-east-1#/queues/https%3A%2F%2Fsqs.us-east-1.amazonaws.com%2F123456789012%2Fshop-orders-internal-bookings_dlq")
    }
}

struct QueueNamingTests {
    /// A naming scheme with service tags: `shop-<service>-<purpose>_dlq`.
    private let shop = try! QueueNaming(
        dlqPattern: "^shop-.*_dlq$",
        tagPattern: "^shop-(?<service>[^-]+)-(?<purpose>.+)_dlq$"
    )

    @Test func selectsDLQsByPattern() throws {
        #expect(shop.isDLQ("shop-orders-content_dlq"))
        #expect(!shop.isDLQ("shop-orders-content"))
        #expect(!shop.isDLQ("shop-orders-content_dlq-replay"))
        #expect(!shop.isDLQ("billing-invoices_dlq"))

        let dashed = try QueueNaming(dlqPattern: "-(dlq|deadletter)$")
        #expect(dashed.isDLQ("orders-dlq"))
        #expect(dashed.isDLQ("orders-deadletter"))
        #expect(!dashed.isDLQ("orders_dlq"))

        let anyCase = try QueueNaming(dlqPattern: "(?i)^dlq[-_]")
        #expect(anyCase.isDLQ("DLQ-orders"))
        #expect(!anyCase.isDLQ("orders"))
    }

    @Test func defaultPatternFindsCommonDLQNames() throws {
        let naming = try QueueNaming(dlqPattern: QueueNaming.defaultDLQPattern)
        for name in ["orders-dlq", "orders_dlq", "orders.dlq", "OrdersDLQ", "orders-dlq.fifo",
                     "orders-deadletter", "orders-dead-letter-queue", "orders_dead_letter", "shop-orders-content_dlq"] {
            #expect(naming.isDLQ(name), "\(name)")
        }
        for name in ["orders", "orders.fifo", "dlq-replayer", "dead-letter-handler"] {
            #expect(!naming.isDLQ(name), "\(name)")
        }
    }

    @Test func rejectsInvalidPatterns() {
        #expect(QueueNaming.dlqPatternError("_dlq$") == nil)
        #expect(QueueNaming.dlqPatternError("(_dlq") != nil)
        #expect(QueueNaming.dlqPatternError("") != nil)
        #expect(QueueNaming.tagPatternError("") == nil)
        #expect(QueueNaming.tagPatternError("^(?<service>[a-z]+)-") == nil)
        #expect(QueueNaming.tagPatternError("^([a-z]+)-") != nil)
        #expect(QueueNaming.tagPatternError("^(?<service>[a-z+-") != nil)
        #expect(throws: QueueNaming.PatternError.self) { try QueueNaming(dlqPattern: "[") }
    }

    @Test func splitsServiceAndPurpose() {
        #expect(shop.label(for: "shop-orders-internal-cron_dlq") == ("orders", "internal-cron"))
        #expect(shop.label(for: "shop-payments-bookings_dlq") == ("payments", "bookings"))
    }

    @Test func showsFullNameWithoutTagForOtherNames() throws {
        #expect(shop.label(for: "shop-solo_dlq") == (nil, "shop-solo_dlq"))
        #expect(shop.label(for: "shop--content_dlq") == (nil, "shop--content_dlq"))
        #expect(shop.label(for: "billing-invoices-sent_dlq") == (nil, "billing-invoices-sent_dlq"))
        #expect(try QueueNaming(dlqPattern: "_dlq$").label(for: "shop-orders-content_dlq") == (nil, "shop-orders-content_dlq"))
    }

    @Test func readsTagFromNamedGroups() throws {
        let naming = try QueueNaming(dlqPattern: "\\.dlq$", tagPattern: #"^(?<service>[a-z]+)\.(?<purpose>[a-z-]+)(\.dlq)?$"#)
        #expect(naming.label(for: "orders.payment-failed.dlq") == ("orders", "payment-failed"))
        #expect(naming.label(for: "Orders.dlq") == (nil, "Orders.dlq"))

        let serviceOnly = try QueueNaming(dlqPattern: "_dlq$", tagPattern: "^(?<service>[^_]+)_")
        #expect(serviceOnly.label(for: "billing_invoices_dlq") == ("billing", "billing_invoices_dlq"))
    }
}

struct AWSConfigFileTests {
    private let config = """
    [default]
    region=eu-central-1

    [profile app]
    source_profile = base
      region = us-east-1   
    [profile base]
    # region = us-east-1
    mfa_serial = arn:aws:iam::123456789012:mfa/someone
    """

    @Test func readsTheProfilesRegion() {
        #expect(AWSConfigFile.region(profile: "app", config: config) == "us-east-1")
        #expect(AWSConfigFile.region(profile: "default", config: config) == "eu-central-1")
        #expect(AWSConfigFile.region(profile: "base", config: config) == nil)
        #expect(AWSConfigFile.region(profile: "missing", config: config) == nil)
        #expect(AWSConfigFile.region(profile: "default", config: "[profile default]\nregion = us-west-2") == "us-west-2")
    }

    @Test func honoursAWSConfigFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dlq-monitor-test-config-\(UUID())")
        try config.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AWSConfigFile.region(profile: "app", environment: ["AWS_CONFIG_FILE": url.path]) == "us-east-1")
    }
}

struct LoginShellPATHTests {
    @Test func readsPATHFromLoginShell() throws {
        let path = try #require(LoginShell.path(timeout: 10))
        #expect(path.split(separator: ":").contains("/usr/bin"))
        #expect(!path.contains("DLQ_MONITOR_PATH="))
    }
}

struct FormatTests {
    @Test func formatsAges() {
        #expect(Format.age(45) == "45s")
        #expect(Format.age(35 * 60) == "35m")
        #expect(Format.age(36_725) == "10h 12m")
        #expect(Format.age(413_479) == "4d 18h")
        #expect(Format.age(2 * 86_400) == "2d")
    }

    @Test func formatsCounts() {
        #expect(Format.count(2081) == "2,081")
        #expect(Format.compactCount(12_400) == "12.4k")
        #expect(Format.delta(12) == "▲ 12")
        #expect(Format.delta(-3) == "▼ 3")
    }
}

struct AWSErrorMessageTests {
    @Test func explainsCredentialFailures() {
        let error = AWSCredentialIdentityResolverError.failedToResolveAWSCredentials(
            "ProfileAWSCredentialIdentityResolver: Profile with name nope doesn't exist."
        )
        #expect(AWSErrorMessage.describe(error) == "No AWS credentials: Profile with name nope doesn't exist. "
            + "Check the profile in Settings and ~/.aws/config, and that its credential source is signed in.")
    }

    @Test func showsServiceErrorCodeAndMessage() {
        var error = QueueDoesNotExist()
        error.message = "The specified queue does not exist."
        #expect(AWSErrorMessage.describe(error) == "AWS AWS.SimpleQueueService.NonExistentQueue: The specified queue does not exist.")
    }
}

struct ConcurrentMapTests {
    private actor Gauge {
        var running = 0
        var peak = 0
        var log: [String] = []
        func enter(_ item: Int) { running += 1; peak = max(peak, running); log.append("start \(item)") }
        func leave(_ item: Int) { running -= 1; log.append("end \(item)") }
    }

    @Test func keepsOrderAndLimit() async throws {
        let gauge = Gauge()
        let results = try await QueueService.concurrentMap(Array(0..<20), limit: 3) { item in
            await gauge.enter(item)
            try await Task.sleep(for: .milliseconds(5))
            await gauge.leave(item)
            return item * 2
        }
        #expect(results == Array(0..<20).map { $0 * 2 })
        #expect(await gauge.peak == 3)
        // The first call finishes before any other starts.
        #expect(await Array(gauge.log.prefix(2)) == ["start 0", "end 0"])
    }

    @Test func handlesEmptyInput() async throws {
        #expect(try await QueueService.concurrentMap([Int](), limit: 3) { $0 }.isEmpty)
    }
}
