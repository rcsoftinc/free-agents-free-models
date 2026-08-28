# Build the plan

Execute the plan we agreed.

If it is already in `.orch/tasks.json`:
```
.free-agents/bin/fa orch run
```

Otherwise write it there first, in this shape:
```json
{"tasks":[{"id":"slug","prompt":"self-contained instruction","deps":[],"files":["path"],"category":"coding"}]}
```

Rules while it runs:
- Do not re-architect what a worker produced. Fix integration gaps only.
- Verify by running the tests/build, not by re-reading every file.
- A worker reporting success is **not** evidence the work happened. Check the files.
- If a task failed, read `.orch/results/<id>.err` before retrying it.

Report what completed, what failed, and what you had to fix.
