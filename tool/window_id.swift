// Prints the id of the first on-screen window owned by the named app, for `screencapture -l`.
import CoreGraphics

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for window in windows where (window["kCGWindowOwnerName"] as? String ?? "") == CommandLine.arguments[1] && (window["kCGWindowLayer"] as? Int) == 0 {
  print(window["kCGWindowNumber"]!)
  break
}
