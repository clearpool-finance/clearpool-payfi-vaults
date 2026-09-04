#!/usr/bin/env python3
"""harness-config-validate.py <config> — fail loud on any shape the gate cannot run safely."""
import json,re,sys
p=sys.argv[1]; errs=[]
try: cfg=json.load(open(p))
except Exception as e: print(f"config: not valid JSON ({e}) — remember: no // comments",file=sys.stderr); sys.exit(1)
g=cfg.get("gate") or {}
for k in ("changed_patterns","gate","evidence_dir"):
    if k not in cfg: errs.append(f"missing key {k!r}")
if not cfg.get("changed_patterns"): errs.append("changed_patterns must be a non-empty list — an empty list silently disables the heavy stage forever")
for pat in cfg.get("changed_patterns",[]):
    try: re.compile(pat)
    except re.error as e: errs.append(f"changed_patterns {pat!r}: {e}")
    if not (pat.startswith("^") or pat.endswith("$")): errs.append(f"changed_patterns {pat!r}: must be anchored (^ or $)")
for stage in ("fast","heavy"):
    cmds=g.get(stage)
    if not isinstance(cmds,list) or not cmds: errs.append(f"gate.{stage}: must be a non-empty list"); continue
    for c in cmds:
        if isinstance(c,list): 
            if not c or not all(isinstance(x,str) for x in c): errs.append(f"gate.{stage}: argv entries must be non-empty lists of strings")
        elif isinstance(c,str):
            if "|" in c: errs.append(f"gate.{stage}: {c!r} pipes — exit code would be masked; make it an argv list")
        else: errs.append(f"gate.{stage}: {c!r} must be an argv list or a string")
if "lock_deadline_sec" not in g: errs.append("gate.lock_deadline_sec is required")
ht=g.get("heavy_timeout_sec",300); ld=g.get("lock_deadline_sec",600)
if not (isinstance(ht,int) and isinstance(ld,int)): errs.append("heavy_timeout_sec / lock_deadline_sec must be integers")
elif ld < 2*ht: errs.append(f"lock_deadline_sec ({ld}) must be >= 2 x heavy_timeout_sec ({ht}) or a live heavy stage can be reaped mid-run")
tc=cfg.get("test_census")
if tc is not None and not (isinstance(tc,dict) and isinstance(tc.get("cmd"),list) and isinstance(tc.get("count_pattern"),str)): errs.append("test_census must be {cmd: [argv], count_pattern: regex}")
for k in ("interpreter",):
    v=cfg.get(k)
    if v and (v.startswith("/") or ".." in v): errs.append(f"{k} must be repo-relative with no '..' ({v!r})")
if errs: print("config:", *errs, sep="\n  ", file=sys.stderr); sys.exit(1)
