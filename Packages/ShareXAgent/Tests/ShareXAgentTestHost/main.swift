import Foundation
import ShareXAgent

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
