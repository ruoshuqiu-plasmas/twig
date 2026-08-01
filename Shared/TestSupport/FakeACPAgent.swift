import Foundation

/// fake ACP agent（bash）：按 NDJSON 行读取请求并回 canned 响应/通知。
/// 供 ACPClient 端到端离线集成测试，不驱动真实 kimi CLI（零额度消耗）。
///
/// 响应 id 从请求行中正则提取并原样回显（数字/字符串类型保持一致，
/// SDK 按 id 匹配 pending request）。
public enum FakeACPAgent {

    /// bash 函数片段：reply <请求行> <result JSON>。
    private static let replyFn = """
    reply() {
      local line="$1" result="$2"
      if [[ "$line" =~ \\"id\\":([0-9]+) ]]; then
        echo "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":${BASH_REMATCH[1]},\\"result\\":$result}"
      elif [[ "$line" =~ \\"id\\":\\"([^\\"]+)\\" ]]; then
        echo "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":\\"${BASH_REMATCH[1]}\\",\\"result\\":$result}"
      fi
    }
    """

    private static let initializeResponse = """
    {"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"list":{},"resume":{}}},"agentInfo":{"name":"fake-agent","version":"0.0.1"}}
    """

    private static let thoughtChunk = """
    {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session_fake","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"思考中"}}}}
    """

    private static let messageChunk = """
    {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session_fake","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"你好"}}}}
    """

    /// 权限请求前的 tool_call 事件（G0 实测时序：tool_call 先、request_permission 后；
    /// 策略链路按 toolCallId 关联此处的 kind 分类）。
    private static let toolCallStart = """
    {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session_fake","update":{"sessionUpdate":"tool_call","toolCallId":"0:tool_fake","title":"Write","kind":"edit","status":"pending"}}}
    """

    /// options 三档与真实样本一致（perms/terminal 脱敏样本：approve_once/approve_always/reject）。
    private static let permissionRequest = """
    {"jsonrpc":"2.0","id":1000,"method":"session/request_permission","params":{"sessionId":"session_fake","options":[{"optionId":"approve_once","name":"Approve once","kind":"allow_once"},{"optionId":"approve_always","name":"Approve for this session","kind":"allow_always"},{"optionId":"reject","name":"Reject","kind":"reject_once"}],"toolCall":{"toolCallId":"0:tool_fake","title":"Write"}}}
    """

    /// 标准流程：initialize / session/new / prompt（思考 chunk + 正文 chunk + end_turn）。
    ///
    /// 注意：acp-swift-sdk 的 JSON 编码会把 `/` 转义为 `\/`（`session\/new`），
    /// 故每个含斜杠的 method 匹配都要同时容忍两种写法。
    public static let chat = """
    \(replyFn)
    while IFS= read -r line; do
      case "$line" in
        *notifications/initialized* | *notifications\\\\/initialized*) : ;;
        *\\"initialize\\"*)
          reply "$line" '\(initializeResponse)' ;;
        *\\"session/new\\"* | *\\"session\\\\/new\\"*)
          reply "$line" '{"sessionId":"session_fake"}' ;;
        *\\"session/prompt\\"* | *\\"session\\\\/prompt\\"*)
          echo '\(thoughtChunk)'
          echo '\(messageChunk)'
          reply "$line" '{"stopReason":"end_turn"}' ;;
      esac
    done
    exit 0
    """

    /// 权限流程：prompt 时先发 tool_call（kind=edit）再发 request_permission（agent→client
    /// 请求，id 1000，G0 实测时序），读取客户端响应写入 stderr（PERMRESP: 前缀），
    /// 再回 chunk + end_turn。
    public static let permission = """
    \(replyFn)
    while IFS= read -r line; do
      case "$line" in
        *notifications/initialized* | *notifications\\\\/initialized*) : ;;
        *\\"initialize\\"*)
          reply "$line" '\(initializeResponse)' ;;
        *\\"session/new\\"* | *\\"session\\\\/new\\"*)
          reply "$line" '{"sessionId":"session_fake"}' ;;
        *\\"session/prompt\\"* | *\\"session\\\\/prompt\\"*)
          echo '\(toolCallStart)'
          echo '\(permissionRequest)'
          IFS= read -r permresp
          echo "PERMRESP:$permresp" >&2
          echo '\(messageChunk)'
          reply "$line" '{"stopReason":"end_turn"}' ;;
      esac
    done
    exit 0
    """

    /// 权限放行流程（M2-006）：tool_call kind=read / title=Read 触发 permission 时
    /// 走 allowlist 批准路径——应回 selected + allow_once，且不产生 toolCallDenied 事件。
    public static let permissionAllow = """
    \(replyFn)
    while IFS= read -r line; do
      case "$line" in
        *notifications/initialized* | *notifications\\\\/initialized*) : ;;
        *\\"initialize\\"*)
          reply "$line" '\(initializeResponse)' ;;
        *\\"session/new\\"* | *\\"session\\\\/new\\"*)
          reply "$line" '{"sessionId":"session_fake"}' ;;
        *\\"session/prompt\\"* | *\\"session\\\\/prompt\\"*)
          echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session_fake","update":{"sessionUpdate":"tool_call","toolCallId":"0:tool_fake","title":"Read","kind":"read","status":"pending"}}}'
          echo '{"jsonrpc":"2.0","id":1000,"method":"session/request_permission","params":{"sessionId":"session_fake","options":[{"optionId":"approve_once","name":"Approve once","kind":"allow_once"},{"optionId":"approve_always","name":"Approve for this session","kind":"allow_always"},{"optionId":"reject","name":"Reject","kind":"reject_once"}],"toolCall":{"toolCallId":"0:tool_fake","title":"Read"}}}'
          IFS= read -r permresp
          echo "PERMRESP:$permresp" >&2
          echo '\(messageChunk)'
          reply "$line" '{"stopReason":"end_turn"}' ;;
      esac
    done
    exit 0
    """

    /// 分片传输：initialize 响应故意分两次写入（验证 NDJSON 行分帧的粘包/拆包容忍）。
    public static let fragmentedHandshake = """
    \(replyFn)
    first=1
    while IFS= read -r line; do
      case "$line" in
        *notifications/initialized*) : ;;
        *\\"initialize\\"*)
          if [[ "$line" =~ \\"id\\":([0-9]+) ]]; then
            printf '{"jsonrpc":"2.0","id":%s,"res' "${BASH_REMATCH[1]}"
            sleep 0.1
            printf 'ult":%s}\n' '\(initializeResponse)'
          fi ;;
      esac
    done
    exit 0
    """

    /// 多 session 路由流程（M1-010）：session/new 按调用次序返回 sess_1/sess_2/…；
    /// prompt 从请求中提取 sessionId，回显归属该 session 的正文 chunk（text 为 `reply-<sid>`）。
    /// 首次 prompt 额外发一条无主 session（sess_ghost）事件，验证路由层保守记录、不串线、不崩溃。
    public static let multiSession = """
    \(replyFn)
    n=0
    ghost_sent=0
    while IFS= read -r line; do
      case "$line" in
        *notifications/initialized* | *notifications\\\\/initialized*) : ;;
        *\\"initialize\\"*)
          reply "$line" '\(initializeResponse)' ;;
        *\\"session/new\\"* | *\\"session\\\\/new\\"*)
          n=$((n+1))
          reply "$line" "{\\"sessionId\\":\\"sess_$n\\"}" ;;
        *\\"session/prompt\\"* | *\\"session\\\\/prompt\\"*)
          if [[ "$line" =~ \\"sessionId\\":\\"([^\\"]+)\\" ]]; then
            sid="${BASH_REMATCH[1]}"
          else
            sid="unknown"
          fi
          if [[ $ghost_sent -eq 0 ]]; then
            ghost_sent=1
            echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_ghost","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"幽灵"}}}}'
          fi
          echo "{\\"jsonrpc\\":\\"2.0\\",\\"method\\":\\"session/update\\",\\"params\\":{\\"sessionId\\":\\"$sid\\",\\"update\\":{\\"sessionUpdate\\":\\"agent_message_chunk\\",\\"content\\":{\\"type\\":\\"text\\",\\"text\\":\\"reply-$sid\\"}}}}"
          reply "$line" '{"stopReason":"end_turn"}' ;;
      esac
    done
    exit 0
    """
}
