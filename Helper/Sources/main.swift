import Foundation

// Placeholder so the app target links while the daemon is being written.
// The real entry point stands up an NSXPCListener and parks on a run loop.
FileHandle.standardError.write(Data("net.kandera.localfox.helper is not implemented yet\n".utf8))
exit(1)
