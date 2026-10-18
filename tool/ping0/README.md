# Ping0 环境检测契约

本目录提供公开客户端契约和保留证据的采集、回放接口。它不重建 Ping0 后台，也不把网站分数当作 Hiddify、VPN、DNS 或真机验收。

`contract.json` 的固定标识为 `ping0-env-2026-10-18-cb9bbcc5`，`schema_version=1`。其中列出 11 个 job 的逐字段来源、类型、失败语义、18 个 crosscheck，以及网络目标、生命周期和未知边界。

## 四层结果

| 层 | 含义 | 不能替代的内容 |
|---|---|---|
| `facts` | 实际事务、源码身份和页面提交字段的去敏投影 | 不是完整原始网络正文，不从最终页面对象反推请求 |
| `observation` | 提前布防、HTTP/body/JSON/schema状态、版本覆盖、超时、截断和清理完整性 | 不把未观察到、缺字段或未完成写成通过 |
| `site_result` | 网站返回的 score、level、findings 和 evidence | 不冒充独立验证的服务器规则 |
| `diagnosis` | 有证据引用、备选解释和未知项的有限判断 | 不从站点单项标记认定系统故障或 Fake-IP 根因 |

`facts.client_submission` 必须来自本轮实际 `/envdetect/submit` 请求，并保留 `facts.client_submission_transaction_id` 和 `facts.client_submission_scope_id` 的绑定。`cdn-main.js:506` 会用 `resp.evidence` 覆盖 `finalEvidence`，服务器 findings 也会改写页面行值。因此最终 Vue 对象、下载报告里的 evidence、请求原文不是同一种证据。

## CLI 约定

在项目根目录使用以下接口。大写参数是占位符，不是现成路径或端点。

```sh
python3 -B tool/ping0/ping0.py replay CAPTURE --format json
python3 -B tool/ping0/ping0.py replay CAPTURE --format markdown
python3 -B tool/ping0/ping0.py capture-desktop \
  --cdp LOOPBACK_WS \
  --run-dir SSD_RUN \
  --gate-receipt FRESH_GATE \
  --ack-site-disclosure
```

- `replay` 只解析已保留的数据，不联网，不导入网络、CDP 或设备适配器，不执行或 eval 网站 JS
- `capture-desktop` 使用已获批准的本机 loopback WebSocket CDP 端点；不是允许启动任意浏览器、访问设备或复用旧采集目录
- 在线入口另须由操作者显式提供 `PING0_VOLUME_UUID`、`PING0_HOST_UUID`、`PING0_VOLUME_PATH`、`PING0_HOST_PATH`，并与本任务登记和新鲜验卷回执一致；源码不携带任何人的真实卷标识或挂载路径，也不默认回退其他磁盘。这些环境值不能代替用户批准或验卷，离线 `replay` 不需要它们
- 在线单轮最多 90 秒，另有独立的 5 秒收口窗口；使用独立 context、前台页面，先监听再导航
- 不点击 retest，不绕过 captcha，不自动授权或伪造权限；到期保留 pending、失败、缺失和清理状态，不延时补做一轮
- `SSD_RUN` 必须是另行批准且通过新鲜存储门控的目录；`FRESH_GATE` 是对应回执。本文档不会创建目录、验盘、挂载或代替该门控
- 首轮目录为 `desktop-a1`。已获明确的额外一次授权时，`desktop-a2` 还必须传入 `--additional-approval TASK/approval-a2/approval.json`，并核对用户授权记录、旧 claim 和旧 manifest 的字节身份；它使用独立 claim，不重置首轮记录，不允许 `desktop-a3`

这些是接口和证据边界，不是本次采集成功记录。仅修改本契约与文档时，不运行上述 CLI，也不能据此声称在线端到端测试通过。

## 来源与版本

四个 pin 的完整 URL 均来自公开 HTML 的 exact `script src`。main、probes、browser-detect client 是 required，i18n 是 optional；SHA-256 在 `source_pins` 中。pin 只绑定已审客户端，不绑定后台版本、ENGINE 动态目录、第三方服务或 iPad 已加载的脚本。

契约不依赖原审阅目录作为运行时库，不把完整抓获源码复制进仓库。`source_locations` 使用原文件名和定位；probes 是单行文件，`char_start`、`char_range` 是原始文本零基 Unicode 字符位置，区间右端不包含，不是字节偏移或还原视图偏移。静态 constant view 只是阅读辅助，不是全 bundle 等价证明。

required pin 缺失或不同，应保留版本覆盖未知或不匹配，不能套用旧契约宣布通过。i18n 中多出来的标签也不能自动扩充 job 或 crosscheck。

服务器可先返回普通字段的 findings，再返回跨检项。工具最多扫描 512 项，筛选后最多保留 64 个已审 ID 的条目；忽略无关字段与实际超限截断分别记录。`site_result.response.evidence` 只保留独立去敏投影，不覆盖 `facts.client_submission`。旧记录若已截断或省略正文，修复工具后也不能凭回放补出缺失数据，不能据此洗成完整结果。

## 11 个 job

| Job | 主要输出与来源 | 失败和类型边界 |
|---|---|---|
| NET | `net.ipv4/ipv6`，双族 IP-info HTTPS 请求；main 再合并 IP、国家、ASN、组织和风险字段 | null 同时可能表示族不可用、请求失败或结果不可用；captcha 占位的 false/0 不是无代理、低风险实测 |
| RTC | 公网、本地 IPv4/IPv6、mDNS 和 `disabled`，来自 ICE candidate | 4 秒窗口和首地址投影不覆盖全部候选；空值不是无泄漏证明 |
| IDENT | navigator 身份字段，Client Hints 的 JSON 字符串 | `ua_chua` 不是 HTTP 请求头；缺失、空串和默认零不等于正常 |
| LOCALE | Date 偏移、Intl locale/时区、语言、字体和语音数组 | 浏览器报告不是系统设置验收；字体数组不是服务器 `has_cn_fonts` |
| HW | 浏览器报告的硬件值，WebGL/WebGPU、Canvas×5、Audio×3、字体候选匹配 | 稳定性字段是样本数组，不是布尔；字体数量是拼接后的长度，未跨组去重 |
| STEALTH | webdriver、有限全局标记、描述符、权限一致性和帧间隔 | 启发式不认证“干净浏览器”；部分异常会变成 false，权限查询不支持或失败可变成 true |
| PRIVACY | storage 配额、IndexedDB、Service Worker 存在性 | 第三方 Cookie 字段为 null；IndexedDB 可创建站点数据库，不是只读检测 |
| API | 24 个属性路径存在性布尔值，另有 missing_count、total | 不调用这些能力，不等于授权成功；i18n 的额外标签不是实际检查项 |
| ENGINE | 服务端动态目录的探针位图与匹配结果，版本可有上下界 | 目录和匹配规则未固定；失败返回空串，不能按文案认定有 1,247 个探针 |
| DNS | 随机域触发后查询站点 API，返回 count、resolver 列表和国家投影 | 零有多条观测或失败路径；不能用列表长度替代 count |
| MULTIGEO | 14 个 direct + 20 个 trace 任务，并发 6，输出列表和不同 IP/国家数组 | 空 IP 对象或 null 都可能出现，不要求 34 个全部成功；provider 的 region 标签不是实测国家 |

所有逐字段定义在 `probe_jobs[].outputs`；NET 的后续扁平合并字段另在 `net.preferred_family_flat_fields`。HTTP headers 和 UA 解析后的浏览器/版本可由服务端 findings 富化，不是额外的本地 job。

## 网络路径的已核与未知

### NET 与 RTC

NET 初始请求为 `https://ipv4.ping0.cc/envdetect/ipinfo-cors?token=` 和对应 IPv6 主机，CORS、omit credentials、no-store。族请求使用 5 秒计时器，但收到 Response 就清除，不能把它称为 JSON body 全程硬超时。IP 分类、地理库、代理/IDC 风险规则仍属于后台未知。

RTC 配置的四个 STUN URL 在 `network_targets.rtc_ice_urls`。候选按客户端 regex 分类，4 秒后关闭并投影到首地址。缺少 RTCPeerConnection 或同步设置错误会令 disabled=true；offer 拒绝可被吞掉并留下 disabled=false 和空地址。这不认证 UDP 或 DNS 通路。

### DNS

- 名义 5 批 × 10 个 `r-<Date.now()>-<floor(random*MAX_SAFE_INTEGER)>.d.ping0.cc`，每批后等待 600 ms，包括最后一批；50 次生成尝试不等于 50 次外发 DNS
- 每域尝试 prefetch、CSS 背景图、Image；有 RTC 时另尝试 `stun:HOST:3478`。同步异常和 offer 拒绝可能被吞掉
- POST `/envdetect/probe/dnsleak`，提交 `domains`、`stamp`。直接解析 JSON，没有显式 HTTP ok 检查或 fetch 硬超时
- 批次完成后设 +9 秒截止点，轮询间隔 1 秒；相同正 count 稳定两次可早退，零响应不重置前正值与稳定次数。截止检查在响应之后，不能中断挂起请求
- count 直接取 `response.resolver_count || 0`，不取 `items.length`。fetch、JSON 或结果转换错误也可返回相同的零和空数组
- `dns.dnssec` 在成功返回和 catch 都是固定空串占位，不是 DNSSEC 请求、实测结果或安全状态

后端如何关联 stamp/domains、观察、去重和赋予国家信息没有取得。零既不能证明系统 DNS 全坏，也不能证明 Fake-IP 根因、无泄漏或 VPN 通过。

### MULTIGEO 与 ENGINE

`network_targets.multigeo` 完整列出已核 34 个静态目标；`multigeo` 进一步列 direct 字段读取、20 个 trace host/provider、并发和失败语义。JSON/text 与 header helper 有计时器及一次拒绝重试，但不提供普遍的 body/整轮硬截止。列表完整不等于服务可达、CORS 放行或解析全部成功，UI 最多显示 14 条也不代表只执行 14 个任务。

ENGINE 从 `/envdetect/probe/engine?init=1` 获取动态目录，再发送位图。网站正常执行时使用 `new Function` 做语法编译或存在性求值；回放器不能执行该目录。静态 client pin、页面文案和 API 的 24 项总数都不能证明 ENGINE 当轮目录总数。

## 字体与判分

字体用 Canvas `measureText`，样本 `mwlxg阅日`、20px、三种 fallback，任一宽度差绝对值大于 0.1px 则命中。56 个 CJK 候选包含 PingFang SC/TC/HK、Heiti SC/TC。苹果设备支持这些字体本身不异常；候选匹配不证明国籍、中文系统或已安装字体全表。

18 个 crosscheck ID 以 `crosschecks` 为准。每项列候选输入，但候选关联不是隐藏后端依赖证明。其 `value` 的具体嵌套形状、精确 if、权重、阈值、去重和 iOS/浏览器例外均不补造；`scoring.crosscheck_result` 统一描述来源、类型和缺失语义。i18n 的“VPN fake-ip”等解释不是因果证据。

页面 mount 后 300 ms 自动 run，11 个 job 按 60 ms 错开。成功和 catch 都会增加 progressDone，初始分数是 100，预置行数也不是完成证据。Turnstile 脚本加载有 15 秒计时器，但 widget 没有已核总截止；未回调可在 job 计数到 11 后继续挡住 submit。

## 隐私与验证范围

在线访问不是“完全只读”：网站正常运行会发送 IP、指纹和区域证据，访问第三方网络目标，并写自己的站点数据。PRIVACY 会 `indexedDB.open('envdetect-probe', 1)`，成功只 close，不 delete。使用 `--ack-site-disclosure` 前应理解这些效果；独立 context 不等于从未上传数据。

浏览器协议在内存中可能包含 IP、指纹、Cookie 或站点标识；写盘前只保留诊断白名单字段，不保存私有本地 IP、Cookie、认证头、验证码 token 或 ENGINE 会话材料。真实 capture 和报告不应提交到仓库；仓库只包含工具、契约、文档和明确标记的合成测试。工具不改 app 翻译，也不修改节点、数据库、VPN 或系统设置。

仅用标准库 JSON 加载和检索可验证本契约的格式、引用和数量，不能验证网站当前行为、后台规则、iPad 字节身份或 VPN 验收。运行时证据不足时保留 unknown，不用页面 score、绿色卡片、空数组或超时后的默认值补成通过。

## 可复用的 DNS 判读顺序

1. 先核设备、浏览器、选定页面、scope 和实际脚本 SHA；桌面观测不能填补 iPad 缺证，系统 VPN 状态也不能认证当前节点归属
2. 按相同 domains/stamp 关联本轮 DNS API 事务，分别保留 HTTP、正文、JSON、schema 和终态；缺失、null、false、字符串 `"0"` 不能变成有效数值零
3. 合法轮询可出现 `0→1→1` 或 `1→0`。依据已审客户端的串行顺序选择提交之前的最后完成响应，不凭历史某次正数宣称客户端丢结果；真实错误、跨 nonce 和迟到记录不能被最后一次成功洗掉
4. 比较实际 submit 请求中的 DNS 数值，不读取被服务器覆盖后的页面对象来代替；响应和提交都为零，只能确认两层数值一致，不能由此宣布系统 DNS 故障
5. 再核对应 submit 响应里的 `xc.dns_blackhole` 的实际 fail 值。提交为正但服务器仍报黑洞时，记录服务端判定差异及后台规则未知，不伪造请求探评分条件
6. 资源 TLS／证书失败不是 DNS 报文。没有物理 DNS 或当前核心路由证据时，不把网络资源失败、解析器 API 零值直接归因于 Fake-IP，也不要求递归解析器 IP 等于 HTTP 出口 IP

每个实际结论应带：来源轮次、原 capture/manifest 的 SHA、使用的工具版本、API/提交/finding 的逐层事实、缺证点，以及是否已验证当前核心和原节点归属。真实记录只放已验 SSD 并登记本地索引；仓库中的说明和合成回归不作为某台设备的通过凭据。
