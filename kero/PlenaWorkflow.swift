//
//  PlenaWorkflow.swift
//  kero
//

import Combine
import Foundation

enum PlenaWorkflowPhase: String {
    case idle
    case running
    case complete
    case blocked
    case failed
}

enum PlenaNodePhase: String {
    case waiting
    case ready
    case running
    case verifying
    case complete
    case blocked
    case failed
}

struct PlenaWorkflowNodeDefinition: Equatable {
    let id: String
    let title: String
    let prompt: String
    let dependsOn: [String]
    let verify: [[String]]
}

struct PlenaWorkflowDefinition: Equatable {
    let version: Int
    let id: String
    let title: String
    let agent: KeroAgentKind
    let maxWorkers: Int
    let nodes: [PlenaWorkflowNodeDefinition]

    static func parse(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(KeroJSONValue.self, from: data)
        let object = try plenaObject(
            value,
            keys: ["version", "id", "title", "agent", "maxWorkers", "nodes"],
            context: "workflow"
        )
        guard let version = object["version"]?.intValue, version == 1 else {
            throw PlenaWorkflowError.message("workflow.version must be 1")
        }
        guard let id = object["id"]?.stringValue, plenaToken(id) else {
            throw PlenaWorkflowError.message("workflow.id must be a safe 1 to 64 character token")
        }
        guard let title = object["title"]?.stringValue, !title.isEmpty else {
            throw PlenaWorkflowError.message("workflow.title must be a non-empty string")
        }
        guard let agentName = object["agent"]?.stringValue,
              let agent = KeroAgentKind(rawValue: agentName) else {
            throw PlenaWorkflowError.message("workflow.agent is not supported by Kero")
        }
        guard let maxWorkers = object["maxWorkers"]?.intValue,
              (1...8).contains(maxWorkers) else {
            throw PlenaWorkflowError.message("workflow.maxWorkers must be between 1 and 8")
        }
        guard let nodeValues = object["nodes"]?.arrayValue, !nodeValues.isEmpty else {
            throw PlenaWorkflowError.message("workflow.nodes must be a non-empty array")
        }

        var nodes: [PlenaWorkflowNodeDefinition] = []
        var ids = Set<String>()
        for value in nodeValues {
            let node = try plenaObject(
                value,
                keys: ["id", "title", "prompt", "dependsOn", "verify"],
                context: "workflow node"
            )
            guard let nodeID = node["id"]?.stringValue, plenaToken(nodeID) else {
                throw PlenaWorkflowError.message("every node.id must be a safe 1 to 64 character token")
            }
            guard ids.insert(nodeID).inserted else {
                throw PlenaWorkflowError.message("duplicate workflow node id: \(nodeID)")
            }
            guard let nodeTitle = node["title"]?.stringValue, !nodeTitle.isEmpty,
                  let prompt = node["prompt"]?.stringValue, !prompt.isEmpty,
                  plenaSafePrompt(prompt), prompt.utf8.count <= 200_000,
                  let dependencies = try? plenaStringArray(node["dependsOn"], context: "\(nodeID).dependsOn"),
                  Set(dependencies).count == dependencies.count else {
                throw PlenaWorkflowError.message("node \(nodeID) has an invalid title, prompt, or dependency list")
            }
            guard let verifyValues = node["verify"]?.arrayValue else {
                throw PlenaWorkflowError.message("node \(nodeID).verify must be an array of argv arrays")
            }
            let commands = try verifyValues.map {
                try plenaStringArray($0, context: "\(nodeID).verify")
            }
            guard commands.allSatisfy({ command in
                guard let executable = command.first else { return false }
                return executable.hasPrefix("/") && command.allSatisfy(plenaSafePrompt)
            }) else {
                throw PlenaWorkflowError.message("node \(nodeID) verification commands need an absolute executable and safe argv")
            }
            nodes.append(Self.node(nodeID, nodeTitle, prompt, dependencies, commands))
        }

        let official = Set(nodes.map(\.id))
        for node in nodes {
            let unknown = node.dependsOn.filter { !official.contains($0) }
            guard unknown.isEmpty, !node.dependsOn.contains(node.id) else {
                throw PlenaWorkflowError.message("node \(node.id) has unknown or self dependencies")
            }
        }
        var resolved = Set<String>()
        while resolved.count < nodes.count {
            let ready = nodes.filter {
                !resolved.contains($0.id) && $0.dependsOn.allSatisfy(resolved.contains)
            }
            guard !ready.isEmpty else {
                throw PlenaWorkflowError.message("workflow dependencies contain a cycle")
            }
            ready.forEach { resolved.insert($0.id) }
        }
        return Self(
            version: version,
            id: id,
            title: title,
            agent: agent,
            maxWorkers: maxWorkers,
            nodes: nodes
        )
    }

    private static func node(
        _ id: String,
        _ title: String,
        _ prompt: String,
        _ dependsOn: [String],
        _ verify: [[String]]
    ) -> PlenaWorkflowNodeDefinition {
        PlenaWorkflowNodeDefinition(
            id: id,
            title: title,
            prompt: prompt,
            dependsOn: dependsOn,
            verify: verify
        )
    }
}

struct PlenaNodeState: Identifiable, Equatable {
    let id: String
    let title: String
    var phase: PlenaNodePhase
    var detail: String
    var sessionID: UUID?
}

private enum PlenaWorkflowError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message): return message
        }
    }
}

private func plenaObject(
    _ value: KeroJSONValue,
    keys: Set<String>,
    context: String
) throws -> [String: KeroJSONValue] {
    guard let object = value.objectValue, Set(object.keys) == keys else {
        throw PlenaWorkflowError.message("\(context) must contain exactly: \(keys.sorted().joined(separator: ", "))")
    }
    return object
}

private func plenaStringArray(_ value: KeroJSONValue?, context: String) throws -> [String] {
    guard let values = value?.arrayValue else {
        throw PlenaWorkflowError.message("\(context) must be a string array")
    }
    let strings = values.compactMap(\.stringValue)
    guard strings.count == values.count else {
        throw PlenaWorkflowError.message("\(context) must contain only strings")
    }
    return strings
}

private func plenaToken(_ value: String) -> Bool {
    guard (1...64).contains(value.utf8.count) else { return false }
    return value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0)
            || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
    }
}

private func plenaSafePrompt(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy { scalar in
        (scalar.value >= 0x20 && !(0x7F...0x9F).contains(scalar.value))
            || scalar.value == 0x0A
            || scalar.value == 0x0D
            || scalar.value == 0x09
    }
}

struct PlenaNodeArtifact {
    enum Status: String {
        case complete
        case blocked
    }

    let status: Status
    let summary: String
    let tests: [PlenaVerification]

    static func parse(_ data: Data, workflowID: String, nodeID: String) throws -> Self {
        let value = try JSONDecoder().decode(KeroJSONValue.self, from: data)
        let object = try plenaObject(
            value,
            keys: ["workflowId", "nodeId", "status", "summary", "changedFiles", "tests", "evidence"],
            context: "node artifact"
        )
        guard object["workflowId"]?.stringValue == workflowID,
              object["nodeId"]?.stringValue == nodeID,
              let statusName = object["status"]?.stringValue,
              let status = Status(rawValue: statusName),
              let summary = object["summary"]?.stringValue,
              !summary.isEmpty else {
            throw PlenaWorkflowError.message("artifact identity, status, or summary is invalid")
        }
        _ = try plenaStringArray(object["changedFiles"], context: "artifact.changedFiles")
        _ = try plenaStringArray(object["evidence"], context: "artifact.evidence")
        guard let tests = object["tests"]?.arrayValue else {
            throw PlenaWorkflowError.message("artifact.tests must be an array")
        }
        var parsedTests: [PlenaVerification] = []
        for test in tests {
            let item = try plenaObject(test, keys: ["argv", "exitCode"], context: "artifact test")
            guard let argv = try? plenaStringArray(item["argv"], context: "artifact test argv"),
                  !argv.isEmpty, let exitCode = item["exitCode"]?.intValue else {
                throw PlenaWorkflowError.message("artifact tests require exact argv and exitCode values")
            }
            parsedTests.append(PlenaVerification(argv: argv, exitCode: exitCode))
        }
        return Self(status: status, summary: summary, tests: parsedTests)
    }
}

struct PlenaVerification: Equatable, Sendable {
    let argv: [String]
    let exitCode: Int
}

nonisolated func plenaRunVerifications(
    _ commands: [[String]],
    root: String
) -> [PlenaVerification] {
    commands.map { argv in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: root, isDirectory: true)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            while process.isRunning && !Task.isCancelled {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if Task.isCancelled, process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
            if Task.isCancelled {
                return PlenaVerification(argv: argv, exitCode: -2)
            }
            return PlenaVerification(argv: argv, exitCode: Int(process.terminationStatus))
        } catch {
            return PlenaVerification(argv: argv, exitCode: -1)
        }
    }
}

@MainActor
final class PlenaWorkflowController: ObservableObject {
    @Published private(set) var definition: PlenaWorkflowDefinition?
    @Published private(set) var nodes: [PlenaNodeState] = []
    @Published private(set) var phase = PlenaWorkflowPhase.idle
    @Published private(set) var message = "No .plena/workflow.json"
    @Published private(set) var runID: String?

    private final class Worker {
        let index: Int
        let session: TerminalSession
        var agentLaunchDate: Date?
        var nodeID: String?

        init(index: Int, session: TerminalSession) {
            self.index = index
            self.session = session
        }
    }

    private var root: String?
    private var manifestDate: Date?
    private weak var project: Project?
    private var workers: [Worker] = []
    private var timer: Timer?
    private var verificationTasks: [String: Task<Void, Never>] = [:]

    func load(root: String, force: Bool = false) {
        guard phase != .running else { return }
        let url = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(".plena/workflow.json")
        let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        guard force || self.root != root || date != manifestDate else { return }
        self.root = root
        manifestDate = date
        runID = nil
        guard let data = try? Data(contentsOf: url) else {
            definition = nil
            nodes = []
            phase = .idle
            message = "No .plena/workflow.json"
            return
        }
        do {
            let definition = try PlenaWorkflowDefinition.parse(data)
            self.definition = definition
            nodes = definition.nodes.map {
                PlenaNodeState(
                    id: $0.id,
                    title: $0.title,
                    phase: $0.dependsOn.isEmpty ? .ready : .waiting,
                    detail: $0.dependsOn.isEmpty ? "Ready" : "Waiting for dependencies",
                    sessionID: nil
                )
            }
            phase = .idle
            message = "\(definition.nodes.count) nodes · \(definition.maxWorkers) workers"
        } catch {
            definition = nil
            nodes = []
            phase = .failed
            message = String(describing: error)
        }
    }

    func start(project: Project, root: String) {
        guard phase != .running else { return }
        verificationTasks.values.forEach { $0.cancel() }
        verificationTasks.removeAll()
        load(root: root, force: true)
        guard let definition else { return }
        let runID = UUID().uuidString.lowercased()
        let runRoot = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(".plena/runs/\(runID)/nodes", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: runRoot,
                withIntermediateDirectories: true
            )
        } catch {
            phase = .failed
            message = "Could not create run directory: \(error.localizedDescription)"
            return
        }

        self.project = project
        self.runID = runID
        nodes = definition.nodes.map {
            PlenaNodeState(
                id: $0.id,
                title: $0.title,
                phase: $0.dependsOn.isEmpty ? .ready : .waiting,
                detail: $0.dependsOn.isEmpty ? "Ready" : "Waiting for dependencies",
                sessionID: nil
            )
        }
        workers = (0..<min(definition.maxWorkers, definition.nodes.count)).map { index in
            let session = project.createWorkflowSession(directory: root)
            return Worker(index: index, session: session)
        }
        phase = .running
        message = "Run \(runID.prefix(8))"
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        guard phase == .running else { return }
        timer?.invalidate()
        timer = nil
        verificationTasks.values.forEach { $0.cancel() }
        verificationTasks.removeAll()
        for index in nodes.indices where nodes[index].phase == .running
            || nodes[index].phase == .verifying
            || nodes[index].phase == .ready {
            nodes[index].phase = .blocked
            nodes[index].detail = "Stopped by user"
        }
        phase = .blocked
        message = "Stopped"
    }

    func focus(nodeID: String) {
        guard let sessionID = nodes.first(where: { $0.id == nodeID })?.sessionID else { return }
        project?.focusWorkflowSession(sessionID)
    }

    private func tick() {
        guard phase == .running, let definition, let root, let runID else { return }
        inspectArtifacts(definition: definition, root: root, runID: runID)
        guard phase == .running else { return }

        for worker in workers {
            guard let nodeID = worker.nodeID,
                  !artifactExists(root: root, runID: runID, nodeID: nodeID),
                  let agentPhase = worker.session.agentStatus?.phase,
                  agentPhase == .blocked || agentPhase == .done || agentPhase == .idle else { continue }
            let detail = agentPhase == .blocked
                ? worker.session.agentStatus?.reason ?? "Agent blocked"
                : "Agent finished without an artifact"
            block(nodeID: nodeID, detail: detail)
            return
        }

        unlockReadyNodes(definition)
        for worker in workers where worker.agentLaunchDate == nil
            && worker.session.isShellAvailableForAutomation {
            worker.session.declareAutomationAgent(
                alias: "plena-\(worker.index + 1)",
                kind: definition.agent
            )
            worker.session.sendCommand(definition.agent.executable + "\r")
            worker.agentLaunchDate = Date()
        }
        for worker in workers {
            guard let launchDate = worker.agentLaunchDate,
                  Date().timeIntervalSince(launchDate) > 5,
                  !worker.session.isAutomationAgentRunning(kind: definition.agent),
                  worker.session.isShellAvailableForAutomation else { continue }
            phase = .failed
            message = "Worker \(worker.index + 1) could not start \(definition.agent.executable)"
            timer?.invalidate()
            timer = nil
            return
        }
        for worker in workers where worker.nodeID == nil && worker.session.isAutomationAgentRunning(kind: definition.agent) {
            guard let node = nodes.first(where: { $0.phase == .ready }),
                  let task = definition.nodes.first(where: { $0.id == node.id }) else { continue }
            assign(task, to: worker, definition: definition, root: root, runID: runID)
        }

        if nodes.allSatisfy({ $0.phase == .complete }) {
            timer?.invalidate()
            timer = nil
            phase = .complete
            message = "All \(nodes.count) artifacts verified"
        }
    }

    private func inspectArtifacts(
        definition: PlenaWorkflowDefinition,
        root: String,
        runID: String
    ) {
        for index in nodes.indices where nodes[index].phase == .running {
            let nodeID = nodes[index].id
            let url = artifactURL(root: root, runID: runID, nodeID: nodeID)
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let artifact = try PlenaNodeArtifact.parse(
                    data,
                    workflowID: definition.id,
                    nodeID: nodeID
                )
                if artifact.status == .blocked {
                    workers.first(where: { $0.nodeID == nodeID })?.nodeID = nil
                    nodes[index].phase = .blocked
                    nodes[index].detail = artifact.summary
                    phase = .blocked
                    message = "\(nodes[index].title) blocked"
                    timer?.invalidate()
                    timer = nil
                    verificationTasks.values.forEach { $0.cancel() }
                    verificationTasks.removeAll()
                    return
                }
                guard let task = definition.nodes.first(where: { $0.id == nodeID }) else {
                    throw PlenaWorkflowError.message("artifact refers to an unknown node")
                }
                nodes[index].phase = .verifying
                nodes[index].detail = "Verifying \(task.verify.count) command\(task.verify.count == 1 ? "" : "s")"
                let commands = task.verify
                let claimed = artifact.tests
                let summary = artifact.summary
                verificationTasks[nodeID] = Task.detached { [weak self] in
                    let actual = plenaRunVerifications(commands, root: root)
                    await self?.finishVerification(
                        nodeID: nodeID,
                        runID: runID,
                        claimed: claimed,
                        actual: actual,
                        summary: summary
                    )
                }
            } catch {
                nodes[index].phase = .failed
                nodes[index].detail = String(describing: error)
                phase = .failed
                message = "\(nodes[index].title) returned an invalid artifact"
                timer?.invalidate()
                timer = nil
                verificationTasks.values.forEach { $0.cancel() }
                verificationTasks.removeAll()
                return
            }
        }
    }

    private func finishVerification(
        nodeID: String,
        runID: String,
        claimed: [PlenaVerification],
        actual: [PlenaVerification],
        summary: String
    ) {
        guard phase == .running, self.runID == runID,
              let index = nodes.firstIndex(where: { $0.id == nodeID }),
              nodes[index].phase == .verifying else { return }
        verificationTasks[nodeID] = nil
        workers.first(where: { $0.nodeID == nodeID })?.nodeID = nil
        guard claimed == actual, actual.allSatisfy({ $0.exitCode == 0 }) else {
            nodes[index].phase = .failed
            nodes[index].detail = claimed == actual
                ? "Verification command failed"
                : "Artifact tests do not exactly match machine verification"
            phase = .failed
            message = "\(nodes[index].title) failed verification"
            timer?.invalidate()
            timer = nil
            verificationTasks.values.forEach { $0.cancel() }
            verificationTasks.removeAll()
            return
        }
        nodes[index].phase = .complete
        nodes[index].detail = summary
        tick()
    }

    private func unlockReadyNodes(_ definition: PlenaWorkflowDefinition) {
        let complete = Set(nodes.filter { $0.phase == .complete }.map(\.id))
        for index in nodes.indices where nodes[index].phase == .waiting {
            guard let task = definition.nodes.first(where: { $0.id == nodes[index].id }),
                  task.dependsOn.allSatisfy(complete.contains) else { continue }
            nodes[index].phase = .ready
            nodes[index].detail = "Ready"
        }
    }

    private func assign(
        _ task: PlenaWorkflowNodeDefinition,
        to worker: Worker,
        definition: PlenaWorkflowDefinition,
        root: String,
        runID: String
    ) {
        let artifact = artifactURL(root: root, runID: runID, nodeID: task.id)
        let dependencies = task.dependsOn.map {
            artifactURL(root: root, runID: runID, nodeID: $0).path
        }
        let verificationValue = KeroJSONValue.array(task.verify.map { argv in
            .array(argv.map(KeroJSONValue.string))
        })
        let verificationJSON = (try? JSONEncoder().encode(verificationValue))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let prompt = [
            "Execute this Plena workflow node in \(root).",
            "Workflow: \(definition.id)",
            "Node: \(task.id) — \(task.title)",
            "Task:",
            task.prompt,
            "Dependency artifacts:",
            dependencies.isEmpty ? "none" : dependencies.joined(separator: "\n"),
            "Completion is accepted only from an atomic JSON write to:",
            artifact.path,
            "The JSON object must contain exactly these fields:",
            "workflowId, nodeId, status, summary, changedFiles, tests, evidence",
            "workflowId must be \(definition.id); nodeId must be \(task.id).",
            "status is complete or blocked. changedFiles and evidence are string arrays.",
            "The App will independently execute these frozen verification argv arrays:",
            verificationJSON,
            "tests must exactly equal the resulting [{argv, exitCode}] array. Do not add fields.",
        ].joined(separator: "\n")

        worker.nodeID = task.id
        if let index = nodes.firstIndex(where: { $0.id == task.id }) {
            nodes[index].phase = .running
            nodes[index].detail = "Worker \(worker.index + 1)"
            nodes[index].sessionID = worker.session.id
        }
        worker.session.sendCommand("\u{1b}[200~" + prompt + "\u{1b}[201~")
        worker.session.sendCommand("\r")
        worker.session.markAutomationAgentPrompted()
    }

    private func block(nodeID: String, detail: String) {
        if let index = nodes.firstIndex(where: { $0.id == nodeID }) {
            nodes[index].phase = .blocked
            nodes[index].detail = detail
        }
        phase = .blocked
        message = "\(nodeID) blocked"
        timer?.invalidate()
        timer = nil
        verificationTasks.values.forEach { $0.cancel() }
        verificationTasks.removeAll()
    }

    private func artifactExists(root: String, runID: String, nodeID: String) -> Bool {
        FileManager.default.fileExists(atPath: artifactURL(root: root, runID: runID, nodeID: nodeID).path)
    }

    private func artifactURL(root: String, runID: String, nodeID: String) -> URL {
        URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(".plena/runs/\(runID)/nodes/\(nodeID)/result.json")
    }
}
