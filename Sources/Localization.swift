import Foundation

/// Spanish on a Mac whose first language is Spanish; English everywhere else.
private let usesSpanish: Bool = {
    guard let first = Locale.preferredLanguages.first else { return false }
    return first.lowercased().hasPrefix("es")
}()

func L(_ spanish: @autoclosure () -> String, _ english: @autoclosure () -> String) -> String {
    usesSpanish ? spanish() : english()
}
