#!/usr/bin/env python3
"""Run one job of a GitHub Actions workflow on this machine.

A small, dependency-light stand-in for the GitHub runner, written for the
WildKernels build job (.github/workflows/build.yml -> build-gki). It reads the
workflow and the local composite actions (./.github/actions/*) straight from the
repository, so a local build follows exactly the same steps as the CI one.

What it supports: `run:` steps (bash/sh/python), local composite actions with
inputs/outputs, `if:` / `${{ }}` expressions (contexts inputs, env, github,
steps, runner, job; functions contains, startsWith, endsWith, format, success,
failure, always, cancelled, toJSON, fromJSON), GITHUB_ENV / GITHUB_OUTPUT /
GITHUB_PATH / GITHUB_STEP_SUMMARY, working-directory, continue-on-error.

What it does not do: remote actions (actions/checkout, upload-artifact, ...),
which are skipped, plus any step or local action named in --skip-step /
--skip-action (things that only make sense on GitHub).

usage:
  ghrun.py --workflow .github/workflows/build.yml --job build-gki \
           --inputs inputs.json --workspace /path/to/workspace
"""
import argparse
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import time

import yaml


# --------------------------------------------------------------------------
# Expressions
# --------------------------------------------------------------------------

_TOKEN = re.compile(
    r"""\s*(?:
        (?P<str>'(?:[^']|'')*')
      | (?P<num>\d+(?:\.\d+)?)
      | (?P<op>==|!=|<=|>=|&&|\|\||[!<>(),\[\].*])
      | (?P<id>[A-Za-z_][A-Za-z0-9_-]*)
    )""",
    re.X,
)


def _tokenize(text):
    pos, out = 0, []
    text = text.strip()
    while pos < len(text):
        m = _TOKEN.match(text, pos)
        if not m or m.end() == pos:
            raise ValueError(f"cannot parse expression near: {text[pos:pos + 30]!r}")
        pos = m.end()
        kind = m.lastgroup
        val = m.group(kind)
        if kind == "str":
            out.append(("lit", val[1:-1].replace("''", "'")))
        elif kind == "num":
            out.append(("lit", float(val) if "." in val else int(val)))
        elif kind == "id" and val in ("true", "false"):
            out.append(("lit", val == "true"))
        elif kind == "id" and val == "null":
            out.append(("lit", None))
        else:
            out.append((kind, val))
    return out


def truthy(v):
    if v is None or v is False:
        return False
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return v != 0 and not (isinstance(v, float) and math.isnan(v))
    if isinstance(v, str):
        return v != ""
    return True


def _num(v):
    if v is None:
        return 0.0
    if isinstance(v, bool):
        return 1.0 if v else 0.0
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        s = v.strip()
        if s == "":
            return 0.0
        try:
            return float(int(s, 0)) if s.lower().startswith("0x") else float(s)
        except ValueError:
            return float("nan")
    return float("nan")


def _eq(a, b):
    if isinstance(a, str) and isinstance(b, str):
        return a.lower() == b.lower()
    if type(a) is type(b) and not isinstance(a, (int, float)):
        return a == b
    return _num(a) == _num(b)


def to_str(v):
    if v is None:
        return ""
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    if isinstance(v, (dict, list)):
        return json.dumps(v)
    return str(v)


def _get(obj, key):
    if isinstance(obj, dict):
        if key in obj:
            return obj[key]
        low = key.lower()
        for k, v in obj.items():
            if isinstance(k, str) and k.lower() == low:
                return v
        return None
    if isinstance(obj, list) and isinstance(key, (int, float)):
        i = int(key)
        return obj[i] if 0 <= i < len(obj) else None
    return None


class _Parser:
    def __init__(self, tokens, ctx, funcs):
        self.t, self.i, self.ctx, self.funcs = tokens, 0, ctx, funcs

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else (None, None)

    def take(self, val=None):
        tok = self.peek()
        if val is not None and tok[1] != val:
            raise ValueError(f"expected {val!r}, got {tok[1]!r}")
        self.i += 1
        return tok

    def parse(self):
        v = self.p_or()
        if self.i != len(self.t):
            raise ValueError(f"unexpected token {self.peek()[1]!r}")
        return v

    def p_or(self):
        v = self.p_and()
        while self.peek()[1] == "||":
            self.take()
            r = self.p_and()
            v = v if truthy(v) else r
        return v

    def p_and(self):
        v = self.p_eq()
        while self.peek()[1] == "&&":
            self.take()
            r = self.p_eq()
            v = r if truthy(v) else v
        return v

    def p_eq(self):
        v = self.p_rel()
        while self.peek()[1] in ("==", "!="):
            op = self.take()[1]
            r = self.p_rel()
            v = _eq(v, r) if op == "==" else not _eq(v, r)
        return v

    def p_rel(self):
        v = self.p_unary()
        while self.peek()[1] in ("<", ">", "<=", ">="):
            op = self.take()[1]
            r = self.p_unary()
            a, b = (v, r) if isinstance(v, str) and isinstance(r, str) else (_num(v), _num(r))
            v = {"<": a < b, ">": a > b, "<=": a <= b, ">=": a >= b}[op]
        return v

    def p_unary(self):
        if self.peek()[1] == "!":
            self.take()
            return not truthy(self.p_unary())
        return self.p_postfix()

    def p_postfix(self):
        kind, val = self.take()
        if kind == "lit":
            v = val
        elif val == "(":
            v = self.p_or()
            self.take(")")
        elif kind == "id" and self.peek()[1] == "(":
            self.take("(")
            args = []
            if self.peek()[1] != ")":
                args.append(self.p_or())
                while self.peek()[1] == ",":
                    self.take()
                    args.append(self.p_or())
            self.take(")")
            fn = self.funcs.get(val.lower())
            if fn is None:
                raise ValueError(f"unsupported function {val}()")
            v = fn(*args)
        elif kind == "id":
            v = _get(self.ctx, val)
        else:
            raise ValueError(f"unexpected token {val!r}")
        while self.peek()[1] in (".", "["):
            if self.take()[1] == ".":
                kind, name = self.take()
                if name == "*":
                    v = list(v.values()) if isinstance(v, dict) else v
                else:
                    v = _get(v, name)
            else:
                key = self.p_or()
                self.take("]")
                v = _get(v, key)
        return v


def _contains(hay, needle):
    if isinstance(hay, list):
        return any(_eq(x, needle) for x in hay)
    return to_str(needle).lower() in to_str(hay).lower()


def _format(fmt, *args):
    return re.sub(r"\{(\d+)\}", lambda m: to_str(args[int(m.group(1))]), to_str(fmt)).replace("{{", "{").replace("}}", "}")


def evaluate(expr, ctx, job_failed=False):
    funcs = {
        "contains": _contains,
        "startswith": lambda a, b: to_str(a).lower().startswith(to_str(b).lower()),
        "endswith": lambda a, b: to_str(a).lower().endswith(to_str(b).lower()),
        "format": _format,
        "tojson": lambda v: json.dumps(v, indent=2),
        "fromjson": lambda s: json.loads(s) if s else None,
        "success": lambda: not job_failed,
        "failure": lambda: job_failed,
        "always": lambda: True,
        "cancelled": lambda: False,
        "hashfiles": lambda *a: "",
    }
    return _Parser(_tokenize(expr), ctx, funcs).parse()


_INTERP = re.compile(r"\$\{\{(.*?)\}\}", re.S)


def interpolate(value, ctx):
    if not isinstance(value, str):
        return value
    return _INTERP.sub(lambda m: to_str(evaluate(m.group(1), ctx)), value)


def eval_if(cond, ctx, job_failed):
    if cond is None:
        return not job_failed
    if isinstance(cond, bool):
        return cond and not job_failed
    text = str(cond).strip()
    m = re.fullmatch(r"\$\{\{(.*)\}\}", text, re.S)
    if m:
        text = m.group(1)
    status_fn = re.search(r"\b(success|failure|always|cancelled)\s*\(", text)
    if not status_fn:
        text = f"success() && ({text})"
    return truthy(evaluate(text, ctx, job_failed))


# --------------------------------------------------------------------------
# Runner
# --------------------------------------------------------------------------

def _parse_kv_file(path):
    out = {}
    if not os.path.exists(path):
        return out
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        i += 1
        if not line.strip():
            continue
        m = re.match(r"^([^=<]+)<<(.+)$", line)
        if m and "=" not in m.group(1):
            name, delim, buf = m.group(1), m.group(2), []
            while i < len(lines) and lines[i] != delim:
                buf.append(lines[i])
                i += 1
            i += 1
            out[name] = "\n".join(buf)
        elif "=" in line:
            k, v = line.split("=", 1)
            out[k] = v
    return out


class Runner:
    def __init__(self, workspace, repo_root, token, skip_steps, skip_actions, repository):
        self.ws = workspace
        self.repo_root = repo_root
        self.job_env = {}
        self.job_path = []
        self.job_failed = False
        self.skip_steps = {s.lower() for s in skip_steps}
        self.skip_actions = {a.strip("/").split("/")[-1].lower() for a in skip_actions}
        self.counter = 0
        self.dry_run = False
        self.tmp = os.path.join(workspace, ".ghrun")
        os.makedirs(self.tmp, exist_ok=True)
        self.summary = os.path.join(self.tmp, "step_summary.md")
        open(self.summary, "a").close()
        self.git_config = os.path.join(self.tmp, "gitconfig")
        open(self.git_config, "a").close()
        self.github = {
            "workspace": workspace,
            "repository": repository,
            "repository_owner": repository.split("/")[0],
            "token": token,
            "event_name": "workflow_dispatch",
            "server_url": "https://github.com",
            "api_url": "https://api.github.com",
            "run_id": "0",
            "run_number": "0",
            "run_attempt": "1",
            "ref_name": "local",
            "sha": "",
            "actor": "local",
            "job": "build-gki",
            "action_path": "",
        }

    def ctx(self, inputs, steps, action_path, extra_env):
        env = dict(self.job_env)
        env.update(extra_env)
        gh = dict(self.github, action_path=action_path or "")
        return {
            "inputs": inputs,
            "env": env,
            "github": gh,
            "steps": steps,
            "runner": {"os": "Linux", "arch": "X64", "temp": self.tmp, "name": "local"},
            "job": {"status": "failure" if self.job_failed else "success"},
            "matrix": {},
            "vars": {},
            "secrets": {},
        }

    def run_steps(self, steps, inputs, action_path=None, inherited_env=None, depth=0):
        steps_ctx = {}
        inherited_env = dict(inherited_env or {})
        for step in steps:
            name = step.get("name") or step.get("uses") or (step.get("run") or "").strip().splitlines()[0][:60]
            sid = step.get("id")
            ctx = self.ctx(inputs, steps_ctx, action_path, inherited_env)
            indent = "  " * depth
            try:
                run_it = eval_if(step.get("if"), ctx, self.job_failed)
            except ValueError as e:
                print(f"{indent}!! cannot evaluate if: {step.get('if')!r}: {e}", flush=True)
                raise
            uses = step.get("uses", "")
            skip_reason = None
            if not run_it:
                skip_reason = "condition false"
            elif name.lower() in self.skip_steps:
                skip_reason = "GitHub-only step"
            elif uses and not uses.startswith("./"):
                skip_reason = f"remote action {uses}"
            elif uses and uses.strip("/").split("/")[-1].lower() in self.skip_actions:
                skip_reason = "GitHub-only action"
            if skip_reason:
                print(f"{indent}-- skip: {name} ({skip_reason})", flush=True)
                if sid:
                    steps_ctx[sid] = {"outputs": {}, "outcome": "skipped", "conclusion": "skipped"}
                continue

            self.counter += 1
            print(f"\n{indent}==> [{self.counter}] {name}", flush=True)
            step_env = dict(inherited_env)
            for k, v in (step.get("env") or {}).items():
                step_env[k] = to_str(interpolate(v, ctx))
            ok, outputs = True, {}
            failed_before = self.job_failed
            try:
                if uses:
                    ok, outputs = self.run_action(uses, step.get("with") or {}, ctx, step_env, depth)
                else:
                    ok, outputs = self.run_shell(step, ctx, step_env, action_path)
            except Exception as e:  # expression/IO errors fail the step like on GitHub
                print(f"{indent}!! step error: {e}", flush=True)
                ok = False
            outcome = "success" if ok else "failure"
            conclusion = outcome
            if not ok and truthy(interpolate(step.get("continue-on-error", False), ctx)):
                conclusion = "success"
                self.job_failed = failed_before  # a failing composite already flagged the job
                print(f"{indent}   (failed, continue-on-error)", flush=True)
            elif not ok:
                self.job_failed = True
                print(f"{indent}!! FAILED: {name}", flush=True)
            if sid:
                steps_ctx[sid] = {"outputs": outputs, "outcome": outcome, "conclusion": conclusion}
        return steps_ctx

    def run_action(self, uses, with_, ctx, step_env, depth):
        path = os.path.normpath(os.path.join(self.ws, uses))
        meta_file = next((os.path.join(path, n) for n in ("action.yml", "action.yaml") if os.path.exists(os.path.join(path, n))), None)
        if not meta_file:
            raise FileNotFoundError(f"no action.yml in {path}")
        meta = yaml.safe_load(open(meta_file, encoding="utf-8"))
        runs = meta.get("runs") or {}
        if runs.get("using") != "composite":
            raise RuntimeError(f"{uses}: only composite actions are supported")
        inputs = {}
        for k, spec in (meta.get("inputs") or {}).items():
            spec = spec or {}
            if k in with_:
                inputs[k] = to_str(interpolate(with_[k], ctx))
            elif "default" in spec:
                inputs[k] = to_str(interpolate(spec["default"], ctx))
            else:
                inputs[k] = ""
        for k, v in with_.items():
            inputs.setdefault(k, to_str(interpolate(v, ctx)))
        failed_before = self.job_failed
        inner = self.run_steps(runs.get("steps") or [], inputs, path, step_env, depth + 1)
        ok = not (self.job_failed and not failed_before)
        out_ctx = self.ctx(inputs, inner, path, step_env)
        outputs = {}
        for k, spec in (meta.get("outputs") or {}).items():
            val = spec.get("value") if isinstance(spec, dict) else spec
            outputs[k] = to_str(interpolate(val, out_ctx))
        return ok, outputs

    def run_shell(self, step, ctx, step_env, action_path):
        script = interpolate(step["run"], ctx)
        if self.dry_run:
            return True, {}
        shell = (step.get("shell") or "").strip()
        wd = interpolate(step.get("working-directory") or "", ctx) or self.ws
        if not os.path.isabs(wd):
            wd = os.path.join(self.ws, wd)
        n = self.counter
        files = {k: os.path.join(self.tmp, f"{k}_{n}") for k in ("env", "output", "path")}
        for f in files.values():
            open(f, "w").close()
        ext = ".py" if shell.startswith("python") else ".sh"
        sfile = os.path.join(self.tmp, f"step_{n}{ext}")
        with open(sfile, "w", encoding="utf-8", newline="\n") as f:
            f.write(script)
        if shell in ("", "bash"):
            cmd = ["bash", "--noprofile", "--norc", "-eo", "pipefail", sfile] if shell else ["bash", "-e", sfile]
        elif shell == "sh":
            cmd = ["sh", "-e", sfile]
        elif shell.startswith("python"):
            cmd = ["python3", sfile]
        elif "{0}" in shell:
            cmd = shell.replace("{0}", sfile).split()
        else:
            cmd = [shell, sfile]

        env = dict(os.environ)
        env.update(self.job_env)
        env.update(step_env)
        env.update({
            "CI": "true",
            "GITHUB_ACTIONS": "true",
            "GITHUB_WORKSPACE": self.ws,
            "GITHUB_REPOSITORY": self.github["repository"],
            "GITHUB_REPOSITORY_OWNER": self.github["repository_owner"],
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_SERVER_URL": self.github["server_url"],
            "GITHUB_API_URL": self.github["api_url"],
            "GITHUB_RUN_ID": "0",
            "GITHUB_RUN_NUMBER": "0",
            "GITHUB_ENV": files["env"],
            "GITHUB_OUTPUT": files["output"],
            "GITHUB_PATH": files["path"],
            "GITHUB_STEP_SUMMARY": self.summary,
            "GITHUB_ACTION_PATH": action_path or "",
            "RUNNER_OS": "Linux",
            "RUNNER_ARCH": "X64",
            "RUNNER_TEMP": self.tmp,
            # keep the workflow's `git config --global` away from the user's ~/.gitconfig
            "GIT_CONFIG_GLOBAL": self.git_config,
        })
        if self.job_path:
            env["PATH"] = os.pathsep.join(list(reversed(self.job_path)) + [env.get("PATH", "")])
        os.makedirs(wd, exist_ok=True)
        t0 = time.time()
        rc = subprocess.call(cmd, cwd=wd, env=env)
        print(f"   (exit {rc}, {time.time() - t0:.0f}s)", flush=True)

        self.job_env.update(_parse_kv_file(files["env"]))
        with open(files["path"], encoding="utf-8", errors="replace") as f:
            self.job_path.extend(p.strip() for p in f if p.strip())
        return rc == 0, _parse_kv_file(files["output"])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--workflow", required=True)
    ap.add_argument("--job", required=True)
    ap.add_argument("--inputs", required=True, help="JSON file with the workflow_call inputs")
    ap.add_argument("--workspace", required=True, help="repository checkout the job runs in")
    ap.add_argument("--repository", default="local/GKI_KernelSU_SUSFS")
    ap.add_argument("--skip-step", action="append", default=[], help="step name to skip (repeatable)")
    ap.add_argument("--skip-action", action="append", default=[], help="local action dir name to skip (repeatable)")
    ap.add_argument("--dry-run", action="store_true", help="evaluate conditions and list the steps, run nothing")
    args = ap.parse_args()

    ws = os.path.abspath(args.workspace)
    wf = yaml.safe_load(open(os.path.join(ws, args.workflow), encoding="utf-8"))
    on = wf.get(True) or wf.get("on") or {}
    spec = (on.get("workflow_call") or on.get("workflow_dispatch") or {}).get("inputs") or {}
    given = json.load(open(args.inputs, encoding="utf-8"))
    inputs = {}
    for k, s in spec.items():
        s = s or {}
        v = given.get(k, s.get("default", ""))
        t = s.get("type", "string")
        if t == "boolean":
            v = v if isinstance(v, bool) else to_str(v).lower() == "true"
        elif t == "number":
            v = _num(v)
        else:
            v = to_str(v)
        inputs[k] = v
    unknown = set(given) - set(spec)
    if unknown:
        print(f"warning: inputs not declared by the workflow: {sorted(unknown)}", flush=True)

    job = wf["jobs"][args.job]
    runner = Runner(ws, ws, os.environ.get("GITHUB_TOKEN", ""), args.skip_step, args.skip_action, args.repository)
    runner.dry_run = args.dry_run
    runner.job_env.update({k: to_str(v) for k, v in (job.get("env") or {}).items()})
    t0 = time.time()
    runner.run_steps(job["steps"], inputs)
    mins = (time.time() - t0) / 60
    print(f"\n==== job {'FAILED' if runner.job_failed else 'succeeded'} in {mins:.1f} min", flush=True)
    sys.exit(1 if runner.job_failed else 0)


if __name__ == "__main__":
    main()
