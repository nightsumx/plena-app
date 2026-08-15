# Plena workflow

Plena reads one exact DAG from `<project>/.plena/workflow.json`, maps every ready node onto at most `maxWorkers` real Kero terminals, and unlocks dependencies only after an exact artifact passes validation.

```json
{
  "version": 1,
  "id": "editor-paste",
  "title": "Editor paste closure",
  "agent": "codex",
  "maxWorkers": 3,
  "nodes": [
    {
      "id": "explore-a",
      "title": "Explore behavior space",
      "prompt": "Inventory paste axes and write a proposed Behavior Atlas.",
      "dependsOn": [],
      "verify": []
    },
    {
      "id": "critic",
      "title": "Find missing behavior",
      "prompt": "Read the exploration artifact and report every missing axis, crossing, and unresolved product decision.",
      "dependsOn": ["explore-a"],
      "verify": [
        ["/usr/bin/git", "diff", "--check"]
      ]
    }
  ]
}
```

The manifest rejects unknown fields, duplicate IDs, unknown dependencies, self-dependencies, cycles, unsupported agents, unsafe prompt controls, and invalid worker counts. Validate it without opening the app:

```sh
kero +workflow validate .plena/workflow.json
```

The same artifact and process gate can run headlessly:

```sh
kero +workflow check .plena/workflow.json node-id result.json /absolute/project/root
```

Each run receives a new ID. A node completes only by atomically writing:

```text
.plena/runs/<run-id>/nodes/<node-id>/result.json
```

The artifact has exactly this shape:

```json
{
  "workflowId": "editor-paste",
  "nodeId": "explore-a",
  "status": "complete",
  "summary": "Atlas proposal written",
  "changedFiles": ["docs/paste-atlas.json"],
  "tests": [
    { "argv": ["/usr/bin/git", "diff", "--check"], "exitCode": 0 }
  ],
  "evidence": ["docs/paste-atlas.json"]
}
```

`status` is `complete` or `blocked`. For `complete`, the app executes every frozen `verify` argv without a shell and requires `tests` to equal every actual argv and exit code. Every exit code must be zero. Terminal text and an Agent lifecycle `done` state never unlock downstream nodes. Invalid, partial, stale, extra, self-reported, or failing results fail the run.
