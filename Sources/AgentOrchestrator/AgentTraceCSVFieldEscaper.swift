import Foundation

/// Escapes one AgentTrace audit CSV field, including spreadsheet formula guards.
public enum AgentTraceCSVFieldEscaper {
    public static func escape(_ field: String) -> String {
        let safeField = formulaEscaped(field)
        guard safeField.contains(",") || safeField.contains("\"") || safeField.contains("\n") || safeField.contains("\r") else { return safeField }
        return "\"" + safeField.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func formulaEscaped(_ field: String) -> String {
        guard let first = field.first else { return field }
        if isFormulaDangerous(first) {
            return "'" + field
        }

        let firstNonWhitespace = field.drop(while: { $0.isWhitespace }).first
        guard let firstNonWhitespace, isFormulaTrigger(firstNonWhitespace) else { return field }
        return "'" + field
    }

    private static func isFormulaDangerous(_ character: Character) -> Bool {
        isFormulaTrigger(character) || character == "\t" || character == "\r" || character == "\n"
    }

    private static func isFormulaTrigger(_ character: Character) -> Bool {
        character == "=" || character == "+" || character == "-" || character == "@"
    }
}
