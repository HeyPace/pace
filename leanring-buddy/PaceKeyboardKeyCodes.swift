//
//  PaceKeyboardKeyCodes.swift
//  leanring-buddy
//
//  Extracted from PaceActionExecutor.swift (Wave 6a split): the ANSI
//  US-layout key-name → CGKeyCode table and the modifier-flag mapper.
//  Lives as a PaceActionExecutor extension so callers keep using the
//  same `PaceActionExecutor.virtualKeyCode(forKeyName:)` API.
//

import AppKit
import CoreGraphics
import Foundation

extension PaceActionExecutor {

    // MARK: - Key name → virtual key code

    nonisolated static func virtualKeyCode(forKeyName keyName: String) -> CGKeyCode? {
        // ANSI (US-layout) virtual key codes for every letter, digit, common
        // punctuation, function key, and named key. parseKeyPayload validates
        // against this table, so parse-time acceptance and execution-time
        // capability stay in lockstep — an unmappable key name is rejected
        // before it reaches the executor instead of failing mid-plan.
        switch keyName.lowercased() {
        case "a": return 0x00
        case "s": return 0x01
        case "d": return 0x02
        case "f": return 0x03
        case "h": return 0x04
        case "g": return 0x05
        case "z": return 0x06
        case "x": return 0x07
        case "c": return 0x08
        case "v": return 0x09
        case "b": return 0x0B
        case "q": return 0x0C
        case "w": return 0x0D
        case "e": return 0x0E
        case "r": return 0x0F
        case "y": return 0x10
        case "t": return 0x11
        case "1": return 0x12
        case "2": return 0x13
        case "3": return 0x14
        case "4": return 0x15
        case "6": return 0x16
        case "5": return 0x17
        case "=", "equals": return 0x18
        case "9": return 0x19
        case "7": return 0x1A
        case "-", "minus": return 0x1B
        case "8": return 0x1C
        case "0": return 0x1D
        case "]": return 0x1E
        case "o": return 0x1F
        case "u": return 0x20
        case "[": return 0x21
        case "i": return 0x22
        case "p": return 0x23
        case "l": return 0x25
        case "j": return 0x26
        case "'": return 0x27
        case "k": return 0x28
        case ";": return 0x29
        case "\\": return 0x2A
        case ",", "comma": return 0x2B
        case "/", "slash": return 0x2C
        case "n": return 0x2D
        case "m": return 0x2E
        case ".", "period": return 0x2F
        case "`", "backtick", "grave": return 0x32
        case "return", "enter": return 0x24
        case "tab": return 0x30
        case "space": return 0x31
        case "delete", "backspace": return 0x33
        case "forwarddelete": return 0x75
        case "escape", "esc": return 0x35
        case "up", "uparrow": return 0x7E
        case "down", "downarrow": return 0x7D
        case "left", "leftarrow": return 0x7B
        case "right", "rightarrow": return 0x7C
        case "home": return 0x73
        case "end": return 0x77
        case "pageup": return 0x74
        case "pagedown": return 0x79
        case "f1": return 0x7A
        case "f2": return 0x78
        case "f3": return 0x63
        case "f4": return 0x76
        case "f5": return 0x60
        case "f6": return 0x61
        case "f7": return 0x62
        case "f8": return 0x64
        case "f9": return 0x65
        case "f10": return 0x6D
        case "f11": return 0x67
        case "f12": return 0x6F
        default:
            return nil
        }
    }

    static func cgEventFlags(forModifiers modifiers: [PaceKeyboardModifier]) -> CGEventFlags {
        var combinedFlags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case .command: combinedFlags.insert(.maskCommand)
            case .option: combinedFlags.insert(.maskAlternate)
            case .control: combinedFlags.insert(.maskControl)
            case .shift: combinedFlags.insert(.maskShift)
            }
        }
        return combinedFlags
    }
}
