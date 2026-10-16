// Runs in the guest: turns on "Show menu bar background" and sets every screen's
// wallpaper to the image given, so the menu bar draws the blur Blackout has to cover.
//   setup <image>
import AppKit

let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
typealias SetBlur = @convention(c) (Bool, UnsafeRawPointer?) -> Int32
if let symbol = dlsym(skyLight, "SLSSetMenuBarUseBlurredAppearance") {
    _ = unsafeBitCast(symbol, to: SetBlur.self)(true, nil)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
for screen in NSScreen.screens {
    try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
}
