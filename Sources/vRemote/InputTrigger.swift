import CoreGraphics
import Foundation

enum InputTriggerKey: String, CaseIterable, Identifiable {
    case leftOption
    case rightOption
    case leftCommand
    case rightCommand
    case leftControl
    case rightControl
    case leftShift
    case rightShift
    case function

    var id: String { rawValue }

    /// Settings saved before left/right selection existed. Each maps to the
    /// side vRemoter used to synthesize, so existing input-method shortcuts
    /// keep working after the upgrade.
    static func stored(_ raw: String?) -> InputTriggerKey? {
        switch raw {
        case "option": .leftOption
        case "command": .rightCommand
        case "control": .leftControl
        case "shift": .leftShift
        default: raw.flatMap(InputTriggerKey.init(rawValue:))
        }
    }

    var title: String {
        switch self {
        case .leftOption: L10n.text("左 Option (⌥)", "Left Option (⌥)")
        case .rightOption: L10n.text("右 Option (⌥)", "Right Option (⌥)")
        case .leftCommand: L10n.text("左 Command (⌘)", "Left Command (⌘)")
        case .rightCommand: L10n.text("右 Command (⌘)", "Right Command (⌘)")
        case .leftControl: L10n.text("左 Control (⌃)", "Left Control (⌃)")
        case .rightControl: L10n.text("右 Control (⌃)", "Right Control (⌃)")
        case .leftShift: L10n.text("左 Shift (⇧)", "Left Shift (⇧)")
        case .rightShift: L10n.text("右 Shift (⇧)", "Right Shift (⇧)")
        case .function: "Fn / Globe"
        }
    }

    var keyCode: CGKeyCode {
        switch self {
        case .leftOption: 0x3A
        case .rightOption: 0x3D
        case .leftCommand: 0x37
        case .rightCommand: 0x36
        case .leftControl: 0x3B
        case .rightControl: 0x3E
        case .leftShift: 0x38
        case .rightShift: 0x3C
        case .function: 0x3F
        }
    }

    /// Both sides of the modifier. X6 emits its own native modifier events,
    /// which are suppressed regardless of the side chosen here.
    var familyKeyCodes: Set<Int64> {
        switch self {
        case .leftOption, .rightOption: [0x3A, 0x3D]
        case .leftCommand, .rightCommand: [0x37, 0x36]
        case .leftControl, .rightControl: [0x3B, 0x3E]
        case .leftShift, .rightShift: [0x38, 0x3C]
        case .function: [0x3F]
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .leftOption, .rightOption: .maskAlternate
        case .leftCommand, .rightCommand: .maskCommand
        case .leftControl, .rightControl: .maskControl
        case .leftShift, .rightShift: .maskShift
        case .function: .maskSecondaryFn
        }
    }

    /// Device-dependent side bit from IOLLEvent.h (NX_DEVICE*KEYMASK).
    /// Input methods that tell left from right read this bit.
    var sideFlag: CGEventFlags {
        switch self {
        case .leftControl: CGEventFlags(rawValue: 0x0000_0001)
        case .leftShift: CGEventFlags(rawValue: 0x0000_0002)
        case .rightShift: CGEventFlags(rawValue: 0x0000_0004)
        case .leftCommand: CGEventFlags(rawValue: 0x0000_0008)
        case .rightCommand: CGEventFlags(rawValue: 0x0000_0010)
        case .leftOption: CGEventFlags(rawValue: 0x0000_0020)
        case .rightOption: CGEventFlags(rawValue: 0x0000_0040)
        case .rightControl: CGEventFlags(rawValue: 0x0000_2000)
        case .function: []
        }
    }
}

enum Key {
    /// Lets the event tap distinguish vRemoter-generated events from physical
    /// keyboards, Bluetooth buttons, and external remappers.
    static let syntheticMarker: Int64 = 0x4D_49_52_42 // "MIRB"

    static func triggerDown(_ trigger: InputTriggerKey = AppStorage.inputTriggerKey) {
        post(trigger: trigger, keyDown: true)
    }

    static func triggerUp(_ trigger: InputTriggerKey = AppStorage.inputTriggerKey) {
        post(trigger: trigger, keyDown: false)
    }

    /// A deliberate short modifier click for Doubao's toggle mode.
    static func triggerTap(
        _ trigger: InputTriggerKey = AppStorage.inputTriggerKey,
        completion: (() -> Void)? = nil
    ) {
        triggerDown(trigger)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            triggerUp(trigger)
            completion?()
        }
    }

    private static func post(trigger: InputTriggerKey, keyDown: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: trigger.keyCode,
            keyDown: keyDown
        ) else { return }
        event.flags = keyDown ? trigger.flag.union(trigger.sideFlag) : []
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        event.post(tap: .cghidEventTap)
        print(
            "[KEY] synthetic \(trigger.rawValue) " +
            (keyDown ? "DOWN" : "UP")
        )
    }
}
