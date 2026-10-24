import Foundation

public enum PrivacyRedactor {
    private static let expressions: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?i)([a-z][a-z0-9+.-]*://)[^/@\s]+@"#),
        try! NSRegularExpression(pattern: #"(?i)([?&](?:token|access_token|refresh_token|password|passwd|secret|api[_-]?key|auth|credential)=)[^&#\s]+"#),
        try! NSRegularExpression(pattern: #"(?i)\bBearer\s+[A-Za-z0-9._~+/-]+=*"#)
    ]

    public static func redact(_ value: String) -> String {
        var result = value
        let fullRange = NSRange(result.startIndex..<result.endIndex, in: result)
        result = expressions[0].stringByReplacingMatches(in: result, range: fullRange, withTemplate: "$1[REDACTED]@")
        var range = NSRange(result.startIndex..<result.endIndex, in: result)
        result = expressions[1].stringByReplacingMatches(in: result, range: range, withTemplate: "$1[REDACTED]")
        range = NSRange(result.startIndex..<result.endIndex, in: result)
        result = expressions[2].stringByReplacingMatches(in: result, range: range, withTemplate: "Bearer [REDACTED]")
        return result
    }
}
