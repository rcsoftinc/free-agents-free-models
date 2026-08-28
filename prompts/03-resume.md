# Continue after an interruption

Pick up where we left off. First:

```
.free-agents/bin/fa status
```

That reads the run journal, which is the source of truth — not your memory of this
session and not what the files look like.

Then `.free-agents/bin/fa resume` to re-dispatch whatever is unfinished. Completed
tasks are not re-run.

Tell me what was still outstanding before you continue.
