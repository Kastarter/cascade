// LEAF TARGET — no package dependencies. See Geometry.swift header.

/// A leaf-safe description of a screen action. `kindToken` uses the same vocabulary
/// as CUStep.kindToken (click/type/key/scroll/drag/open_app/open_url/wait/…).
/// ProviderKit's CUAction maps to this ONCE at the boundary in a later task — never here.
public struct ActionDescriptor: Sendable, Equatable {
    public let kindToken: String
    public let targetText: String?
    public let typedText: String?
    public let point: Point<FrameSpace>?
    public let app: AppTarget?

    public init(
        kindToken: String,
        targetText: String? = nil,
        typedText: String? = nil,
        point: Point<FrameSpace>? = nil,
        app: AppTarget? = nil
    ) {
        self.kindToken = kindToken
        self.targetText = targetText
        self.typedText = typedText
        self.point = point
        self.app = app
    }
}
