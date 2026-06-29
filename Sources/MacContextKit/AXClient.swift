import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum AXReadError: Error, Equatable, CustomStringConvertible {
    case copyFailed(attribute: String, error: AXError)
    case missingValue(attribute: String)
    case typeMismatch(attribute: String, expected: String, actual: String)
    case invalidFrame(attribute: String, rect: CGRect)
    case actionFailed(action: String, error: AXError)

    public var description: String {
        switch self {
        case .copyFailed(let attribute, let error):
            return "\(attribute) copy failed: \(error)"
        case .missingValue(let attribute):
            return "\(attribute) had no value"
        case .typeMismatch(let attribute, let expected, let actual):
            return "\(attribute) expected \(expected), got \(actual)"
        case .invalidFrame(let attribute, let rect):
            return "\(attribute) invalid frame \(rect)"
        case .actionFailed(let action, let error):
            return "\(action) failed: \(error)"
        }
    }
}

public enum AXClient {
    public static let defaultMessagingTimeout: Float = 0.3

    public static func setMessagingTimeout(_ element: AXUIElement, seconds: Float = defaultMessagingTimeout) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    public static func attribute<T>(
        _ element: AXUIElement,
        _ name: String,
        as type: T.Type
    ) -> Result<T, AXReadError> {
        var ref: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &ref)
        guard error == .success else {
            return .failure(.copyFailed(attribute: name, error: error))
        }
        guard let ref else {
            return .failure(.missingValue(attribute: name))
        }
        if type == AXUIElement.self {
            guard CFGetTypeID(ref) == AXUIElementGetTypeID() else {
                return .failure(.typeMismatch(attribute: name, expected: "AXUIElement", actual: typeName(ref)))
            }
            return .success((ref as! AXUIElement) as! T)
        }
        if type == String.self {
            guard let value = ref as? String else {
                return .failure(.typeMismatch(attribute: name, expected: "String", actual: typeName(ref)))
            }
            return .success(value as! T)
        }
        if type == [AXUIElement].self {
            guard let value = ref as? [AXUIElement] else {
                return .failure(.typeMismatch(attribute: name, expected: "[AXUIElement]", actual: typeName(ref)))
            }
            return .success(value as! T)
        }
        guard let value = ref as? T else {
            return .failure(.typeMismatch(attribute: name, expected: String(describing: T.self), actual: typeName(ref)))
        }
        return .success(value)
    }

    public static func stringAttributes(
        _ element: AXUIElement,
        preferred attributes: [String]
    ) -> [String: String] {
        attributes.reduce(into: [:]) { out, attribute in
            if case .success(let value) = self.attribute(element, attribute, as: String.self),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out[attribute] = value
            }
        }
    }

    public static func elementAttribute(_ element: AXUIElement, _ name: String) -> Result<AXUIElement, AXReadError> {
        attribute(element, name, as: AXUIElement.self)
    }

    public static func children(_ element: AXUIElement) -> Result<[AXUIElement], AXReadError> {
        attribute(element, kAXChildrenAttribute as String, as: [AXUIElement].self)
    }

    public static func actionNames(_ element: AXUIElement) -> [String] {
        var namesRef: CFArray?
        guard AXUIElementCopyActionNames(element, &namesRef) == .success,
              let names = namesRef as? [String] else { return [] }
        return names
    }

    public static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    public static func setAttribute(_ element: AXUIElement, _ attribute: String, value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }

    @discardableResult
    public static func performAction(_ element: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }

    @discardableResult
    public static func performPress(_ element: AXUIElement) -> AXError {
        performAction(element, kAXPressAction)
    }

    public static func elementAtPosition(_ point: CGPoint) -> Result<AXUIElement, AXReadError> {
        let system = AXUIElementCreateSystemWide()
        setMessagingTimeout(system)
        var ref: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &ref)
        guard error == .success, let ref else {
            return .failure(.copyFailed(attribute: "elementAtPosition", error: error))
        }
        return .success(ref)
    }

    public static func frame(
        _ element: AXUIElement,
        knownDisplays: [CGRect] = activeDisplayBounds(),
        parentFrame: CGRect? = nil
    ) -> Result<CGRect, AXReadError> {
        let position = axValue(element, kAXPositionAttribute as String, as: CGPoint.self)
        let size = axValue(element, kAXSizeAttribute as String, as: CGSize.self)
        switch (position, size) {
        case (.success(let origin), .success(let size)):
            return validateFrame(
                CGRect(origin: origin, size: size),
                attribute: "AXFrame",
                knownDisplays: knownDisplays,
                parentFrame: parentFrame
            )
        case (.failure(let error), _):
            return .failure(error)
        case (_, .failure(let error)):
            return .failure(error)
        }
    }

    public static func validateFrame(
        _ rect: CGRect,
        attribute: String = "AXFrame",
        knownDisplays: [CGRect],
        parentFrame: CGRect? = nil
    ) -> Result<CGRect, AXReadError> {
        let candidate = rect.isFiniteNonZero ? rect : (parentFrame?.isFiniteNonZero == true ? parentFrame! : rect)
        guard candidate.isFiniteNonZero,
              knownDisplays.isEmpty || knownDisplays.contains(where: { !$0.intersection(candidate).isEmpty }) else {
            return .failure(.invalidFrame(attribute: attribute, rect: candidate))
        }
        return .success(candidate)
    }

    public static func axValue<T>(
        _ element: AXUIElement,
        _ attribute: String,
        as type: T.Type
    ) -> Result<T, AXReadError> {
        var ref: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard error == .success else {
            return .failure(.copyFailed(attribute: attribute, error: error))
        }
        guard let ref else { return .failure(.missingValue(attribute: attribute)) }
        guard CFGetTypeID(ref) == AXValueGetTypeID() else {
            return .failure(.typeMismatch(attribute: attribute, expected: "AXValue", actual: typeName(ref)))
        }
        let value = ref as! AXValue
        if type == CGPoint.self {
            guard AXValueGetType(value) == .cgPoint else {
                return .failure(.typeMismatch(attribute: attribute, expected: "CGPoint", actual: "\(AXValueGetType(value))"))
            }
            var point = CGPoint.zero
            guard AXValueGetValue(value, .cgPoint, &point) else {
                return .failure(.typeMismatch(attribute: attribute, expected: "CGPoint", actual: "unreadable"))
            }
            return .success(point as! T)
        }
        if type == CGSize.self {
            guard AXValueGetType(value) == .cgSize else {
                return .failure(.typeMismatch(attribute: attribute, expected: "CGSize", actual: "\(AXValueGetType(value))"))
            }
            var size = CGSize.zero
            guard AXValueGetValue(value, .cgSize, &size) else {
                return .failure(.typeMismatch(attribute: attribute, expected: "CGSize", actual: "unreadable"))
            }
            return .success(size as! T)
        }
        return .failure(.typeMismatch(attribute: attribute, expected: String(describing: T.self), actual: "AXValue"))
    }

    public static func activeDisplayBounds() -> [CGRect] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return CGDisplayBounds(id.uint32Value)
        }
    }

    private static func typeName(_ value: CFTypeRef) -> String {
        String(describing: CFGetTypeID(value))
    }
}

private extension CGRect {
    var isFiniteNonZero: Bool {
        origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
            && size.width > 0 && size.height > 0
    }
}
