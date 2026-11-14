import Foundation
import ShareXAgent
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

if CommandLine.arguments.dropFirst().first == "--atomic-write-failure" {
    let arguments = Array(CommandLine.arguments.dropFirst(2))
    guard arguments.count == 3 else { fatalError("Expected operation, destination, and failure mode.") }
    let interrupted = arguments[2] == "interrupt"
    if interrupted {
        signal(SIGXFSZ) { _ in _ = kill(getpid(), SIGKILL) }
    } else {
        signal(SIGXFSZ, SIG_IGN)
    }
    var signals = sigset_t()
    sigemptyset(&signals)
    sigaddset(&signals, SIGXFSZ)
    guard sigprocmask(SIG_UNBLOCK, &signals, nil) == 0 else { fatalError("Cannot enable the child process file-size signal.") }
    var limit = rlimit(rlim_cur: 512, rlim_max: 512)
    #if canImport(Darwin)
    let resource = RLIMIT_FSIZE
    #else
    let resource = __rlimit_resource_t(RLIMIT_FSIZE.rawValue)
    #endif
    guard setrlimit(resource, &limit) == 0 else { fatalError("Cannot set the child process file-size limit.") }
    let destination = URL(fileURLWithPath: arguments[1])
    let bytes = Data(repeating: 0x61, count: 4096)
    do {
        if arguments[0] == "replace" { try AtomicFile.replace(bytes, at: destination) }
        else { try AtomicFile.create(bytes, at: destination) }
        exit(1)
    } catch {
        try FileHandle.standardError.write(contentsOf: Data("\(error)\n".utf8))
        exit(0)
    }
}

if CommandLine.arguments.dropFirst().first == "--default-endpoint" {
    try FileHandle.standardOutput.write(contentsOf: Data((AgentEndpoint().directory + "\n").utf8))
    exit(0)
}

guard let directory = ProcessInfo.processInfo.environment["SHAREX_TEST_ENDPOINT"] else {
    fatalError("This transport test host requires SHAREX_TEST_ENDPOINT.")
}
let endpoint = AgentEndpoint(directory: directory)
if CommandLine.arguments.dropFirst().first == "--serve" {
    let server = try LocalAgentServer(endpoint: endpoint) { request in
        .success(request.id, .object(["operation": .string(request.operation.rawValue), "arguments": .object(request.arguments)]))
    }
    try FileHandle.standardOutput.write(contentsOf: Data("ready\n".utf8))
    withExtendedLifetime(server) { dispatchMain() }
} else {
    let arguments = Array(CommandLine.arguments.dropFirst(CommandLine.arguments.dropFirst().first == "--agent" ? 2 : 1))
    exit(AgentCommandRunner.run(arguments, launch: {
        throw AgentFailure(.startupTimeout, "The test service is not running.")
    }, endpoint: endpoint))
}
