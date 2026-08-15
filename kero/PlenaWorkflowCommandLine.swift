//
//  PlenaWorkflowCommandLine.swift
//  kero
//

import Foundation

enum PlenaWorkflowCommandLine {
    static func run(arguments: [String]) throws {
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] {
            print("""
                Usage:
                  kero +workflow validate [path-to-workflow.json]
                  kero +workflow check <workflow.json> <node-id> <result.json> [project-root]
                """)
            return
        }
        if arguments.first == "check" {
            try check(arguments: Array(arguments.dropFirst()))
            return
        }
        guard arguments.first == "validate", arguments.count <= 2 else {
            throw CLIError.message("Run `kero +workflow --help` for usage")
        }
        let path = arguments.count == 2
            ? arguments[1]
            : FileManager.default.currentDirectoryPath
        var directory: ObjCBool = false
        let url = FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
            ? URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(".plena/workflow.json")
            : URL(fileURLWithPath: path)
        do {
            let definition = try PlenaWorkflowDefinition.parse(Data(contentsOf: url))
            let result = KeroJSONValue.object([
                "agent": .string(definition.agent.rawValue),
                "id": .string(definition.id),
                "max_workers": .number(Double(definition.maxWorkers)),
                "nodes": .array(definition.nodes.map { .string($0.id) }),
                "path": .string(url.path),
                "valid": .bool(true),
            ])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(result))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            throw CLIError.message("Invalid workflow: \(error)")
        }
    }

    private static func check(arguments: [String]) throws {
        guard arguments.count == 3 || arguments.count == 4 else {
            throw CLIError.message("Run `kero +workflow --help` for usage")
        }
        do {
            let definition = try PlenaWorkflowDefinition.parse(
                Data(contentsOf: URL(fileURLWithPath: arguments[0]))
            )
            let nodeID = arguments[1]
            guard let node = definition.nodes.first(where: { $0.id == nodeID }) else {
                throw CLIError.message("Unknown workflow node: \(nodeID)")
            }
            let artifact = try PlenaNodeArtifact.parse(
                Data(contentsOf: URL(fileURLWithPath: arguments[2])),
                workflowID: definition.id,
                nodeID: nodeID
            )
            guard artifact.status == .complete else {
                throw CLIError.message("Artifact status is blocked")
            }
            let root = arguments.count == 4
                ? arguments[3]
                : FileManager.default.currentDirectoryPath
            let actual = plenaRunVerifications(node.verify, root: root)
            guard artifact.tests == actual else {
                throw CLIError.message("Artifact tests do not exactly match machine verification")
            }
            guard actual.allSatisfy({ $0.exitCode == 0 }) else {
                throw CLIError.message("A verification command failed")
            }
            let result = KeroJSONValue.object([
                "node": .string(nodeID),
                "tests": .array(actual.map { verification in
                    .object([
                        "argv": .array(verification.argv.map(KeroJSONValue.string)),
                        "exitCode": .number(Double(verification.exitCode)),
                    ])
                }),
                "valid": .bool(true),
                "workflow": .string(definition.id),
            ])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(result))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.message("Invalid workflow artifact: \(error)")
        }
    }
}
