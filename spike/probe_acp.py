#!/usr/bin/env python3
"""G0 ACP 探针：以 JSON-RPC over stdio 驱动 `kimi acp`，采集协议事件样本。

用法：
  python3 probe_acp.py baseline   # 握手/session/流式/list/resume/load
  python3 probe_acp.py perms      # 工具调用 + permission 放行/拒绝（不声明 fs 能力）
  python3 probe_acp.py fsrpc      # 声明 fs.readTextFile 能力，采样文件读取反向 RPC
  python3 probe_acp.py lifecycle  # 握手失败/未知方法/崩溃/stdin 关闭
  python3 probe_acp.py seed       # 长背景播种（多档长度）

输出：samples/raw/<run>-<ts>.jsonl（全量收发记录，含方向与时间戳）
      samples/stderr-<run>-<ts>.log（子进程 stderr）
所有文件内容均为探针自建沙箱内容，不含真实项目数据。
"""
import json
import os
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime

KIMI = os.path.expanduser("~/.kimi-code/bin/kimi")
SPIKE_DIR = os.path.dirname(os.path.abspath(__file__))
SANDBOX = os.path.join(SPIKE_DIR, "sandbox")
SAMPLES = os.path.join(SPIKE_DIR, "samples")
RAW = os.path.join(SAMPLES, "raw")

READ_SEED = os.path.join(SANDBOX, "readme_seed.txt")
WRITE_TARGET = os.path.join(SANDBOX, "created_by_agent.txt")

PROTOCOL_VERSION = 1


class AcpProbe:
    def __init__(self, run_name, fs_read=False, fs_write=False):
        os.makedirs(RAW, exist_ok=True)
        ts = datetime.now().strftime("%Y%m%d-%H%M%S")
        self.log_path = os.path.join(RAW, f"{run_name}-{ts}.jsonl")
        self.err_path = os.path.join(SAMPLES, f"stderr-{run_name}-{ts}.log")
        self._err = open(self.err_path, "wb")
        self.proc = subprocess.Popen(
            [KIMI, "acp"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self._err,
            text=True,
            bufsize=1,
        )
        self._log = open(self.log_path, "a", encoding="utf-8")
        self._write_lock = threading.Lock()
        self._pending = {}          # id -> dict(event, msg)
        self._pending_lock = threading.Lock()
        self.notifications = []     # 收到的通知（session/update 等）
        self.agent_requests = []    # 收到的 agent→client 请求
        self.eof = threading.Event()
        self.fs_read = fs_read
        self.fs_write = fs_write
        self.permission_policy = "allow_once"   # perms 场景动态切换
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()

    # ---------- 底层收发 ----------
    def _record(self, direction, obj):
        line = {"ts": datetime.now().isoformat(timespec="milliseconds"), "dir": direction, "msg": obj}
        with self._write_lock:
            self._log.write(json.dumps(line, ensure_ascii=False) + "\n")
            self._log.flush()

    def _send(self, obj):
        data = json.dumps(obj, ensure_ascii=False)
        self._record("out", obj)
        with self._write_lock:
            try:
                self.proc.stdin.write(data + "\n")
                self.proc.stdin.flush()
            except (BrokenPipeError, ValueError) as e:
                self._record("local", {"event": "send_failed", "error": str(e)})

    def _read_loop(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                self._record("in-raw", line)
                continue
            self._record("in", msg)
            self._dispatch(msg)
        self._record("local", {"event": "stdout_eof", "returncode": self.proc.poll()})
        self.eof.set()
        with self._pending_lock:
            for p in self._pending.values():
                p["msg"] = {"error": {"code": "transport_closed", "message": "stdout EOF"}}
                p["event"].set()

    def _dispatch(self, msg):
        if "method" in msg and "id" in msg:
            # agent → client 请求，需要应答
            self.agent_requests.append(msg)
            self._handle_agent_request(msg)
        elif "method" in msg:
            self.notifications.append(msg)
        elif "id" in msg:
            with self._pending_lock:
                p = self._pending.get(msg["id"])
            if p:
                p["msg"] = msg
                p["event"].set()

    def _handle_agent_request(self, msg):
        method = msg["method"]
        if method == "session/request_permission":
            options = msg.get("params", {}).get("options", [])
            chosen = None
            for opt in options:
                if opt.get("kind") == self.permission_policy:
                    chosen = opt
                    break
            if chosen is None:  # 兜底：按策略选首个 allow/reject
                prefix = "allow" if self.permission_policy.startswith("allow") else "reject"
                for opt in options:
                    if str(opt.get("kind", "")).startswith(prefix):
                        chosen = opt
                        break
            if chosen is None and options:
                chosen = options[0]
            if chosen is None:
                result = {"outcome": {"outcome": "cancelled"}}
            else:
                result = {"outcome": {"outcome": "selected", "optionId": chosen["optionId"]}}
            self._send({"jsonrpc": "2.0", "id": msg["id"], "result": result})
        elif method == "fs/read_text_file":
            path = msg.get("params", {}).get("path", "")
            try:
                with open(path, "r", encoding="utf-8") as f:
                    content = f.read()
                self._send({"jsonrpc": "2.0", "id": msg["id"], "result": {"content": content}})
            except Exception as e:
                self._send({"jsonrpc": "2.0", "id": msg["id"],
                            "error": {"code": -32602, "message": f"probe read failed: {e}"}})
        elif method == "fs/write_text_file":
            # 本探针默认不写盘，直接拒绝，观察 agent 反应
            self._send({"jsonrpc": "2.0", "id": msg["id"],
                        "error": {"code": -32000, "message": "probe policy: write denied"}})
        else:
            self._send({"jsonrpc": "2.0", "id": msg["id"],
                        "error": {"code": -32601, "message": f"probe does not implement {method}"}})

    def rpc(self, method, params=None, timeout=180):
        req_id = f"probe-{time.time_ns()}"
        ev = threading.Event()
        with self._pending_lock:
            self._pending[req_id] = {"event": ev, "msg": None}
        self._send({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params or {}})
        if not ev.wait(timeout):
            with self._pending_lock:
                self._pending.pop(req_id, None)
            self._record("local", {"event": "rpc_timeout", "method": method, "timeout": timeout})
            return {"error": {"code": "probe_timeout", "message": f"{method} timed out after {timeout}s"}}
        with self._pending_lock:
            entry = self._pending.pop(req_id, None)
        return (entry or {}).get("msg") or {}

    def notify(self, method, params=None):
        self._send({"jsonrpc": "2.0", "method": method, "params": params or {}})

    # ---------- 协议步骤 ----------
    def initialize(self, protocol_version=PROTOCOL_VERSION):
        return self.rpc("initialize", {
            "protocolVersion": protocol_version,
            "clientCapabilities": {
                "fs": {"readTextFile": self.fs_read, "writeTextFile": self.fs_write},
                "terminal": False,
            },
            "clientInfo": {"name": "g0-probe", "title": "G0 Probe", "version": "0.1.0"},
        })

    def session_new(self, cwd=SANDBOX):
        return self.rpc("session/new", {"cwd": cwd, "mcpServers": []})

    def prompt(self, session_id, text, timeout=180):
        t0 = time.monotonic()
        before = len(self.notifications)
        resp = self.rpc("session/prompt",
                        {"sessionId": session_id, "prompt": [{"type": "text", "text": text}]},
                        timeout=timeout)
        dt = time.monotonic() - t0
        new_notifs = self.notifications[before:]
        chunks = [n for n in new_notifs
                  if n.get("params", {}).get("update", {}).get("sessionUpdate") == "agent_message_chunk"]
        first_chunk_dt = None
        # 从原始日志估算首 chunk 时间（粗略：用通知列表顺序即可，精确值在 jsonl 里）
        self._record("local", {
            "event": "prompt_summary", "sessionId": session_id,
            "duration_s": round(dt, 2), "notifications": len(new_notifs),
            "agent_message_chunks": len(chunks),
            "agent_requests_during": len(self.agent_requests),
            "stopReason": (resp.get("result") or {}).get("stopReason"),
            "error": resp.get("error"),
        })
        return resp

    def close(self):
        try:
            if self.proc.poll() is None:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
        finally:
            self._record("local", {"event": "probe_close", "returncode": self.proc.poll()})
            self._log.close()
            self._err.close()


def ensure_sandbox():
    os.makedirs(SANDBOX, exist_ok=True)
    if not os.path.exists(READ_SEED):
        with open(READ_SEED, "w", encoding="utf-8") as f:
            f.write("第一行：这是 G0 探针自建的种子文件。\n第二行：用于采样读文件工具调用。\n第三行：不包含任何真实项目内容。\n")


def get_session_id(resp):
    return (resp.get("result") or {}).get("sessionId")


# ================= 场景 =================

def run_baseline():
    ensure_sandbox()
    p = AcpProbe("baseline")
    print("[baseline] initialize ->", json.dumps(p.initialize(), ensure_ascii=False)[:600])
    r = p.session_new()
    print("[baseline] session/new ->", json.dumps(r, ensure_ascii=False)[:600])
    sid = get_session_id(r)
    if not sid:
        # 未登录等情况：尝试 authenticate(methodId=login) 后重试
        print("[baseline] session/new failed, try authenticate login ->",
              json.dumps(p.rpc("authenticate", {"methodId": "login"}), ensure_ascii=False)[:300])
        r = p.session_new()
        sid = get_session_id(r)
    if sid:
        p.prompt(sid, "用一句话回答：2+2 等于几？不要调用任何工具。")
        print("[baseline] session/list ->", json.dumps(p.rpc("session/list", {}), ensure_ascii=False)[:800])
        print("[baseline] session/resume ->",
              json.dumps(p.rpc("session/resume", {"sessionId": sid, "cwd": SANDBOX, "mcpServers": []}),
                         ensure_ascii=False)[:400])
        before = len(p.notifications)
        lr = p.rpc("session/load", {"sessionId": sid, "cwd": SANDBOX, "mcpServers": []})
        replayed = len(p.notifications) - before
        p._record("local", {"event": "session_load_replay", "replayed_notifications": replayed})
        print("[baseline] session/load ->", json.dumps(lr, ensure_ascii=False)[:300],
              f"(replayed {replayed} notifications)")
    p.close()
    print(f"[baseline] log: {p.log_path}")


def run_perms():
    ensure_sandbox()
    if os.path.exists(WRITE_TARGET):
        os.remove(WRITE_TARGET)
    p = AcpProbe("perms")  # 不声明 fs 能力
    p.initialize()
    sid = get_session_id(p.session_new())
    if not sid:
        print("[perms] no session, abort"); p.close(); return
    # 读文件：预期 permission 请求 -> allow_once
    p.permission_policy = "allow_once"
    p.prompt(sid, f"请使用工具读取文件 {READ_SEED}，并告诉我它的第一行内容。")
    # 写文件：预期 permission 请求 -> reject_once
    p.permission_policy = "reject_once"
    p.prompt(sid, f"请在 {SANDBOX} 目录下创建文件 created_by_agent.txt，内容为 hello world。")
    p._record("local", {"event": "write_target_exists_after_reject",
                        "exists": os.path.exists(WRITE_TARGET)})
    print(f"[perms] write target exists after reject: {os.path.exists(WRITE_TARGET)}")
    p.close()
    print(f"[perms] log: {p.log_path}")


def run_terminal():
    """SEC-08 关键场景：终端命令是否经过 session/request_permission。"""
    ensure_sandbox()
    p = AcpProbe("terminal")  # 不声明 terminal 能力（与应用一致）
    p.initialize()
    sid = get_session_id(p.session_new())
    if not sid:
        print("[terminal] no session, abort"); p.close(); return
    p.permission_policy = "reject_once"  # 若有 permission 请求一律拒绝
    marker = os.path.join(SANDBOX, "terminal_marker.txt")
    if os.path.exists(marker):
        os.remove(marker)
    p.prompt(sid, f"请执行终端命令 touch {marker}，然后告诉我命令是否执行成功。")
    p._record("local", {"event": "terminal_marker_exists_after_reject",
                        "exists": os.path.exists(marker)})
    print(f"[terminal] marker exists after reject: {os.path.exists(marker)}")
    p.close()
    print(f"[terminal] log: {p.log_path}")


def run_loadreplay():
    """复核 session/load 的历史重放时序：load 后等待 5s 再统计通知。"""
    ensure_sandbox()
    target = sys.argv[2] if len(sys.argv) > 2 else None
    p = AcpProbe("loadreplay")
    p.initialize()
    if not target:
        lst = p.rpc("session/list", {})
        sessions = (lst.get("result") or {}).get("sessions", [])
        own = [s for s in sessions if s.get("cwd") == SANDBOX and s.get("title") != "New Session"]
        if not own:
            print("[loadreplay] no prior session with history, abort"); p.close(); return
        target = own[0]["sessionId"]
    before = len(p.notifications)
    lr = p.rpc("session/load", {"sessionId": target, "cwd": SANDBOX, "mcpServers": []})
    time.sleep(5)
    replayed = p.notifications[before:]
    kinds = {}
    for n in replayed:
        su = n.get("params", {}).get("update", {}).get("sessionUpdate", "?")
        kinds[su] = kinds.get(su, 0) + 1
    p._record("local", {"event": "load_replay_recheck", "sessionId": target,
                        "replayed": len(replayed), "by_kind": kinds,
                        "load_error": lr.get("error")})
    print(f"[loadreplay] replayed {len(replayed)} notifications: {kinds}")
    p.close()
    print(f"[loadreplay] log: {p.log_path}")


def run_fsrpc():
    ensure_sandbox()
    p = AcpProbe("fsrpc", fs_read=True, fs_write=False)  # 声明读能力
    p.initialize()
    sid = get_session_id(p.session_new())
    if not sid:
        print("[fsrpc] no session, abort"); p.close(); return
    p.permission_policy = "allow_once"
    p.prompt(sid, f"请使用工具读取文件 {READ_SEED}，并告诉我它有几行。")
    p.close()
    print(f"[fsrpc] log: {p.log_path}")


def run_lifecycle():
    ensure_sandbox()
    # (a) 非法 JSON
    p = AcpProbe("lifecycle-badjson")
    p._send_raw("this is not json")
    time.sleep(2)
    p.close()
    # (b) 不支持的 protocolVersion
    p = AcpProbe("lifecycle-badversion")
    print("[badversion] ->", json.dumps(p.initialize(protocol_version=999), ensure_ascii=False)[:400])
    p.close()
    # (c) 未实现方法
    p = AcpProbe("lifecycle-unknown")
    p.initialize()
    for m in ("session/close", "logout", "_probe/bogus"):
        print(f"[unknown] {m} ->",
              json.dumps(p.rpc(m, {"sessionId": "nonexistent"} if m == "session/close" else {}),
                         ensure_ascii=False)[:300])
    p.close()
    # (d) 崩溃：SIGKILL
    p = AcpProbe("lifecycle-crash")
    p.initialize()
    p.session_new()
    os.kill(p.proc.pid, signal.SIGKILL)
    rc = p.proc.wait(timeout=10)
    p.eof.wait(timeout=5)
    p._record("local", {"event": "killed", "returncode": rc})
    p.close()
    # (e) 正常终止：关闭 stdin
    p = AcpProbe("lifecycle-stdinclose")
    p.initialize()
    p.proc.stdin.close()
    try:
        rc = p.proc.wait(timeout=15)
        p._record("local", {"event": "stdin_closed_exit", "returncode": rc})
        print(f"[stdinclose] exit code: {rc}")
    except subprocess.TimeoutExpired:
        p._record("local", {"event": "stdin_close_no_exit", "note": "15s 内未退出，已强杀"})
        p.proc.kill()
        print("[stdinclose] did not exit within 15s after stdin close; killed")
    p.close()


def _send_raw_patch():
    """给 AcpProbe 补一个发送原始字节的方法（用于非法 JSON 采样）。"""
    def _send_raw(self, text):
        self._record("out-raw", text)
        with self._write_lock:
            self.proc.stdin.write(text + "\n")
            self.proc.stdin.flush()
    AcpProbe._send_raw = _send_raw


SEED_PARA = (
    "背景段落：分支对话面板是一款 macOS 原生应用，通过 ACP 协议接入 Kimi Code CLI 的 agent 能力。"
    "其核心特色是选中回答中的任意文字即可开启带上下文的支线对话，主线程保持整洁。"
    "支线拥有独立的 ACP session，支持嵌套与结论回流，对话历史以树状结构组织并持久化在本地 SQLite 中。"
    "权限策略第一阶段严格只读：读文件、列目录、搜索自动批准，写文件与终端命令自动拒绝。\n"
)


def run_seed():
    ensure_sandbox()
    sizes = [4096, 32768, 131072]
    p = AcpProbe("seed")
    p.initialize()
    for size in sizes:
        background = (SEED_PARA * (size // len(SEED_PARA) + 1))[:size]
        seed_text = (
            "[背景上下文]\n" + background + "\n\n"
            "[当前选中段落]\n权限策略第一阶段严格只读：读文件、列目录、搜索自动批准，写文件与终端命令自动拒绝。\n\n"
            "[用户追问]\n请用一句话说明背景上下文主要在讨论什么，并确认你看到了选中段落。\n\n"
            "[来源说明]\n这是从主线程派生的独立支线。请围绕当前选中段落回答，不要调用任何工具。"
        )
        sid = get_session_id(p.session_new())
        if not sid:
            print(f"[seed] size={size}: no session, abort"); break
        t0 = time.monotonic()
        resp = p.prompt(sid, seed_text, timeout=300)
        dt = time.monotonic() - t0
        result = resp.get("result") or {}
        p._record("local", {
            "event": "seed_result", "size_chars": size, "duration_s": round(dt, 2),
            "stopReason": result.get("stopReason"), "usage": result.get("usage"),
            "error": resp.get("error"),
        })
        print(f"[seed] size={size} chars: {round(dt,1)}s stopReason={result.get('stopReason')} "
              f"error={resp.get('error')}")
        if resp.get("error"):
            break  # 出现错误即停止升档
    p.close()
    print(f"[seed] log: {p.log_path}")


if __name__ == "__main__":
    _send_raw_patch()
    scenario = sys.argv[1] if len(sys.argv) > 1 else "baseline"
    {"baseline": run_baseline,
     "perms": run_perms,
     "terminal": run_terminal,
     "loadreplay": run_loadreplay,
     "fsrpc": run_fsrpc,
     "lifecycle": run_lifecycle,
     "seed": run_seed}[scenario]()
