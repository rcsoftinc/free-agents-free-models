# One task, no orchestration

Do this directly. Do not split it, do not spawn anything.

TASK: <describe it>

If you hit a rate limit, do not stop — hand the task to the fallback engine, which
walks every healthy credential:

```
.free-agents/bin/fa run "<the task, self-contained>"
```
