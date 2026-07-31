#!/usr/bin/env python3
"""样本脱敏：samples/raw/*.jsonl 与 samples/stderr-*.log → samples/sanitized/。

规则：
1. 用户主目录路径 → <HOME>；沙箱路径 → <SANDBOX>；
2. session/list 结果中非本探针创建的会话条目：sessionId/title/cwd 一律遮蔽；
3. 扫描敏感关键词（token/secret/password/bearer/api key），命中则报告行号，不静默放行。
"""
import glob
import json
import os
import re
import sys

HOME = os.path.expanduser("~")
SPIKE_DIR = os.path.dirname(os.path.abspath(__file__))
SANDBOX = os.path.join(SPIKE_DIR, "sandbox")
SAMPLES = os.path.join(SPIKE_DIR, "samples")
RAW = os.path.join(SAMPLES, "raw")
OUT = os.path.join(SAMPLES, "sanitized")

SENSITIVE = re.compile(r"(token|secret|password|bearer|api[-_ ]?key|authorization)", re.IGNORECASE)


def redact_obj(obj):
    """结构化遮蔽 session/list 中非探针会话。"""
    if isinstance(obj, dict):
        result = obj.get("result")
        if isinstance(result, dict) and isinstance(result.get("sessions"), list):
            for s in result["sessions"]:
                if isinstance(s, dict) and s.get("cwd") != SANDBOX:
                    s["sessionId"] = "<other-session-id>"
                    if "title" in s:
                        s["title"] = "<redacted>"
                    if "cwd" in s:
                        s["cwd"] = "<redacted-cwd>"
        for v in obj.values():
            redact_obj(v)
    elif isinstance(obj, list):
        for v in obj:
            redact_obj(v)
    return obj


def scrub_text(text):
    return text.replace(SANDBOX, "<SANDBOX>").replace(HOME, "<HOME>")


def main():
    os.makedirs(OUT, exist_ok=True)
    warnings = []
    inputs = sorted(glob.glob(os.path.join(RAW, "*.jsonl"))) + \
             sorted(glob.glob(os.path.join(SAMPLES, "stderr-*.log")))
    for path in inputs:
        name = os.path.basename(path)
        out_path = os.path.join(OUT, name)
        with open(path, encoding="utf-8", errors="replace") as f, \
             open(out_path, "w", encoding="utf-8") as out:
            for i, line in enumerate(f, 1):
                if SENSITIVE.search(line):
                    warnings.append(f"{name}:{i}")
                line = scrub_text(line)
                try:
                    rec = json.loads(line)
                    if isinstance(rec, dict) and isinstance(rec.get("msg"), (dict, list)):
                        rec["msg"] = redact_obj(rec["msg"])
                        line = json.dumps(rec, ensure_ascii=False) + "\n"
                except json.JSONDecodeError:
                    pass
                out.write(line)
        print(f"sanitized -> {out_path}")
    if warnings:
        print("\n!! 敏感关键词命中（需人工复核）：")
        for w in warnings:
            print("  ", w)
    else:
        print("\n敏感关键词扫描：无命中")


if __name__ == "__main__":
    main()
