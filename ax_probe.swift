import ApplicationServices
import Foundation

// Throwaway probe: is THIS process (and thus its children) already trusted for
// Accessibility? Uses the non-prompting check, so it never opens a dialog.
let trusted = AXIsProcessTrusted()
print("AXIsProcessTrusted:", trusted)
