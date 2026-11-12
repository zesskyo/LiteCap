import SwiftUI

/// LiteCap's look: flat, square, gray. Blue means "on" (recording / streaming / selected).
enum Theme {
    static let active = Color(red: 0.16, green: 0.42, blue: 0.92)
    static let control = Color.gray.opacity(0.28)
    static let controlPressed = Color.gray.opacity(0.45)
    static let panel = Color.gray.opacity(0.08)
    static let selection = Color(red: 0.16, green: 0.42, blue: 0.92).opacity(0.45)
}

/// Square gray button; blue when `active`.
struct FlatButtonStyle: ButtonStyle {
    var active = false
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        FlatButton(configuration: configuration, active: active, fullWidth: fullWidth)
    }

    private struct FlatButton: View {
        let configuration: Configuration
        let active: Bool
        let fullWidth: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .foregroundStyle(active ? Color.white : Color.primary)
                .background(active ? Theme.active : (configuration.isPressed ? Theme.controlPressed : Theme.control))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
        }
    }
}

/// Small square icon button (panel headers, mixer strips).
struct IconButtonStyle: ButtonStyle {
    var on = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 22, height: 20)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(on ? Theme.active : (configuration.isPressed ? Theme.controlPressed : Color.clear))
            .contentShape(Rectangle())
    }
}

/// A selectable list row with a square highlight.
struct FlatRow<Content: View>: View {
    let selected: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.selection : Color.clear)
            .contentShape(Rectangle())
    }
}

/// Whole numbers without thousands separators: 20000, not 20,000.
let plainNumber = IntegerFormatStyle<Int>().grouping(.never)
/// Whole-pixel decimals without separators: 1480, not 1,480.
let plainDecimal = FloatingPointFormatStyle<Double>().grouping(.never).precision(.fractionLength(0))
