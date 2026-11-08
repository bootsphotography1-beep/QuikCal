import Foundation

/// Layout policy for compact Voice setup content. Pure + unit-testable.
/// The ScrollView keeps a bottom gutter and clear footer separation.
public enum ModelsLayoutPolicy: Sendable {
    /// Minimum empty space between the last scroll content and the footer.
    public static let bottomGutter: Double = 20
    /// Extra top padding on the footer when on Voice setup.
    public static let footerTopSeparation: Double = 12

    public static func hasRequiredGutter(_ gutter: Double) -> Bool {
        gutter >= 16 && gutter <= 24
    }
}
