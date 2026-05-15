#!/usr/bin/env python3
"""Grade spec-writing iteration-2 with updated Document Skeleton."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
# Reuse iter-1 grading logic but retarget paths
import grade as g1

g1.WORKSPACE = Path("/home/jan/repos/b3tchi/acag/main/infinifu/skills/spec-writing-workspace/iteration-2")
g1.EVAL_DIR = g1.WORKSPACE / "eval-impl-plan"
g1.SANDBOX = g1.EVAL_DIR / "with_skill" / "sandbox"

if __name__ == "__main__":
    g1.main()
