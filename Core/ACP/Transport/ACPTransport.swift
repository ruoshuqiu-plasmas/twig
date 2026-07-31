import Foundation

/// NDJSON over stdio 传输层（占位，M1-009 实现）。
/// UI 不直接读写 Pipe；framing 依据 G0 实测：每行一个 JSON-RPC 消息，日志走 stderr。
public enum ACPTransportNamespace {}
