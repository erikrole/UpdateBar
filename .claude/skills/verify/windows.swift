// How many normal on-screen windows a process has, or with --id the first one's number for `screencapture -l`.
//   swift .claude/skills/verify/windows.swift <pid>
//   screencapture -x -o -l "$(swift .claude/skills/verify/windows.swift --id <pid>)" shot.png
import CoreGraphics
let args = Array(CommandLine.arguments.dropFirst())
let pid = Int32(args.last ?? "") ?? -1
let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let mine = all.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
print(args.first == "--id" ? "\(mine.first?[kCGWindowNumber as String] ?? 0)" : "\(mine.count)")
