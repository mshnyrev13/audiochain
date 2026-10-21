import Foundation

func auditOutputDirectory(fallback:String) -> String {
    if let index = CommandLine.arguments.firstIndex(of:"--audit-output"), CommandLine.arguments.count > index+1 {
        return CommandLine.arguments[index+1]
    }
    return fallback
}
