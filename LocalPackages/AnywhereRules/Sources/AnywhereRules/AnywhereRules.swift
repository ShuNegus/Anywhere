import Foundation

public enum AnywhereRules {
    /// URL of the bundled read-only rules database.
    public static let databaseURL: URL? = Bundle.module.url(forResource: "Rules", withExtension: "db")
}
