# VMQ Monitor V2 单 IPA 设计

日期：2026-07-28
状态：待用户审核
目标：TrollStore 安装、RootHide/rootless 监听、兼容 iOS 15.0 至 iOS 16.5

## 1. 目标

开发一个完善版 `VMQMonitor-v2.ipa`。用户只需要在 TrollStore 中安装一个 IPA，随后在同一个 App 内完成环境检测、监听启用、VMQ 配置、联网测试、日志查看、故障恢复和卸载。

监听端只识别微信和支付宝的到账通知，并兼容现有 VMQ 服务端：

- `GET/POST /appHeart`：监听端心跳。
- `GET/POST /appPush`：到账事件上报。
- VMQ `type=1`：微信。
- VMQ `type=2`：支付宝。

新项目独立开发。旧 `vmq-ios-monitor` 仅作为历史目录保留，旧监听源码、旧 Hook、旧测试和旧构建产物不得复制、链接或打入新 IPA。

## 2. 必要前提

TrollStore 能永久安装带扩展权限的 IPA，但 TrollStore 本身不能向系统进程注入 Tweak。完整监听需要同时满足：

1. 设备已安装 TrollStore。
2. RootHide、Dopamine rootless 或兼容的 rootless 越狱环境处于激活状态。
3. 越狱环境提供可用的注入框架和 rootless/RootHide 文件环境。

越狱未激活时，App 仍可打开、查看历史日志和修改配置，但监听与后台联网暂停。App 必须明确显示原因，不能反复尝试注入。

## 3. 不做的内容

- 不注入微信或支付宝进程。
- 不读取微信、支付宝数据库、账号资料或应用文件。
- 不监听其他 App 的通知。
- 不把完整通知正文、通信密钥或付款人信息上传到第三方。
- 不修改 VMQ 服务端协议和订单匹配逻辑。
- 不自动产生真实付款测试。
- 不承诺在未知方法签名上强制监听；未知环境必须停止加载。

## 4. 单 IPA 交付结构

最终只交付一个用户安装文件：

```text
VMQMonitor-v2.ipa
```

IPA 内部包含四个组件，但系统桌面只显示一个 App：

1. `VMQ Monitor` App
   - 配置、扫码、状态、日志、诊断、启停和卸载入口。
2. Root Helper
   - 使用 TrollStore 保留的授权，以 root 身份执行受控安装和卸载动作。
3. 全新通知监听组件
   - 分别包含原生 rootless 与 RootHide 构建，App 按环境选择一个。
4. 后台服务 `vmqmond`
   - 负责解析、SQLite 队列、心跳、到账上报、重试和持久日志。

用户不需要手动安装 `.deb`。IPA 内嵌两个原生 Theos 运行时包，包标识统一为 `com.z010genleman.vmqmonitor.v2.runtime`，rootless 与 RootHide 版本互斥。App 检测环境后，Root Helper 只允许对内置且 SHA-256 校验通过的对应包执行 bootstrap 环境中的 `dpkg -i`，随后执行 `sbreload`。禁止裸复制或转换 dylib，因为 RootHide 的随机 jbroot、Mach-O 路径修正和卸载登记必须由原生包安装流程处理。

运行时包只拥有监听 dylib、过滤 plist、`vmqmond`、LaunchDaemon plist 和卸载脚本，不拥有 TrollStore App bundle。

## 5. 安装、更新和卸载

### 5.1 首次启用

1. 用户通过 TrollStore 安装并打开 IPA。
2. App 检测 iOS 版本、CPU 架构、越狱状态、RootHide/rootless 类型、注入框架和运行时通知接口。
3. App 先运行只读探针，记录类、方法和类型签名，不安装 Hook。
4. 只有匹配已验证适配器时，才允许点击“启用监听”。
5. Root Helper 验证内置载荷哈希，通过当前 bootstrap 的 `dpkg -i` 安装正确载荷并启动 `vmqmond`。
6. App 请求一次 Respring。
7. 首次进入“只监听不上报”模式；确认稳定后，用户在 App 中开启正式上报。

### 5.2 更新

App 启动时比较 IPA 内置组件版本与已安装版本。版本不一致时显示更新按钮，由用户确认后替换监听组件并 Respring。更新失败必须保留上一可用版本并记录错误。

### 5.3 卸载

App 提供“彻底卸载监听”按钮，依次停止服务、卸载监听载荷、删除注入配置并 Respring。完成后用户再从 TrollStore 删除 App。

TrollStore 直接删除 App 不会执行运行时包的卸载脚本，因此不能保证同时清除外置监听组件。`vmqmond` 每次启动和每 5 分钟检查一次 Bundle ID `com.z010genleman.vmqmonitor.v2`；主 App 未注册时立即暂停心跳和到账上报，并写入禁用标记。彻底清理仍需重新安装 App 后点击“彻底卸载监听”，或在包管理器中卸载 `com.z010genleman.vmqmonitor.v2.runtime`。

## 6. 运行架构

```text
SpringBoard 通知发布链路
          |
          v
全新监听组件（只读、非阻塞、无网络、无落盘）
          |
          | 本机 Unix datagram，立即返回
          v
vmqmond（过滤、解析、去重、SQLite、联网、日志）
          |
          | HTTPS
          v
VMQ /appHeart 与 /appPush
```

监听组件必须先调用系统原实现，不能拦截、修改、延迟或取消用户通知。通知字段复制失败时直接放弃本次事件。

监听组件与后台服务之间使用本机非阻塞 Unix datagram。Socket 只允许设备本机指定用户访问，不开放 TCP 端口。后台服务未运行或队列已满时，监听组件只写一条限频系统日志并立即返回。

## 7. 统一监听管线

微信和支付宝使用同一套代码路径：

```text
Bundle ID 精确匹配
  -> 标题和正文收款语义校验
  -> 排除支出、退款和普通消息
  -> 货币金额提取
  -> 精确十进制规范化
  -> 事件 ID 去重
  -> SQLite 待上传队列
  -> VMQ 上报
```

代码只维护一个解析器和一个上报器。每个渠道仅提供数据配置：Bundle ID、VMQ 类型、允许标题、收款关键词和排除关键词。

统一事件结构：

```text
eventId
bundleId
channelType
title
subtitle
body
eventTime
```

监听组件发送原始事件到本机后台服务后立即结束。所有业务判断均在 `vmqmond` 中完成。

## 8. 微信监听方案

### 8.1 来源识别

- Bundle ID 必须精确等于 `com.tencent.xin`。
- VMQ 类型固定为 `1`。
- 其他 Bundle ID 即使正文包含“微信”“收款”也必须丢弃。

### 8.2 收款判定

微信普通聊天很多，因此采用更严格的两层判定：

1. 标题符合已验证的收款标题，例如“微信收款助手”“微信支付”“收款小助手”“微信收款商业版”。
2. 标题、副标题或正文同时包含明确入账语义，例如“收款”“成功收款”“已到账”“向你付款”。

仅出现“支付成功”或“付款成功”不能判定为收款，因为它可能是本机用户主动支出。

### 8.3 排除规则

以下语义不得上报：

- 普通聊天、群聊、好友申请和营销消息。
- 红包提醒、红包领取和红包退回。
- 待收款、请确认收款、转账邀请等尚未到账状态。
- 退款、撤回、付款失败和支出通知。
- 没有明确金额或包含多个无法唯一确定金额的通知。

### 8.4 金额提取

金额必须与“收款”“到账”“向你付款”等入账词处于同一语义片段，并符合以下形式之一：

- `¥12.30`
- `￥12.30`
- `12.30元`
- `收款12元`

解析结果必须大于 `0.00`，最多两位小数，规范化为 `12.30`。不使用 `double` 参与金额判断。

## 9. 支付宝监听方案

### 9.1 来源识别

- Bundle ID 必须精确等于 `com.alipay.iphoneclient`。
- VMQ 类型固定为 `2`。
- 其他 Bundle ID 即使模仿支付宝通知文本也必须丢弃。

### 9.2 收款判定

支付宝采用与微信相同的统一管线，渠道配置允许以下强收款语义：

- 标题示例：“收钱码收款通知”“支付宝收款”“到账通知”。
- 正文示例：“通过扫码向你付款”“你已收款”“成功收款”“到账”。

标题只有“支付宝”时不能单独判定，正文必须同时具备明确入账语义和金额。

### 9.3 排除规则

以下语义不得上报：

- 主动付款、消费、扣款和账单提醒。
- 付款成功但没有“收款”“到账”“向你付款”等入账语义。
- 退款、退款到账、撤销、付款失败和营销通知。
- 没有明确金额或包含多个无法唯一确定金额的通知。

### 9.4 金额提取

支付宝与微信共用同一金额解析器。金额必须靠近入账关键词，并规范化为最多两位小数的正十进制字符串。

## 10. 通知预览与缺失内容

系统关闭微信或支付宝通知、关闭通知预览，或者应用只发送模糊通知时，监听端可能拿不到金额。此时：

- 不猜测金额。
- 不上报 VMQ。
- 日志记录“通知内容不足”，但不保存完整正文。
- App 的环境检查页提示用户开启对应 App 通知及通知预览。

## 11. iOS 15.0 至 iOS 16.5 兼容

### 11.1 构建目标

- Deployment Target：iOS 15.0。
- 架构：`arm64`、`arm64e`。
- 载荷：原生 rootless 与原生 RootHide 两种，不使用转换工具生成 RootHide 包。
- App UI 只使用 iOS 15 可用的 UIKit/Foundation API；新 API 必须做可用性检查。
- RootHide 路径一律通过 `jbroot()` 或原生包安装结果解析，不缓存和硬编码随机 jbroot 前缀。
- 不申请 iOS 15 A12+ 禁止的 `dynamic-codesigning`、`com.apple.private.cs.debugger` 或 `com.apple.private.skip-library-validation` entitlement。

### 11.2 运行时适配

不按 `UIDevice.systemVersion` 猜测私有接口。每次启用前必须检查：

1. 目标类是否存在。
2. 目标 selector 是否存在。
3. 参数数量是否正确。
4. Objective-C type encoding 是否等于已验证签名。
5. 必要通知字段是否可读。

iOS 15 与 iOS 16 可以拥有不同适配器，但适配器只负责将通知转换为统一事件结构。未知签名、未知系统构建或字段不匹配时必须失败关闭，并在 App 显示“不兼容，监听未加载”。

### 11.3 验证矩阵

至少验证以下系统点位：

- iOS 15.0/15.1。
- iOS 15.4。
- iOS 15.7.x。
- iOS 16.0。
- iOS 16.3.x。
- iOS 16.5。

私有通知接口的最终兼容结论必须来自真机探针日志。模拟器或仅通过编译不能证明监听兼容。

## 12. 去重与金额安全

优先使用系统通知的稳定 bulletin ID 作为 `eventId`。字段不可用时，使用以下内容的 SHA-256 作为本机事件 ID：

```text
bundleId + title + subtitle + body + eventTime
```

SQLite 对 `eventId` 建立唯一约束。同一事件重复进入时只保留第一条。VMQ 上报保留原始 `eventTime`，每次重试使用新的请求时间 `t`。

无法确定唯一金额时宁可拒绝事件，不按第一个数字、余额、时间或笔数猜测金额。

## 13. VMQ 联网协议

### 13.1 心跳

监听启用且配置有效时，`vmqmond` 每 30 秒调用：

```text
/appHeart
```

心跳不进入持久队列。下一周期重新发送即可。

### 13.2 到账上报

到账事件调用：

```text
/appPush?type={1|2}&price={amount}&t={requestTime}&eventTime={eventTime}&...
```

默认使用 HTTPS 与 HMAC-SHA256。兼容旧 VMQ 时可以在 App 中显式开启 MD5 模式：

```text
heartbeatCanonical = nonce={nonce}&signType=HMAC_SHA256&t={t}
pushCanonical = eventTime={eventTime}&nonce={nonce}&price={price}&signType=HMAC_SHA256&t={t}&type={type}
sign = hmacSha256Hex(key, canonical)
```

每个 HMAC 请求生成新的高熵 `nonce`，字段按名称升序组成 canonical string。旧 MD5 模式使用：

```text
md5(type + price + t + eventTime + key)
```

只有 HTTP 2xx 且 JSON 返回 `code=1` 时，事件才标记成功。

### 13.3 联网行为

- 支持 Wi-Fi、蜂窝网络、系统 VPN 和系统代理。
- 使用系统 TLS 校验，不关闭证书验证。
- DNS、连接超时、断网和 HTTP 5xx 自动重试。
- 密钥错误、签名错误和非法配置暂停队列，并在 App 中显示原因。
- App 提供“测试连接”，显示 DNS/TLS、HTTP 状态及 VMQ 业务结果。

## 14. 可靠队列

`vmqmond` 使用系统 SQLite，不引入第三方数据库。最小状态为：

- `pending`：等待发送。
- `sending`：本次正在发送。
- `done`：服务端已确认。
- `paused`：配置或业务错误，需要用户处理。

网络失败采用有限指数退避，最大间隔 5 分钟。网络恢复时立即唤醒队列。进程重启后，残留 `sending` 事件恢复为 `pending`。

已成功事件只保留必要审计摘要，7 天后删除。通信密钥不进入 SQLite 日志表。

## 15. 日志与诊断

App 必须提供可筛选日志页面，至少包含：

- 环境：iOS、架构、RootHide/rootless、注入框架和监听适配器。
- 生命周期：探针、安装、加载、启用、停用、更新和卸载。
- 通知：渠道、匹配结果、拒绝原因和规范化金额。
- 网络：心跳、队列长度、重试次数、HTTP 状态和 VMQ 业务结果。
- 安全：签名不匹配、自动熔断和紧急禁用状态。

默认日志保存 7 天或 5 MB，任一条件达到即清理最旧记录。默认不保存完整通知正文、付款人名称、服务器密钥或签名原文。

“详细诊断模式”必须由用户手动开启，10 分钟后自动关闭。导出诊断包前显示内容预览，并再次过滤密钥和完整通知正文。

## 16. 防崩溃与自动熔断

### 16.1 监听组件限制

- 先执行系统原实现，再进行被动观察。
- Hook 回调不联网、不解析金额、不写文件、不等待锁。
- 所有本机 IPC 使用非阻塞发送。
- 复制字段时做空值、类型和长度检查。
- 未匹配 Bundle ID 在最前面丢弃。

### 16.2 加载保护

监听启用前先写入一次待稳定标记。加载后稳定运行 60 秒，由 `vmqmond` 清除标记。如果 5 分钟内连续 3 次未稳定加载，后台服务写入固定禁用标记，下一次 SpringBoard 启动时监听组件在 Hook 前直接退出。

固定禁用标记放在稳定的 `/var/mobile` 数据目录，不依赖随机 RootHide 路径，以便通过 SSH 或 Filza 恢复。

### 16.3 恢复入口

- App：“立即停用监听”。
- App：“彻底卸载监听”。
- 自动熔断：5 分钟内 3 次异常。
- 越狱环境 Safe Mode：禁止 Tweak 注入后启动。
- SSH/Filza：创建固定禁用标记，随后 Respring。

SSH/Filza 紧急禁用使用固定路径，不依赖 RootHide 随机前缀：

```sh
mkdir -p "/var/mobile/Library/Application Support/VMQMonitorV2"
touch "/var/mobile/Library/Application Support/VMQMonitorV2/listener.disabled"
sbreload
```

若越狱环境未提供 `sbreload`，先进入越狱环境 Safe Mode 禁用 Tweak 注入，再通过 App 或包管理器卸载运行时包。

## 17. 数据与权限

运行数据位于 `/var/mobile/Library/Application Support/VMQMonitorV2/`，目录权限为 `0700`。配置和通信密钥文件权限为 `0600`。监听 Socket 同样限制为本机访问。

App Bundle ID 固定为 `com.z010genleman.vmqmonitor.v2`。Root Helper 只能执行内置的安装、更新、停用和卸载动作，不接受任意命令、任意包路径或任意 package ID。每次安装前必须核对内置清单中的版本、环境类型和 SHA-256。App 不在日志或导出包中输出通信密钥。

监听组件只加载到经过验证的系统通知进程。RootHide App List 不需要为微信或支付宝开启注入。

## 18. App 页面

只保留完成工作所需页面：

1. 首页
   - 监听状态、服务器状态、最近心跳、最近到账和待上传数量。
2. 通道
   - 微信开关、支付宝开关和通知权限提示。
3. 服务配置
   - 扫描 VMQ 配置二维码、手动填写地址和密钥、签名模式、测试连接。
4. 日志
   - 分类筛选、详细诊断、导出和清空。
5. 恢复
   - 环境探针、启用、停用、更新、彻底卸载和紧急恢复说明。

## 19. 构建与打包

- 使用 RootHide 官方 Theos 构建 RootHide 载荷。
- 使用标准 Theos 构建 rootless 载荷。
- 使用 iOS SDK 编译 App、Root Helper、监听组件和 `vmqmond`。
- IPA 使用 TrollStore 支持的 fakesign 与必要 entitlements。
- IPA 内同时携带两个原生运行时包，首次启用时只通过当前 bootstrap 的 `dpkg` 安装匹配环境的一份。
- 发布前检查 IPA 中不存在真实服务器地址、通信密钥、测试账号和通知样本。

发布产物：

```text
VMQMonitor-v2.ipa
VMQMonitor-v2.ipa.sha256
INSTALL-RECOVERY.md
```

## 20. 测试方案

### 20.1 自动测试

- 微信有效收款通知识别。
- 支付宝有效收款通知识别。
- 普通微信聊天、红包、退款、支出和营销通知拒绝。
- 支付宝付款、消费、扣款、退款和营销通知拒绝。
- 金额格式、多个数字、非法金额和精确十进制测试。
- `type=1` 微信、`type=2` 支付宝映射测试。
- HMAC-SHA256 与 MD5 兼容签名测试向量。
- SQLite 唯一去重、进程重启恢复和重试状态测试。
- 日志脱敏、容量清理和诊断超时测试。
- 未知方法签名必须拒绝安装 Hook。
- rootless 与 RootHide 两种载荷内容检查。

### 20.2 真机测试

- TrollStore 单 IPA 安装、更新和删除。
- RootHide/rootless 自动识别及一键启用。
- App 关闭后保持监听、心跳和上报。
- 锁屏、解锁、Wi-Fi、蜂窝、VPN、断网及恢复。
- 微信和支付宝各进行用户授权的小额真实收款测试。
- 连续普通通知压力测试，不得误上报。
- 连续 Respring、服务重启和监听组件异常注入，验证自动熔断。
- iOS 15 与 iOS 16.5 至少各使用一台真机完成核心回归。

## 21. 完成标准

- 用户只安装一个 `VMQMonitor-v2.ipa`。
- 不需要手动安装或管理 `.deb`。
- 新项目不包含旧监听源码。
- iOS 15.0 至 iOS 16.5 使用运行时适配；未知签名自动停止监听。
- 微信与支付宝使用同一管线，并正确映射 VMQ 类型。
- App 退出后仍能监听、心跳和可靠上报。
- 断网事件恢复后可继续发送，且不重复确认同一通知。
- 普通聊天、红包、主动付款、退款和营销通知不会触发到账。
- 日志可查看、导出和清理，密钥与完整正文不泄露。
- 5 分钟内连续 3 次异常会自动停用监听，设备可以通过 App、Safe Mode 或固定禁用标记恢复。
- 发布 IPA 通过自动测试、真机兼容测试和 SHA-256 校验。

## 22. 已知边界

- 微信或支付宝没有发出系统通知时，监听端没有事件来源。
- 通知预览隐藏金额时，监听端不会猜测或上报。
- 越狱未激活时系统通知监听停止。
- 私有通知接口可能随系统构建变化，因此必须以运行时签名和真机探针为准。
- 通知监听属于到账辅助确认，可靠性仍低于官方支付平台异步回调。
