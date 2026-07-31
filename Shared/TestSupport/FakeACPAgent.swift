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

    private static let permissionRequest = """
    {"jsonrpc":"2.0","id":1000,"method":"session/request_permission","params":{"sessionId":"session_fake","options":[{"optionId":"approve_once","name":"Approve once","kind":"allow_once"},{"optionId":"reject","name":"Reject","kind":"reject_once"}],"toolCall":{"toolCallId":"0:tool_fake","title":"Write"}}}
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

    /// 权限流程：prompt 时先发 request_permission（agent→client 请求，id 1000），
    /// 读取客户端响应写入 stderr（PERMRESP: 前缀），再回 chunk + end_turn。
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
          echo '\(permissionRequest)'
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
}
