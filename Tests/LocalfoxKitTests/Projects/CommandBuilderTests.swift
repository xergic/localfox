import Testing
@testable import LocalfoxKit

@Suite("forwarding a fixed port to a development command")
struct CommandBuilderTests {
    @Test("npm forwards the flag to the script exactly once")
    func npmArguments() {
        #expect(CommandBuilder.pinningPort(4100, in: "npm run dev", style: .doubleDashPort).command == "npm run dev -- --port 4100")
        #expect(CommandBuilder.pinningPort(4100, in: "npm run dev -- --turbo", style: .dashP).command == "npm run dev -- --turbo -p 4100")
        #expect(CommandBuilder.pinningPort(4100, in: "pnpm dev", style: .dashP).command == "pnpm dev -p 4100")
        #expect(CommandBuilder.pinningPort(4100, in: "npm run dev", style: .environmentPORT).command == "npm run dev")
    }
}
