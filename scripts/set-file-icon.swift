import AppKit
import Foundation

guard CommandLine.arguments.count == 3,
      let icon = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    fputs("Usage: set-file-icon IMAGE FILE\n", stderr); exit(1)
}
guard NSWorkspace.shared.setIcon(icon, forFile: CommandLine.arguments[2], options: []) else {
    fputs("Failed to set Finder icon\n", stderr); exit(1)
}
