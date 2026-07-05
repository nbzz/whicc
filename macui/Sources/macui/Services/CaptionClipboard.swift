import AppKit

/// One-shot helper that copies the user's caption history to
/// the macOS pasteboard, with a chosen format (translation only /
/// source only / both tab-separated).
///
/// Kept separate from `OverlayState` because it's a side-effecting
/// operation that needs to know the system pasteboard. The
/// `OverlayState` shouldn't be making AppKit calls; this is the
/// "glue" layer between the UI button and NSPasteboard.
enum CaptionClipboard {
    enum Format: String, CaseIterable, Identifiable {
        case translation = "translation"
        case source      = "source"
        case both        = "both"

        var id: String { rawValue }

        /// Display name shown in the HUD popover menu.
        /// LocalizedStringKey 让 NSMenuItem(title:) 字面量查表 — 但这里 title 是 String
        /// 参数,所以用 NSLocalizedString() 显式查。
        var displayName: String {
            switch self {
            case .translation: return NSLocalizedString("复制译文", comment: "")
            case .source:      return NSLocalizedString("复制原文", comment: "")
            case .both:        return NSLocalizedString("复制全部", comment: "")
            }
        }
    }

    /// Build the text payload to copy. Order: oldest first → newest
    /// last, with the committed caption (if any) at the end. The
    /// committed caption is the live "now" line; history is what
    /// came before.
    static func makePayload(
        history: [OverlayCaption],
        committed: OverlayCaption?,
        format: Format
    ) -> String {
        // History is stored newest-last; reverse for display order.
        let ordered = history + (committed.map { [$0] } ?? [])
        let lines: [String] = ordered.compactMap { caption in
            switch format {
            case .translation:
                let text = caption.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            case .source:
                let text = caption.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            case .both:
                let src = caption.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
                let tr  = caption.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if src.isEmpty && tr.isEmpty { return nil }
                if src.isEmpty { return tr }
                if tr.isEmpty  { return src }
                return "\(src)\t\(tr)"
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Push `payload` to the general pasteboard. No-op when the
    /// payload is empty (avoids putting an empty string on the
    /// pasteboard when the user picks "copy" with no captions
    /// available yet).
    @discardableResult
    static func copy(_ payload: String) -> Bool {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(payload, forType: .string)
        return true
    }
}