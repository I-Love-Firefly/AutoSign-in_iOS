# 学校接口实现依据

审查日期 2026-10-05。只调用签到需求涉及的接口，首页审计所得 305 条路径不全部接入。

| 接口（相对主机） | 方法 | 本应用用途 |
|---|---|---|
| cas.xmu.edu.my/lyuapServer/login?service=… | GET | 建立初始 CAS Cookie 会话 |
| cas.xmu.edu.my/lyuapServer/loginType | GET | 查询登录配置，遇验证要求停止 |
| cas.xmu.edu.my/lyuapServer/v1/tickets | POST 表单 | Campus ID、网页同款 RSA 密文、service 换取票据 |
| acad.xmu.edu.my/mobile/shiro-cas?ticket=… | GET | 学校自己的 CAS 票据交换 |
| acad.xmu.edu.my/mobile/tryLoginUserInfo | POST | 获取当前登录身份和令牌 |
| acad.xmu.edu.my/mobile/api/jwxt-jcsj/login-user/sync-list | POST | 与移动网页相同的登录身份同步 |
| acad.xmu.edu.my/mobile/api/jwxt-jcsj/common/semester/selectCurrentXnXq | GET | 当前学期 |
| acad.xmu.edu.my/mobile/api/jwxt-ktkq/mobile/attendanceStudent/query/opt | POST | 当日课程、提交前复查、提交后核验 |
| acad.xmu.edu.my/mobile/api/jwxt-ktkq/mobile/attendanceStudent/updateStuAttendance | POST | 单次签到提交，不自动重试 |
| acad.xmu.edu.my/mobile/logout | GET | 教务会话退出 |
| cas.xmu.edu.my/lyuapServer/uniLogout?tgt=… | GET | 销毁本次 CAS 会话（取得 tgt 时） |

源码：`mobile/p__student__myAttendance__index.d5e753f7.async.js`、`mobile/umi.074a4ff1.js`、CAS `assets/js/app.0190d91a1ed73e4b605c.js`。

学校移动端旧 Axios 代码将对象 JSON.stringify，但曾设置 Content-Type 为 application/x-www-form-urlencoded;charset=utf-8。2026-10-06 真机登录时学校业务 POST 返回 HTTP 415；改用 application/json;charset=utf-8 后，sync-list 与课程查询均成功。CAS v1/tickets 仍使用表单编码。

CAS RSA 参数为公开密钥，不是私钥；仅为学校现有协议兼容。不使用应用自建密码算法存储凭据。加密原函数为 CAS bundle 模块 29，普通 ASCII 和跨块输入向量均纳入测试。

课程筛选在原页面入口规则基础上保守限制为：有效时间窗、backGroundColor=1、attendanceStatus 为 0 或 pending、settingId 与课程信息存在、无其他出勤状态、非 teacherMarkedAbsentLocked、非 studentCourseSign=2。服务端仍具有最终裁决权，不修改任何学校前端状态。

0.7.6将提交资格与结果识别分开：当日查询保留全部记录，当前有效课程窗口内 attendanceStatus=1 且无 studentOtherStatus 的记录显示为已签到，不重复提交。若提交前同一活动的复查记录变为已签到，同样停止提交并展示已签到。空列表或课程消失不等于已签到；当前无可签到课程为中性结果，提交后记录未确认仍显示待确认。

0.7.7主页状态读取复用独立 CAS/教务登录及当日 query/opt 接口，完成后关闭会话；不经过 AdaptiveNetworkProvider，不执行校园网切换或 updateStuAttendance。仅对 AC 课表当前上课的账号串行查询，按账号、马来西亚日期、课程代码及起止分钟唯一匹配，模糊匹配或失败不得推断为未签到。流程页保留完整的当日查询列表，核验成功后更新同一活动的状态；查看详情不会发送签到请求。

0.7.8准备阶段的 SRun 请求仍固定到选定 Wi-Fi，但不再调用 bindProcessToNetwork。CAS/教务登录及首次 query/opt 与校园网切换并行。两路均成功后通过新 activate 操作核对已选择的 Wi-Fi 是否仍在线、IPv4 是否相同并绑定整个应用，复查 SRun 身份后重建 Dart HTTP 连接（保留 Cookie）；重新 query/opt，再检查提交资格。真正提交前再做一次网络核验。仅连接中断可在网络准备完毕后恢复一次独立教务会话及只读请求，不自动重放签到提交。清理等待网络准备任务结束后执行，防止任务仍运行时释放其路由或清除其会话。

0.7.11重新检查已保存的学校移动端源码：签到响应分支使用 o.data 的真值，不是 data === true。应用旧版的严格布尔检查会将已受理的其他响应表示误判为 SERVER_REJECTED。现在只保留 HTTP/meta 基本校验，受理响应后进入五秒间隔的同一活动记录核验；任何 data 值本身都不能证明签到成功。即使受理响应返回 false/null，若记录尚未确认也只显示待确认，不推断成功或自动重发。服务器明确 meta 拒绝与 HTTP 错误仍按原规则处理。2026-10-13 用户录屏显示提交与清理发生在同一秒，中间没有验证阶段；随后主页只读查询显示已签到。录屏没有原始响应，具体 data 值仍未知。

签到声明属于原网页的客户端提交前条件，原接口没有单独的声明字段；本应用在主页说明“点击本人账号即确认本人在场并参加全程”，学生本人点击后才发起流程。
# Student 校园网切换（0.5.0）

2026-10-06 从当前手机 Student 认证 WebView 重新核验：HTTPS 主机 srun.xmu.edu.my，ac_id=1，MacAuth=true。应用通过 ConnectivityManager 选择唯一 Wi-Fi Network、固定整个本轮请求到 Wi-Fi，并用 Network.openConnection 发起认证请求；服务端 client_ip 必须匹配该 Wi-Fi 的动态 IPv4 地址。当前协议只支持已核验的 Student IPv4 配置。

顺序：GET /cgi-bin/rad_user_info → 若已在线，GET /cgi-bin/rad_user_dm（username、ip、time、unbind=1、SHA1 签名）→ 查询确认离线 → GET /cgi-bin/get_challenge（username、ip）→ GET /cgi-bin/srun_portal（action=login、挑战值派生的 HMAC-MD5、SRBX1 info、SHA1 chksum、ac_id=1、n=200、type=1）→ 查询确认所选 Campus ID 在线。离线响应使用 client_ip，在线响应仅有 online_ip，两种都严格核对 Wi-Fi 地址。每次重新取挑战值，不重放旧请求。请求不记录 URL或密码；仅展示经过限制的错误代码。注销未确认、登录失败、地址或身份不匹配均停止教务流程。

校园网密码是 Account.networkPassword，与签到系统密码分开安全存储，包含在加密账号导出中。旧数据缺少此字段时保留为空，要求用户补填；不会猜测两种密码相同。任务结束清理教务/CAS 会话、解除应用 Wi-Fi 绑定，校园网认证保持在线，下一轮开始时切换。额外验证码或学校策略拒绝时请在认证网页核验。


无论初次是否离线，均执行当前设备注销并复核。在线时使用网页配置的 rad_user_dm 解绑，离线时执行带当前 IP 的普通 srun_portal logout；不主动注销其他设备。登录 E2620 且仍离线时最多三次等待 10 秒重新取挑战，等待超限、其他错误或身份不符均停止。


0.5.1：用户选择系统 Wi-Fi 面板手动重连。在注销离线复核之后解除旧路由绑定，打开 Settings.Panel.ACTION_WIFI（Android 29 以下使用 Wi-Fi 设置），等候与旧 Network 不同的新 Wi-Fi 网络及 IPv4 地址，重新绑定并核验离线，再登录。最多等待 180 秒。按用户纠正移除 E2620 时间重试；错误仍明确停止，不能推断需要延迟或重连就是所有失败的根因。
