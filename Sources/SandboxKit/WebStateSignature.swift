import Foundation

/// A compact, deterministic signature of a sandboxed web page state.
///
/// The builder deliberately stores hashes for mutable page text and form values
/// instead of serializing the raw strings. That keeps future background-agent
/// state comparisons useful without turning the signature into a sensitive log.
public struct WebStateSignature: Equatable, Sendable, CustomStringConvertible {
    public struct ActiveElement: Equatable, Hashable, Sendable {
        public let tagName: String
        public let id: String
        public let name: String
        public let type: String
        public let role: String
        public let label: String
        public let path: String

        public init(
            tagName: String = "",
            id: String = "",
            name: String = "",
            type: String = "",
            role: String = "",
            label: String = "",
            path: String = ""
        ) {
            self.tagName = tagName
            self.id = id
            self.name = name
            self.type = type
            self.role = role
            self.label = label
            self.path = path
        }

        public init(snapshot: Any?) {
            let dict = WebStateSignature.dictionary(snapshot)
            self.init(
                tagName: WebStateSignature.string(dict["tagName"]) ?? WebStateSignature.string(dict["tag"]) ?? "",
                id: WebStateSignature.string(dict["id"]) ?? "",
                name: WebStateSignature.string(dict["name"]) ?? "",
                type: WebStateSignature.string(dict["type"]) ?? "",
                role: WebStateSignature.string(dict["role"]) ?? "",
                label: WebStateSignature.string(dict["label"]) ?? "",
                path: WebStateSignature.string(dict["path"]) ?? ""
            )
        }

        fileprivate var canonicalValue: [String: Any] {
            [
                "tagName": tagName,
                "id": id,
                "name": name,
                "type": type,
                "role": role,
                "label": label,
                "path": path
            ]
        }
    }

    public struct Scroll: Equatable, Sendable {
        public let x: Double
        public let y: Double

        public init(x: Double = 0, y: Double = 0) {
            self.x = x
            self.y = y
        }

        public init(snapshot: Any?) {
            let dict = WebStateSignature.dictionary(snapshot)
            self.init(
                x: WebStateSignature.double(dict["x"]) ?? WebStateSignature.double(dict["scrollX"]) ?? 0,
                y: WebStateSignature.double(dict["y"]) ?? WebStateSignature.double(dict["scrollY"]) ?? 0
            )
        }

        fileprivate var canonicalValue: [String: Any] {
            ["x": x, "y": y]
        }
    }

    public struct Mutation: Equatable, Hashable, Sendable {
        public let kind: String
        public let targetRole: String
        public let targetName: String
        public let targetPath: String
        public let attributeName: String
        public let oldValueHash: String
        public let newValueHash: String

        public init(
            kind: String = "",
            targetRole: String = "",
            targetName: String = "",
            targetPath: String = "",
            attributeName: String = "",
            oldValueHash: String = "",
            newValueHash: String = ""
        ) {
            self.kind = kind
            self.targetRole = targetRole
            self.targetName = targetName
            self.targetPath = targetPath
            self.attributeName = attributeName
            self.oldValueHash = oldValueHash
            self.newValueHash = newValueHash
        }

        public init(snapshot: Any?) {
            let dict = WebStateSignature.dictionary(snapshot)
            self.init(
                kind: WebStateSignature.string(dict["kind"]) ?? WebStateSignature.string(dict["type"]) ?? "",
                targetRole: WebStateSignature.string(dict["targetRole"]) ?? "",
                targetName: WebStateSignature.string(dict["targetName"]) ?? "",
                targetPath: WebStateSignature.string(dict["targetPath"]) ?? WebStateSignature.string(dict["path"]) ?? "",
                attributeName: WebStateSignature.string(dict["attributeName"]) ?? WebStateSignature.string(dict["attribute"]) ?? "",
                oldValueHash: WebStateSignature.string(dict["oldValueHash"]) ?? "",
                newValueHash: WebStateSignature.string(dict["newValueHash"]) ?? ""
            )
        }

        fileprivate var canonicalValue: [String: Any] {
            [
                "kind": kind,
                "targetRole": targetRole,
                "targetName": targetName,
                "targetPath": targetPath,
                "attributeName": attributeName,
                "oldValueHash": oldValueHash,
                "newValueHash": newValueHash
            ]
        }
    }

    public let url: String
    public let title: String
    public let activeElement: ActiveElement
    public let scroll: Scroll
    public let interactivesHash: String
    public let formValuesHash: String
    public let checkedSelectedHash: String
    public let contentEditableTextHash: String
    public let ariaTextHash: String
    public let mutationSequence: Int
    public let mutations: [Mutation]
    public let stableHash: String

    public init(
        url: String,
        title: String,
        activeElement: ActiveElement = ActiveElement(),
        scroll: Scroll = Scroll(),
        interactivesHash: String,
        formValuesHash: String,
        checkedSelectedHash: String,
        contentEditableTextHash: String,
        ariaTextHash: String,
        mutationSequence: Int,
        mutations: [Mutation] = []
    ) {
        self.url = url
        self.title = title
        self.activeElement = activeElement
        self.scroll = scroll
        self.interactivesHash = interactivesHash
        self.formValuesHash = formValuesHash
        self.checkedSelectedHash = checkedSelectedHash
        self.contentEditableTextHash = contentEditableTextHash
        self.ariaTextHash = ariaTextHash
        self.mutationSequence = mutationSequence
        self.mutations = mutations
        self.stableHash = Self.hashCanonical([
            "url": url,
            "title": title,
            "activeElement": activeElement.canonicalValue,
            "scroll": scroll.canonicalValue,
            "interactivesHash": interactivesHash,
            "formValuesHash": formValuesHash,
            "checkedSelectedHash": checkedSelectedHash,
            "contentEditableTextHash": contentEditableTextHash,
            "ariaTextHash": ariaTextHash,
            "mutationSequence": mutationSequence,
            "mutations": mutations.map(\.canonicalValue)
        ])
    }

    public init(snapshot: [String: Any]) {
        let activeElement = ActiveElement(snapshot: snapshot["activeElement"])
        let scroll = Scroll(snapshot: snapshot["scroll"])
        self.init(
            url: Self.string(snapshot["url"]) ?? "",
            title: Self.string(snapshot["title"]) ?? "",
            activeElement: activeElement,
            scroll: scroll,
            interactivesHash: Self.hashField(snapshot, hashKey: "interactivesHash", rawKeys: ["interactives", "interactiveElements"]),
            formValuesHash: Self.hashField(snapshot, hashKey: "formValuesHash", rawKeys: ["formValues", "forms"]),
            checkedSelectedHash: Self.hashField(snapshot, hashKey: "checkedSelectedHash", rawKeys: ["checkedSelected", "checkedSelectedState"]),
            contentEditableTextHash: Self.hashField(snapshot, hashKey: "contentEditableTextHash", rawKeys: ["contentEditableText", "contentEditable"]),
            ariaTextHash: Self.hashField(snapshot, hashKey: "ariaTextHash", rawKeys: ["ariaText", "ariaTexts"]),
            mutationSequence: Self.integer(snapshot["mutationSequence"]) ?? 0,
            mutations: Self.array(snapshot["mutations"] ?? snapshot["mutationRing"]).map(Mutation.init(snapshot:))
        )
    }

    public var description: String {
        let urlHash = Self.hashCanonical(url)
        let titleHash = Self.hashCanonical(title)
        let activeElementHash = Self.hashCanonical(activeElement.canonicalValue)
        return "WebStateSignature(urlHash: \(urlHash), titleHash: \(titleHash), activeElementHash: \(activeElementHash), scroll: \(scroll), interactivesHash: \(interactivesHash), formValuesHash: \(formValuesHash), checkedSelectedHash: \(checkedSelectedHash), contentEditableTextHash: \(contentEditableTextHash), ariaTextHash: \(ariaTextHash), mutationSequence: \(mutationSequence), mutations: \(mutations.count), stableHash: \(stableHash))"
    }

    public static let mutationObserverInstallScript = #"""
    (() => {
      if (window.__cascadeWebStateObserver) return;
      const canonical = (value) => {
        if (value === null || value === undefined) return "null";
        if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
        if (typeof value === "object") {
          return "{" + Object.keys(value).sort().map((key) => JSON.stringify(key) + ":" + canonical(value[key])).join(",") + "}";
        }
        if (typeof value === "number") return Number.isFinite(value) ? String(value) : "null";
        if (typeof value === "boolean") return value ? "true" : "false";
        return JSON.stringify(String(value));
      };
      const hash = (value) => {
        let h = 0xcbf29ce484222325n;
        const bytes = new TextEncoder().encode(canonical(value));
        for (const byte of bytes) {
          h ^= BigInt(byte);
          h = (h * 0x100000001b3n) & 0xffffffffffffffffn;
        }
        return "fnv64:" + h.toString(16).padStart(16, "0");
      };
      const clip = (text, max = 120) => String(text || "").replace(/\s+/g, " ").trim().slice(0, max);
      const cssPath = (el) => {
        if (!el || el.nodeType !== Node.ELEMENT_NODE) return "";
        if (el.id) return "#" + CSS.escape(el.id);
        const parts = [];
        for (let node = el; node && node.nodeType === Node.ELEMENT_NODE && parts.length < 6; node = node.parentElement) {
          let part = node.localName || node.tagName.toLowerCase();
          const parent = node.parentElement;
          if (parent) part += ":nth-of-type(" + (Array.from(parent.children).filter((sibling) => sibling.localName === node.localName).indexOf(node) + 1) + ")";
          parts.unshift(part);
        }
        return parts.join(">");
      };
      const targetInfo = (node) => {
        const el = node && node.nodeType === Node.ELEMENT_NODE ? node : node?.parentElement;
        return {
          targetRole: clip(el?.getAttribute?.("role") || el?.localName || ""),
          targetName: clip(el?.id || el?.getAttribute?.("name") || el?.getAttribute?.("aria-label") || ""),
          targetPath: cssPath(el)
        };
      };
      const pushMutation = (payload) => {
        window.__cascadeWebStateMutationSequence = Number(window.__cascadeWebStateMutationSequence || 0) + 1;
        const ring = window.__cascadeWebStateMutations || [];
        ring.push(payload);
        window.__cascadeWebStateMutations = ring.slice(-80);
      };
      window.__cascadeWebStateMutationSequence = Number(window.__cascadeWebStateMutationSequence || 0);
      window.__cascadeWebStateMutations = window.__cascadeWebStateMutations || [];
      window.__cascadeWebStateObserver = new MutationObserver((mutations) => {
        for (const mutation of mutations) {
          const info = targetInfo(mutation.target);
          if (mutation.type === "attributes") {
            const nextValue = mutation.target?.getAttribute?.(mutation.attributeName || "") || "";
            pushMutation({
              kind: "attributes",
              ...info,
              attributeName: mutation.attributeName || "",
              oldValueHash: hash(mutation.oldValue || ""),
              newValueHash: hash(nextValue)
            });
          } else if (mutation.type === "characterData") {
            pushMutation({
              kind: "characterData",
              ...info,
              attributeName: "",
              oldValueHash: hash(mutation.oldValue || ""),
              newValueHash: hash(mutation.target?.data || "")
            });
          } else {
            pushMutation({
              kind: "childList",
              ...info,
              attributeName: "",
              oldValueHash: "",
              newValueHash: hash([mutation.addedNodes?.length || 0, mutation.removedNodes?.length || 0])
            });
          }
        }
      });
      const root = document.documentElement || document;
      window.__cascadeWebStateObserver.observe(root, {
        attributes: true,
        attributeOldValue: true,
        childList: true,
        characterData: true,
        characterDataOldValue: true,
        subtree: true
      });
    })();
    """#

    public static let mutationConsumeJavaScript = #"""
    (() => {
      const out = Array.isArray(window.__cascadeWebStateMutations) ? window.__cascadeWebStateMutations.slice() : [];
      window.__cascadeWebStateMutations = [];
      return out;
    })();
    """#

    /// JavaScript that returns a signature-ready dictionary from a live page.
    ///
    /// It returns hashes for mutable/sensitive collections, never raw form values
    /// or contenteditable text. The mutation observer itself is installed by
    /// `mutationObserverInstallScript` at document start.
    public static let javaScriptSnippet = #"""
    (() => {
      const canonical = (value) => {
        if (value === null || value === undefined) return "null";
        if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
        if (typeof value === "object") {
          return "{" + Object.keys(value).sort().map((key) => JSON.stringify(key) + ":" + canonical(value[key])).join(",") + "}";
        }
        if (typeof value === "number") return Number.isFinite(value) ? String(value) : "null";
        if (typeof value === "boolean") return value ? "true" : "false";
        return JSON.stringify(String(value));
      };

      const hash = (value) => {
        let h = 0xcbf29ce484222325n;
        const bytes = new TextEncoder().encode(canonical(value));
        for (const byte of bytes) {
          h ^= BigInt(byte);
          h = (h * 0x100000001b3n) & 0xffffffffffffffffn;
        }
        return "fnv64:" + h.toString(16).padStart(16, "0");
      };

      const clip = (text, max = 160) => String(text || "").replace(/\s+/g, " ").trim().slice(0, max);
      const cssPath = (el) => {
        if (!el || el.nodeType !== Node.ELEMENT_NODE) return "";
        if (el.id) return "#" + CSS.escape(el.id);
        const parts = [];
        for (let node = el; node && node.nodeType === Node.ELEMENT_NODE && parts.length < 6; node = node.parentElement) {
          let part = node.localName || node.tagName.toLowerCase();
          if (node.name) part += "[name=\"" + CSS.escape(node.name) + "\"]";
          const parent = node.parentElement;
          if (parent) part += ":nth-of-type(" + (Array.from(parent.children).filter((sibling) => sibling.localName === node.localName).indexOf(node) + 1) + ")";
          parts.unshift(part);
        }
        return parts.join(">");
      };

      const editableTags = new Set(["input", "textarea", "select"]);
      const editableRoles = new Set(["textbox", "searchbox"]);
      const isEditableElement = (el) => {
        const tag = el?.tagName?.toLowerCase() || "";
        const role = (el?.getAttribute("role") || "").toLowerCase();
        return Boolean(el?.isContentEditable || editableTags.has(tag) || editableRoles.has(role));
      };

      const labelFor = (el) => {
        const safeLabel = clip(
          el?.getAttribute("aria-label") ||
          el?.getAttribute("title") ||
          el?.getAttribute("placeholder") ||
          Array.from(el?.labels || []).map((label) => label.innerText).join(" ") ||
          ""
        );
        if (safeLabel || isEditableElement(el)) return safeLabel;
        return clip(el?.innerText || "");
      };

      const descriptor = (el) => ({
        tagName: el?.tagName?.toLowerCase() || "",
        id: el?.id || "",
        name: el?.getAttribute("name") || "",
        type: el?.getAttribute("type") || "",
        role: el?.getAttribute("role") || "",
        label: labelFor(el),
        path: cssPath(el)
      });

      const interactiveSelector = [
        "a[href]",
        "button",
        "input",
        "select",
        "textarea",
        "[contenteditable='true']",
        "[role='button']",
        "[role='link']",
        "[role='menuitem']",
        "[tabindex]:not([tabindex='-1'])"
      ].join(",");

      const controls = Array.from(document.querySelectorAll("input, select, textarea"));
      const controlValue = (el) => {
        if (el.tagName?.toLowerCase() === "select" && el.multiple) {
          return Array.from(el.selectedOptions).map((option) => option.value);
        }
        return el.value || "";
      };

      const interactives = Array.from(document.querySelectorAll(interactiveSelector)).map(descriptor);
      const formValues = controls.map((el) => ({ element: descriptor(el), valueHash: hash(controlValue(el)) }));
      const checkedSelected = controls.map((el) => {
        const tag = el.tagName?.toLowerCase();
        if (tag === "select") {
          return {
            element: descriptor(el),
            selectedIndex: el.selectedIndex,
            selected: Array.from(el.options).map((option, index) => option.selected ? { index, valueHash: hash(option.value) } : null).filter(Boolean)
          };
        }
        return { element: descriptor(el), checked: Boolean(el.checked) };
      });
      const contentEditableText = Array.from(document.querySelectorAll("[contenteditable='true']")).map((el) => ({
        element: descriptor(el),
        textHash: hash(el.innerText || el.textContent || "")
      }));
      const ariaText = Array.from(document.querySelectorAll("[aria-label], [aria-labelledby], [aria-describedby]")).map((el) => ({
        element: descriptor(el),
        ariaHash: hash([
          el.getAttribute("aria-label") || "",
          el.getAttribute("aria-labelledby") || "",
          el.getAttribute("aria-describedby") || ""
        ])
      }));

      return {
        url: location.href,
        title: document.title,
        activeElement: descriptor(document.activeElement),
        scroll: { x: window.scrollX || document.documentElement.scrollLeft || 0, y: window.scrollY || document.documentElement.scrollTop || 0 },
        interactivesHash: hash(interactives),
        formValuesHash: hash(formValues),
        checkedSelectedHash: hash(checkedSelected),
        contentEditableTextHash: hash(contentEditableText),
        ariaTextHash: hash(ariaText),
        mutationSequence: Number(window.__cascadeWebStateMutationSequence || 0),
        mutations: Array.isArray(window.__cascadeWebStateMutations) ? window.__cascadeWebStateMutations.slice(-80) : []
      };
    })();
    """#

    private static func hashField(_ snapshot: [String: Any], hashKey: String, rawKeys: [String]) -> String {
        if let existing = string(snapshot[hashKey]), existing.hasPrefix("fnv64:") {
            return existing
        }
        for key in rawKeys {
            if let value = snapshot[key] {
                return hashCanonical(value)
            }
        }
        return hashCanonical([])
    }

    fileprivate static func hashCanonical(_ value: Any) -> String {
        fnv1a64Hex(canonical(value))
    }

    private static func canonical(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        if let value = value as? String { return quote(value) }
        if let value = value as? Bool { return value ? "true" : "false" }
        if let value = value as? Int { return String(value) }
        if let value = value as? Int64 { return String(value) }
        if let value = value as? Double { return numberString(value) }
        if let value = value as? Float { return numberString(Double(value)) }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return value.boolValue ? "true" : "false"
            }
            return numberString(value.doubleValue)
        }
        if let value = value as? [Any] {
            return "[" + value.map { canonical($0) }.joined(separator: ",") + "]"
        }
        if let value = value as? [String: Any] {
            return "{" + value.keys.sorted().map { key in
                quote(key) + ":" + canonical(value[key])
            }.joined(separator: ",") + "}"
        }
        return quote(String(describing: value))
    }

    private static func quote(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        result += "\""
        return result
    }

    private static func numberString(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value.rounded(.towardZero) == value {
            return String(Int64(value))
        }
        var string = String(format: "%.6f", value)
        while string.last == "0" { string.removeLast() }
        if string.last == "." { string.removeLast() }
        return string
    }

    private static func fnv1a64Hex(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return "fnv64:" + String(format: "%016llx", hash)
    }

    fileprivate static func dictionary(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    fileprivate static func array(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    fileprivate static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? Double { return boundedInteger(value) }
        if let value = value as? NSNumber {
            if let integer = Int(value.stringValue) { return integer }
            return boundedInteger(value.doubleValue)
        }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func boundedInteger(_ value: Double) -> Int? {
        guard value.isFinite,
              value >= Double(Int.min),
              value < Double(Int.max) else { return nil }
        return Int(value)
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Float { return Double(value) }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
}
