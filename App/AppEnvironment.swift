import Foundation

/// 应用级环境装配入口（依赖注入容器，占位）。
/// 负责在启动时组装 Core 各服务（进程 Supervisor、ACP Client、策略器、数据库），
/// 具体实现随 M1-008～M1-011 落地。
public enum AppEnvironment {}
