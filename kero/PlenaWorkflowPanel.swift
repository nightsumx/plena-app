//
//  PlenaWorkflowPanel.swift
//  kero
//

import AppKit
import SwiftUI

@MainActor
final class PlenaWorkflowPanelView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Workflow")
    private let statusLabel = NSTextField(labelWithString: "")
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let runButton = NSButton(title: "Run", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let nodeStack = NSStackView()
    private weak var controller: PlenaWorkflowController?
    private weak var project: Project?
    private var root = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        for button in [reloadButton, runButton, stopButton] {
            button.bezelStyle = .roundRect
            button.controlSize = .small
            button.target = self
        }
        reloadButton.action = #selector(reload)
        runButton.action = #selector(run)
        stopButton.action = #selector(stop)

        let labels = NSStackView(views: [titleLabel, statusLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.setHuggingPriority(.defaultLow, for: .horizontal)

        let controls = NSStackView(views: [reloadButton, runButton, stopButton])
        controls.orientation = .horizontal
        controls.spacing = 5
        controls.setHuggingPriority(.required, for: .horizontal)

        let header = NSStackView(views: [labels, controls])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        nodeStack.orientation = .vertical
        nodeStack.alignment = .leading
        nodeStack.spacing = 2
        nodeStack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 8, right: 6)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = nodeStack

        let layout = NSStackView(views: [header, scroll])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 6
        layout.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layout)

        header.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        nodeStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            layout.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            layout.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            layout.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: layout.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: layout.widthAnchor),
            nodeStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(controller: PlenaWorkflowController, project: Project, root: String) {
        self.controller = controller
        self.project = project
        self.root = root
        titleLabel.stringValue = controller.definition?.title ?? "Workflow"
        statusLabel.stringValue = controller.message
        reloadButton.isEnabled = controller.phase != .running
        runButton.isEnabled = controller.definition != nil && controller.phase != .running
        stopButton.isHidden = controller.phase != .running

        for view in nodeStack.arrangedSubviews {
            nodeStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if controller.nodes.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: controller.message)
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            empty.maximumNumberOfLines = 0
            empty.translatesAutoresizingMaskIntoConstraints = false
            nodeStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: nodeStack.widthAnchor, constant: -12).isActive = true
            return
        }
        for node in controller.nodes {
            nodeStack.addArrangedSubview(nodeRow(node))
        }
    }

    private func nodeRow(_ node: PlenaNodeState) -> NSView {
        let button = NSButton(title: node.title, target: self, action: #selector(focusNode(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(node.id)
        button.isBordered = false
        button.alignment = .left
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol(for: node.phase), accessibilityDescription: node.phase.rawValue)
        button.imagePosition = .imageLeading
        button.isEnabled = node.sessionID != nil
        button.lineBreakMode = .byTruncatingTail

        let detail = NSTextField(labelWithString: node.detail)
        detail.font = .systemFont(ofSize: 9)
        detail.textColor = color(for: node.phase)
        detail.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [button, detail])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 0
        row.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        row.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -8),
            detail.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -8),
            row.widthAnchor.constraint(equalTo: nodeStack.widthAnchor, constant: -12),
        ])
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel("\(node.title), \(node.phase.rawValue), \(node.detail)")
        return row
    }

    private func symbol(for phase: PlenaNodePhase) -> String {
        switch phase {
        case .waiting: return "clock"
        case .ready: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .verifying: return "checkmark.seal"
        case .complete: return "checkmark.circle.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func color(for phase: PlenaNodePhase) -> NSColor {
        switch phase {
        case .complete: return .systemGreen
        case .blocked: return .systemOrange
        case .failed: return .systemRed
        case .running, .verifying: return .controlAccentColor
        case .waiting, .ready: return .secondaryLabelColor
        }
    }

    @objc private func reload() {
        controller?.load(root: root, force: true)
    }

    @objc private func run() {
        guard let controller, let project else { return }
        controller.start(project: project, root: root)
    }

    @objc private func stop() {
        controller?.stop()
    }

    @objc private func focusNode(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        controller?.focus(nodeID: id)
    }
}

struct PlenaWorkflowPanelRepresentable: NSViewRepresentable {
    @ObservedObject var controller: PlenaWorkflowController
    let project: Project
    let root: String

    func makeNSView(context: Context) -> PlenaWorkflowPanelView {
        PlenaWorkflowPanelView(frame: .zero)
    }

    func updateNSView(_ view: PlenaWorkflowPanelView, context: Context) {
        view.update(controller: controller, project: project, root: root)
    }
}
