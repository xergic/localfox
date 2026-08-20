import Darwin
import Dispatch
import Foundation
import LocalfoxKit

// Everything this daemon creates is root-only unless it says otherwise. Set
// before any filesystem work, because launchd's inherited umask is not ours to
// assume and a permissive one would leave the config and pid file writable.
umask(0o077)

HelperService.cleanUpOrphanedCaddy()

let service = HelperService()
let listener = NSXPCListener(machServiceName: HelperIdentity.machServiceName)
listener.delegate = service
listener.resume()

private let terminationHandler = TerminationSignalHandler(service: service)
withExtendedLifetime(terminationHandler) {
    RunLoop.main.run()
}

private final class TerminationSignalHandler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "net.kandera.localfox.helper.signals")
    private let service: HelperService
    private var sources: [DispatchSourceSignal] = []
    private var isStopping = false

    init(service: HelperService) {
        self.service = service

        for signalNumber in [SIGTERM, SIGINT] {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [weak self] in
                self?.stopAndExit()
            }
            source.resume()
            sources.append(source)
        }
    }

    private func stopAndExit() {
        guard !isStopping else { return }
        isStopping = true

        Task {
            await service.shutDown()
            exit(EXIT_SUCCESS)
        }
    }
}
