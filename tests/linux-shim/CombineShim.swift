#if !canImport(Combine)
public protocol ObservableObject: AnyObject {}
@propertyWrapper public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
#endif

// swift-corelibs-foundation has no `String(localized:)`; the shim lets the app code typecheck on Linux.
#if !canImport(Darwin)
import Foundation
extension String {
    public struct LocalizationValue: ExpressibleByStringInterpolation {
        public let value: String
        public init(stringLiteral value: String) { self.value = value }
        public init(stringInterpolation: DefaultStringInterpolation) { self.value = String(stringInterpolation: stringInterpolation) }
    }
    public init(localized value: LocalizationValue) { self = value.value }
}
#endif
