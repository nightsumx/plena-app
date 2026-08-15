# Plena

A native multi-Agent workflow runner for macOS, forked from [Kero](https://github.com/egoist/kero).

Plena executes an exact behavior-to-tests DAG across a bounded pool of real terminal Agents. Only exact project artifacts plus independently executed verification commands unlock downstream work; terminal text and Agent self-reports do not.

![preview](https://kero.sh/kero-screenshot.png)

See [PLENA-WORKFLOW.md](PLENA-WORKFLOW.md) for the manifest and artifact contracts.

## Run

```sh
cp .plena/workflow.example.json .plena/workflow.json
xcodebuild -project kero.xcodeproj -scheme kero -configuration Debug build
```

Open the built Plena app, open this repository as a project, select **Flow** in the right sidebar, then press **Run**.

## What the Kero base provides

- Native AppKit interface for projects, tabs, and split panes
- libghostty by default, with an optional Alacritty backend
- Integrated browser tabs and panes
- File tree, Git status, and editable diffs
- Command palette, project-wide file search, and local path links
- AI agents can delegate background work and coordinate across Kero panes, with provider-reported status and human-controlled approvals

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md)

## License

GPLv3
