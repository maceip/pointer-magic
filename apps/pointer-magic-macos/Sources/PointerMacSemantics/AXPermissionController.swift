@preconcurrency import ApplicationServices
import PointerCore

public enum AXPermissionController {
    public static func hasPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Requests the system prompt. The returned value is the current state; macOS updates
    /// trust asynchronously after the person responds.
    @discardableResult
    public static func requestPermission() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
