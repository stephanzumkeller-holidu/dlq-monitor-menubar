import AWSClientRuntime
import AWSCloudWatch
import AWSSDKIdentity
import AWSSQS
import Foundation

/// SQS and CloudWatch clients for one AWS profile and region, from the official AWS SDK for Swift.
public struct AWSClients: Sendable {
    let sqs: SQSClient
    let cloudWatch: CloudWatchClient
    /// The region the clients call.
    public let region: String

    /// The profile resolver runs the profile's credential source again on every call, so its result is kept
    /// in memory this long. Assumed-role sessions last an hour by default.
    static let credentialLifetime: TimeInterval = 15 * 60

    /// Reads `profile` from `~/.aws/config` and `~/.aws/credentials`, like the AWS CLI: static keys,
    /// `credential_process`, `source_profile` + `role_arn`, SSO. An empty `region` means the profile's own.
    public init(profile: String, region: String) async throws {
        guard let region = region.isEmpty ? AWSConfigFile.region(profile: profile) : region else {
            throw NoRegion(profile: profile)
        }
        self.region = region
        let credentials = try CachedAWSCredentialIdentityResolver(
            source: ProfileAWSCredentialIdentityResolver(profileName: profile),
            refreshTime: Self.credentialLifetime
        )
        sqs = SQSClient(config: try await SQSClient.SQSClientConfig(
            awsCredentialIdentityResolver: credentials, region: region
        ))
        cloudWatch = CloudWatchClient(config: try await CloudWatchClient.CloudWatchClientConfig(
            awsCredentialIdentityResolver: credentials, region: region
        ))
    }
}

/// Neither the settings nor the profile name a region.
public struct NoRegion: Error, LocalizedError {
    public let profile: String
    public var errorDescription: String? {
        "No AWS region: set one in Settings, or add region = … to the profile \(profile) in ~/.aws/config."
    }
}

public enum AWSErrorMessage {
    /// A readable message. The SDK's own `localizedDescription` is only "The operation couldn't be completed".
    public static func describe(_ error: any Error) -> String {
        if let error = error as? AWSCredentialIdentityResolverError,
           case .failedToResolveAWSCredentials(let message) = error {
            // "ProfileAWSCredentialIdentityResolver: Profile with name nope doesn't exist."
            let reason = message.range(of: "Resolver: ").map { String(message[$0.upperBound...]) } ?? message
            return "No AWS credentials: \(reason) Check the profile in Settings and ~/.aws/config, and that its credential source is signed in."
        }
        if let error = error as? any AWSServiceError {
            return "AWS \(error.errorCode ?? "error"): \(error.message ?? "no message")"
        }
        return error.localizedDescription
    }
}
