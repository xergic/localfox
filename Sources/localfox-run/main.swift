import Foundation
import LocalfoxKit

// Placeholder entry point. The real command table lands with M1.
let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print("usage: localfox-run <detect|env|up|run> [...]")
    exit(2)
}
print("localfox-run: \(command) is not implemented yet")
exit(1)
