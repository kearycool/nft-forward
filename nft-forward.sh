#!/usr/bin/env bash
# nft-forward.sh v30 (最终版) — 多 VPS 通用 nftables 端口转发管理脚本 (一键安装 + 交互菜单 + 快捷命令)
# v30 改进 (相对 v29, Kevin 问: 下载完没有任何提示, 成功了能不能显示版本号):
#  新增 version 子命令: `nft-forward version` 或 `bash nft-forward.sh version`
#  直接打印 "nft-forward v30"。不需要 root、不碰 nft, 下完文件就能先确认版本
#  再装; 多余参数同样拒绝 (和其他无参命令一致)。下载命令改成 curl 成功后
#  自动跑 version, 成功就有版本提示, 失败 curl 自己报错、version 不跑。
# v29 改进 (相对 v28, Kevin 又问: 没有 apt-get 时能不能加个安装 apt-get 的命令):
#  还是装不了——安装 apt-get 的命令就是 apt-get 自己 (apt-get install apt),
#  它不在, 命令就没法跑; 下面没有更底层的安装器了。硬从网上抓 .deb 用 dpkg
#  装可以写, 但版本必须跟系统发行版严丝合缝, 依赖缺一个就会把包数据库搞成
#  半安装状态, 不值得为几乎不存在的情况冒这个险。所以 v29 改的是报错:
#  check_nft 在 7 个包管理器全没有时, 按 /etc/os-release 认出系统, 有 dpkg
#  的 Debian/Ubuntu 会直接给 apt 官方池地址 (按发行版和架构拼好), 让用户
#  手动下 .deb 装; 别的系统或读不到发行版时也给一句能照着做的办法。
# v28 改进 (相对 v27, Kevin 问: 没装 nftables 时会不会自动装; 能不能 apt-get
# 也检测、没有就默认装 apt-get):
#  apt-get 本身装不了——它就是装软件的工具, 没包管理器就没法装包管理器。
# check_nft 的检测从 apt-get/dnf/yum 扩到 apt-get/apt/dnf/yum/apk/pacman/
# zypper 七个, 哪个在就用哪个 (覆盖 Alpine 的 apk、Arch 的 pacman、openSUSE
# 的 zypper, 以及只有 apt 没有 apt-get 的精简系统)。7 个全没有才报错。
# v27 新功能 (相对 v26, Kevin 在真机甲骨文 VPS 上实测: 菜单和 IP 目标都正常,
# 填域名 jpeastern.lindays.xyz 时报 "目标 IP 不合法"):
#  目标支持填域名。cmd_add 里新增 resolve_target: 已经是 IP 就原样用, 是域名
#  就 DNS 解析一次 (getent 优先, 依次 fallback nslookup/dig/host/python3,
#  取第一个 IPv4), 存解析到的 IP。只在添加时解析, 不在每次 apply 时解析——
#  开机时 systemd 跑 apply, 那时 DNS 可能还没好, 解析失败会让整批规则加载
#  失败。域名 IP 变了要 del 了重加 (那时再解析一次)。rules.conf 里仍只存 IP,
#  手写域名进规则文件仍会被 validate 拒绝。IPv6 地址和解析不到的域名都拒绝。
# v26 修复 (相对 v25, Kevin 传来另一份 v25, 我逐条实测它的 5 处改动, 发现其中 1 处引入严重回归):
# v26 修复 (相对 v25, 我逐条实测 v25 的 5 处改动, 发现其中 1 处引入严重回归):
#  v25 的第 4 项 (Docker 查询失败改为拒绝添加) 本意是对的, 但实现有 bug:
#  docker_published_conflicts 尾巴是 echo | grep -oE | while 循环, grep
#  找不到匹配时退出 1, 在 set -o pipefail 下整个函数返回 1, 调用方误以为
#  Docker 查询失败。实测 v25 在 docker 正常、端口没被发布时 add 也会被拒
#  ("无法确认 Docker 端口占用情况"), check 也误报风险 exit 1——有 docker
#  的机器上基本没法加规则。v26 在函数末尾显式 return 0 (真正查不了时上面
#  已 return 2)。其余 4 项实测都没问题, 原样保留。
# v25 修复 (基于 v24 复核, 另一 AI 的改动, 我逐条实测过):
# v24 修复 (相对 v23, Kevin 把脚本发给另一个 AI 审, 对方报了 3 个高风险问题;
# 我逐条在 v23 上实测复现, 2 个是真的、1 个在 v23 上已不存在):
#  1. [真] nft list ruleset 失败时, DNAT 冲突检查假装没冲突。existing_dnat_conflicts
#     在 nft 缺失或 list 失败时 return 0, add 会继续把规则加上, check 第 6 节
#     也报 "OK, 未发现碰撞"。v24 改成返回 2 表示"查不了": add 拒绝添加,
#     check 计一条风险 (exit 1)。
#  2. [真] add/del/clear 改完 rules.conf 后 nft 加载失败, 文件不回滚。
#     add 失败后文件里有规则、内核里没有; del/clear 失败后文件里没了、内核里
#     还在。v24 加 apply_or_restore: apply 在子 shell 里跑, 失败时把 rules.conf
#     从 .bak 恢复 (只在内核没动时恢复; nft 已加载但持久化失败时不恢复)。
#  3. [假, v23 已安全] install 在 apply 失败后继续。实测: nft -f 失败时 install
#     exit 1, "安装完成" 一次没出现, apply_rules 的 exit 1 直接结束整个进程。
#     未改。
# v23 修复 (相对 v22, 换角度排查: 菜单输入处理逐条核对, 发现 2 个问题):
#  1. 菜单里选 1 添加 (或选 2 删除) 后按 Ctrl-D, 脚本直接 exit 1、
#     没有任何提示。menu_add/menu_del 里 `read ... || return` 的裸
#     return 返回的是 read 的退出码 1, 在 set -e 下会杀掉整个菜单。
#     本来想写的是 "取消这次操作、回菜单", 所以必须 return 0。v23
#     四处都改成 return 0, Ctrl-D 后回菜单、菜单再读到 EOF 才干净退出。
#  2. 菜单顶上的 "当前规则: N 条" 把非法行也数进去了 (1 条真规则 +
#     garbage + 缺字段行, 显示 3 条)。v23 只数 4 字段且协议是
#     tcp/udp/both 的行, 和 list 的显示口径一致。
# v22 修复 (相对 v21, 换角度排查: check 各节逐条核对, 发现 3 个问题):
#  1. Docker 发布端口段时 check 第 6 节假放行。docker_published_conflicts
#     的正则只认单个端口, `0.0.0.0:10000-10010->10000-10010/tcp` 一行都
#     匹配不上, 段里的端口全漏报, add 的冲突检查 (同一函数) 也一样漏。
#     v22 改成端口段也认 (hp 校验同步放宽, ports_overlap 本来就支持段)。
#  2. 无 dport 的全端口 DNAT 漏报。existing_dnat_conflicts 要求行里有
#     "tcp dport ", `ip daddr X dnat to Y` 这种全端口 DNAT 直接跳过。
#     v22 这种行直接报出来 (不按端口比对)。同函数的表名匹配也由 index()
#     子串改成精确比对, 否则另一张表叫 x-nft-forward-nat 也会被当成自家表。
#     第 2 节显示的 awk 同样改精确匹配。
#  3. 第 4 节无 systemd 分支的关键词比 systemd 分支少了
#     flvx|miaomiao|wireguard|wgcf, 没 systemd 的机器上这几个代理查不到。
#     v22 对齐两支的关键词。
# v21 修复 (相对 v20, 换角度排查: status/list 在各种状态下的输出逐条核对, 发现 4 个问题):
#  1. nat 表没了但规则还在时, list 提示 "先跑 install 或 add" 是错的。
#     规则都在文件里, 该跑的是 apply (正好是 nftables restart 清表后的
#     恢复场景)。v21 按规则文件是否为空分开提示。
#  2. 服务文件存在但被 disable 时, status 说 "未安装" 是错的,
#     它明明装了只是没启用。v21 分开说。
#  3. filter 表没了、/etc/nftables.conf 不存在时, list/status 那几节
#     静默少一行, 像输出断了。v21 明说 "(filter 表未创建...)" 和
#     "(/etc/nftables.conf: 不存在...)。
#  4. 规则文件里手写多字段/少字段的行, list 的 printf 会把多余字段
#     当成新一行印出来。v21 字段不对就原样印出来并标注 "格式不对"。
# v20 修复 (相对 v19, 换角度排查: help 文本与实际行为逐条核对):
# v20 修复 (相对 v19, 换角度排查: help 文本与实际行为逐条核对, 发现 1 个问题):
#  1. clear / uninstall / 转发 22 的三次确认提示没有 [ ! -t 0 ] 守卫。
#     stdin 是永远不 EOF 的管道时 (某些自动化环境、ssh 非 tty 继承的
#     输入流), 裸 read 会一直挂起, 进程卡死、没有任何输出。ss 冲突提示
#     (check_port_conflicts) 早有这个守卫, 三处补上同样守卫, 非交互
#     直接报错退出。注意: 这也意味着 echo y | nft-forward clear 这类
#     管道喂 y 的写法不再生效, 破坏性操作必须在终端里跑。
# v19 修复 (相对 v18, 换角度排查: 卸载完整性):
# v19 修复 (相对 v18, 换角度排查: 卸载完整性):
#  1. 卸载后残留 /etc/nftables.conf.bak.nft-forward。卸载只删了 include
#     行、没删 install 时建的这个备份, 每次装卸循环都会留下一个。v19 在
#     换行恢复逻辑跑完后把它也删掉 (锁文件 /run/nft-forward.lock 不删,
#     锁文件惯例: 删了会让等锁的进程和新进程锁到不同 inode, /run 是
#     tmpfs、重启就清了, 留着无害)。
# v18 修复 (相对 v17, 换角度排查: 对抗输入与退出码):
# v18 修复 (相对 v17, 换角度排查: 对抗输入与退出码):
#  1. check 发现问题也返回 0。check 报了 "!! 碰撞 / !! 规则非法"、结论说
#     有风险, 但退出码永远是 0, 自动化里 check && install 会误以为没问题
#     就继续装。v18 在 bad>0 时 return 1, 干净时仍返回 0; 菜单第 8 项已
#     用 || true 接住, 不会因此闪退 (直接调 cmd_check 的话, set -e 会退
#     出菜单)。
#  2. 对抗输入已验证无注入: rules.conf 里写 $(...)/反引号/分号/多余字段/
#     格式串, apply 全部 exit 1 挡住, 没有任何命令被执行, rules.nft 里也
#     没有 flush 行; 恶意 add 参数同样被挡; list/check 只打印不执行。
#     (脚本里没有 eval, 规则字段进 nft 文件前必过 validate。)
# v17 修复 (相对 v16, 生产环境角度: 开机恢复):
# v17 修复 (相对 v16, 生产环境角度: 开机恢复):
#  1. 开机顺序竞态: 转发丢了要手动恢复。nft-forward.service 只有
#     After=network-online.target, 和 nftables.service 之间没有顺序。
#     装的时候 nftables 没启用 (所以没加 include), 之后用户手动启用
#     nftables.service 的话, 开机时 nftables 的 flush ruleset 可能在
#     nft-forward.service 的 apply 之后跑, 把刚建好的转发表清掉, 转发
#     就断了, 要手动 apply 才恢复。v17 加 After=nftables.service (只
#     有顺序, 没有 Wants/Requires, 不会拉起一个本来没启用的服务),
#     保证 nftables 先 flush, nft-forward 再 apply 重建。
# v16 修复 (相对 v15, 换角度排查: 环境差异与缺失命令):
# v16 修复 (相对 v15, 换角度排查: 环境差异与缺失命令):
#  1. flock 缺失时报错误导。acquire_lock 直接调 flock -w 10, 精简系统上
#     flock 不存在会返回 127, 被当成"拿不到锁", 报"另一个 nft-forward 正
#     在运行 (等了 10 秒还是拿不到锁)", 实际上根本没有别的实例在跑, 只是
#     没装 flock。v16 先查 command -v flock, 缺失就跳过加锁并提示一次只
#     跑一个命令 (ss/docker/timeout/nft 都有这类 guard, 唯独 flock 没有)。
# v15 修复 (相对 v14, 换角度排查: 并发与中断):
# v15 修复 (相对 v14, 换角度排查: 并发与中断):
#  1. 并行 add 大量丢失。flock -n 一碰上锁就失败, 10 个并行 add 只成 1 个、
#     剩下 9 个都要手动重跑 (规则本身没乱, 只是丢了活)。v15 改成最多等 10 秒
#     (flock -w 10), 前一个做完就轮到下一个; 10 秒还拿不到才报错。
#  2. 持久化文件不是原子替换。apply 最后一步用 cp -f 写 rules.nft, cp 会先
#     截断目标再写, 中途被杀会留下一个写了一半的 rules.nft, 下次开机 nftables
#     加载 include 时失败, 连 nftables 服务都起不来。v15 把临时文件建在规则
#     目录里 (和 rules.nft 同一文件系统), 最后一步用 mv 原子替换, 要么是旧
#     文件、要么是新文件, 不会有半截; 并在 apply 开头清掉上次被杀留下的临时文件。
# v14 修复 (相对 v13, 继续排查发现的剩余问题):
# v14 修复 (相对 v13, 继续排查发现的剩余问题):
#  1. nft 缺失且自动安装失败时没有明确报错。check_nft 里 apt-get/dnf/yum
#     失败后, 在 set -e 下脚本直接退出, 只剩包管理器自身的报错 (如 "E: 无
#     法获取锁"), 用户不知道是 nftables 没装上、install 没继续。v14 用
#     || true 接住安装命令的失败, 装完显式校验 nft 是否存在, 不存在就 die
#     一句明白话。
# v13 修复 (相对 v12, 再仔仔细细核对发现的剩余问题):
# v13 修复 (相对 v12, 再仔仔细细核对发现的剩余问题):
#  1. README 里的版本号还是旧的。标题写着 v7、菜单示例写着 v8, 脚本已是
#     v12, 都是升版时没跟着改的 (和 v11 修的脚本内版本号过期是同一类问题,
#     这次是在 README 里)。v13 把 README 标题、菜单示例、文件说明里的版本
#     号都改成 v13, 和脚本一致。脚本逻辑没动, 只改版本号和注释。
# v12 修复 (相对 v11, 再仔仔细细核对发现的剩余问题):
# v12 修复 (相对 v11, 再仔仔细细核对发现的剩余问题):
#  1. check 对非法规则假放行。rules.conf 里手写了 sctp、缺字段等非法规则时,
#     check 第 6 节不校验规则本身, 直接报 "OK, 未发现碰撞"、结论说"可以继续",
#     但 apply 根本加载不了这条规则。v12 在第 6 节逐条比对前先调 validate_rule
#     校验 (放子 shell 里跑, 失败不退出 check), 非法就标 "!! 规则非法" 并计入
#     bad, 结论不再说可以继续。
# v11 修复 (相对 v10, 再仔仔细细核对发现的剩余问题):
# v11 修复 (相对 v10, 再仔仔细细核对发现的剩余问题):
#  1. 用户能看到的字样里还写着 v7, 脚本已是 v10。报错信息 "(v7 只支持 IPv4
#     目标)"、list 的 "(v7: 只有 nftables 服务本来就启用时才加...)"、help 里
#     的 "v7 只支持 IPv4" 和 "v7 不主动 enable" 共 5 处, 都是 v7 时期写死的
#     版本号, 之后升版没跟着改。v11 把用户可见字样里的版本号全去掉 (只留
#     注释里的 v7/v8/v9 当历史记录), 以后再升版也不会又过期。
#  2. (新验证手段, 不是脚本 bug) 这次试了用 unshare 建 user+net namespace
#     跑真 nft: 不带 fib/ct 的 DNAT 和链结构能正常加载, 说明生成的 nft 文件
#     语法没错; 但 `fib daddr type local`、`ct status dnat`、`ct state` 这三
#     类规则在本容器里都报 "No such file or directory", 原因是本容器内核没
#     有 nft_fib / nft_ct 模块 (/lib/modules 不存在、modinfo 找不到)。这是测
#     试环境的限制, 不是脚本问题 (这些都是标准表达式, 正常 VPS 内核都有),
#     但也说明脚本核心安全规则 (fib+ct) 在这边至今仍没在真内核上跑通过,
#     仍需在真 VPS 上验证。
# v10 修复 (相对 v9, 仔仔细细逐行核对发现的剩余问题):
# v9 修复 (相对 v8, 再仔细检查发现的剩余问题):
#  1. status 输出里有没头没尾的 "enabled"/"disabled"。cmd_status 用
#     `systemctl is-enabled X 2>/dev/null || echo ...`, systemctl 在 stdout
#     上本来就会打印 enabled/disabled, 2>/dev/null 只挡 stderr, 所以
#     status 里会冒出光秃秃的一行 "disabled" 或 "enabled", 没标签、看不懂。
#     v9 改成 `is-enabled --quiet` (只返回退出码、不打印), 再按结果打印
#     带标签的中文状态, 启用/未启用都看得明白。
#  2. (顺带确认, 不是 bug) 手写 rules.conf 时 both / 大写 TCP / 多余字段
#     都会被 validate 拒掉 (both: 协议只能是 tcp/udp; 大写 TCP 同样拒;
#     多余字段会进到目标端口里、端口校验失败), Tab 分隔的字段正常通过;
#     目标写成本机自己的 IP 时是本地端口重定向 (18080 -> 本机:80), 不是
#     死循环, 不拦截, 只在 README 里注明。
# v10 修复 (相对 v9, 仔仔细细逐行核对发现的剩余问题):
#  1. [高危, 报错全丢] acquire_lock 里 `exec 9>"$LOCK_FILE" 2>/dev/null` 会把
#     整个进程的 stderr 永久指到 /dev/null (exec 不带命令时重定向作用于当前
#     shell)。add/del/clear/apply/install/uninstall 都先调 acquire_lock, 所以
#     之后所有 die 的报错都看不见, 只剩一个光秃秃的 exit 1。实测: add 99999、
#     add 999.1.1.1 都只返回 exit 1、没有任何报错信息; 直接测 `exec 9>锁 2>/dev/null`
#     后 `echo ... >&2` 也确实没输出。v10 去掉这行上的 2>/dev/null (打不开锁文件时
#     bash 自己的报错可见, || 兜底仍会走跳过加锁的分支)。uninstall 里的
#     `exec 9>&- 2>/dev/null` 同样会吞 stderr, 一并去掉。
#  2. [中] 规则文件里只有空格/Tab 的空行会被当成规则, apply 直接报"缺字段"失败;
#     check 第 6 节会打印 "检查:  -> :" 的空行还报 OK; list 会打印空白行。
#     v10 把 6 处读文件循环的空行判断改成"全空白也算空行", 和注释行一样跳过。
#  3. clear 在没安装过时 (RULES_DIR 不存在) 会因 `: >` 目录不存在而失败退出。
#     v10 先 mkdir -p, 和 cmd_add 保持一致。
#  4. 头部注释里 v8 标题行重复出现两次, 删掉一行 (纯注释, 不影响功能)。
#  5. backup_rules 在规则文件不存在时返回 1, 在 set -e 下调用它的命令会直接
#     退出且没有任何报错。实测: 没安装过时 clear 直接 exit 1、无输出 (trace
#     到 backup_rules 的 `[ -f ]` 就停了)。v10 改成 if 写法并显式 return 0。
# v8 修复 (相对 v7, 再仔细检查 + shellcheck 发现的剩余问题):
#  1. shellcheck 警告全部清掉 (之前 warning 级别有 1 个 warning + 2 个 error)。
#     - valid_ip 的 `local -a o=($ip)` 改成 `IFS='.' read -ra o` (SC2206)。
#     - check 里 `grep -E ":$pt[[:space:]]"` 改成 `":${pt}[[:space:]]"`,
#       消除 $pt[...] 被当成数组展开的歧义 (SC1087, 虽然实测没错, 但含糊)。
#     - 两处 `A && B || die` 改成显式 if (SC2015, 原写法意图是对的, 但
#       A 真 B 假时 C 也会跑, 换成 if 更不容易看错)。
#     - include 追加时 `tail | read` 和 `>>` 写同一个文件改成先读到变量
#       再追加 (SC2094)。
#  2. docker ps 卡住会拖住 add/check。docker daemon 僵住时 `docker ps`
#     可能一直不返回, add/check 就会一直等。v8 给 docker ps 加 5 秒超时
#     (有 timeout 命令时用, 没有就按原来跑), 超时按"查不到"处理, 不阻塞。
#  3. 原文件末尾没换行时, 卸载恢复不成原样。install 会在原内容后补一个换行
#     再追加 include, 卸载时只删 include 两行, 补的那个换行留下来了, 文件
#     末尾就多了一个换行。v8 在卸载后拿备份文件对照, 备份末尾没换行、当前
#     文件末尾有换行时, 去掉末尾一个换行, 恢复成字节级原样 (mock 实测: 有/
#     无末尾换行两种原文件, 卸载后 diff 都干净)。同时 install 每次都刷新
#     备份 (原来只在备份不存在时才建, 重装后备份会是旧文件的, 对照就错了)。
# v7 修复 (相对 v6, 再仔细检查发现的剩余问题):
#  1. 重复/重叠的转发规则会被悄悄接受。手写 rules.conf 时,
#     `tcp 18080 -> 1.2.3.4:80` 和 `tcp 18080 -> 9.9.9.9:90` 会同时
#     生成两条 DNAT, 第一生效、第二条是死规则, 用户以为两条都通;
#     `tcp 18080` 和 `tcp 18080-18090` 重叠也一样。v7 在 validate 时
#     按协议查本机端口重叠, 有重叠直接报错, 不生成歧义规则。
#     (add 命令本身有去重, 所以这只防手写文件, 但手写文件是常见用法。)
#  2. 目标 IP 0.0.0.0 / 255.255.255.255 会被接受。DNAT 到 0.0.0.0
#     是无效地址, 到 255.255.255.255 是广播地址, 真机 nft 加载时
#     要么报错、要么建出一条不通的规则, mock 里却显示"已添加"。
#     v7 在 validate 和 add 里都拒掉这两个地址 (以及 0.x.x.x)。
#  3. 其他表用集合写法的 DNAT 查不到。`tcp dport { 18081, 18082 } dnat`
#     或 `udp dport { 19000-19010 } dnat` 时, 旧的检查只认 `dport 数字`
#     这种写法, 集合里的端口一个都查不到, add 就直接放行、抢走别人的
#     流量。v7 把冲突检查改成在 awk 里直接解析集合 (单端口、范围、
#     逗号分隔的多个端口/范围都认), 有重叠就报警。
# v6 修复 (相对 v5, 再检查发现的剩余问题):
#  1. del 不存在的规则也报"已删除"。`del 19999` 和 `del 18080 udp` (只有 tcp
#     时) 都会 exit 0 并绿字"已删除", 实际上文件里什么都没动, 还白跑一次
#     apply。v6 先查规则在不在, 不在就直接报错"没有这条规则", 不备份、
#     不 apply、不谎报成功。
#  2. 多余参数被静默忽略。`add 8080 1.2.3.4 80 tcp extra` 会成功并丢掉
#     extra; 更危险的是 `clear foo` 也会真的清空全部规则。v6 在 add/del
#     里拒掉多余参数, 在分发处对 list/status/check/clear/apply/uninstall
#     等无参命令也拒掉多余参数。
#  3. 前导空格的规则删不掉。rules.conf 里 `  tcp 18080 ...` (行首有空格)
#     时, sed 的 `^tcp` 匹配不上, del 报"已删除"但规则还在, add 同端口
#     时去重也删不掉旧行、会写出重复规则。v6 的 sed 改成允许行首空白,
#     且 add/del 的存在性检查也用同样宽松的匹配。
# v5 修复 (相对 v4, 继续检查发现的剩余问题):
#  1. [高危, Docker 检查完全失效] docker_published_conflicts 里的
#     `tr -d ':->'` 把 '-' 当成了字符范围 ':' 到 '>' (ASCII 58-62), 删不掉 '-',
#     导致主机端口变成 "8080-" 这种带横杠的字符串, 后面的 ^[0-9]+$ 校验永远
#     失败、直接 continue, Docker 冲突检查从 v2 起就从没报过任何一次。
#     v5 改用 grep -oE ':[0-9]+->[0-9]+/(tcp|udp)' 直接取主机端口和协议,
#     顺便修了协议误报: 之前不分 tcp/udp, Docker 只发布了 tcp 8080 时,
#     加 udp 8080 也会误报; 现在只报同协议的冲突。
#  2. [中危] rules.conf 带 Windows 换行 (\r\n) 时 apply 会失败。
#     read 出来的 tport 会变成 "80\r", valid_port 的 ^[0-9]+$ 通不过,
#     报错还看不出 \r, 很难排查。v5 在 validate/build/check 的每个读文件
#     循环里都先去掉行尾 \r, 并在 validate 失败时把 \r 显示为 <CR>。
#  3. [中危] 端口段前导零算错/崩溃。port_len 用 $((020-010+1)) 会把 010 当
#     八进制, 010-020 算成 9 而不是 11; 08-09 直接报 "value too great for
#     base" 崩溃。v5 在 port_len / ports_overlap 里都用 10# 强制十进制。
#  4. [中危] add 端口段时静默丢弃用户填的目标端口。`add 10000-10010 1.2.3.4 80`
#     会被悄悄改成 10000-10010 (1:1), 用户填的 80 不声不响就没了。
#     v5 删掉这段静默覆盖, 只留"不填目标端口时默认跟本机端口一样"这一条;
#     显式填了单个 80 时, 长度校验会直接报错, 告诉用户段只能转同样数量的段。
#  5. uninstall 不加锁, 可能和正在跑的 apply/add 并发删表/删规则文件。
#     v5 开头就 acquire_lock, 删本体前先关掉锁 fd (否则后台删脚本的进程
#     会继承锁 fd, 锁住 1 秒)。
#  6. 转发 22 端口时跳过全部冲突检查 (包括其他表 DNAT 和 Docker)。
#     v5 在 22 确认之后, 仍查其他表 DNAT 和 Docker 冲突, 有冲突直接拒绝;
#     只跳过 ss 监听检查 (sshd 本来就占着 22, 那是预期内的)。
# v4 修复 (相对 v3, 最终核对发现的剩余问题):
#  1. install 不再用 systemctl enable --now。v3 的 install 在持有 flock 锁的情况下
#     --now 启动 nft-forward.service, 那个服务进程也要拿同一把锁, 会直接失败。
#     v4 只 enable (不开 --now), 立即生效靠 install 里直接调的 apply_rules, 不靠服务启动。
#  2. include 增加 flush 检查。v3 只查 nftables.service 是否启用就追加 include,
#     但如果 /etc/nftables.conf 里没有 "flush ruleset", 重启加载时表已存在会
#     因 "table already exists" 导致整个 nftables 服务加载失败。
#     v4 要求文件里必须有 flush ruleset 才加 include, 否则跳过并提示只靠本服务恢复。
#  3. check 命令的 DNAT 检查不再误报。v3 里 nft list 失败时, grep 空结果也会显示
#     "(无其他 DNAT)", 会让人误以为已检查过。v4 先判 nft list 是否成功, 失败就明确说
#     "无法检查, 请用 root 且有 NET_ADMIN 权限再跑", 不再假装无冲突。
#  4. filter 放行规则的匹配顺序统一为 ip daddr 在前, 与 masquerade 规则一致,
#     避免个别 nft 版本对匹配顺序的解析差异。
#  5. [高危, 假碰撞] DNAT 冲突检查只认真正的 "dnat to" 行, 且排除本表的两个表。
#     v3 的检查用 grep "dnat" 会把 "ct status dnat masquerade/accept" 也当成 DNAT,
#     且只排除 nft-forward-nat 表、不排除 nft-forward-filter 表, 导致本地端口
#     等于目标端口的规则 (如 51820->51820) 在 check 里报假碰撞, 甚至会拦住
#     同端口覆盖重加。v4 用 awk 按表名排除 nat+filter 两个表, 且只认 "dnat to"。
#     check 第 2 节同样修: 之前 grep -v nft-forward 排除不了本表 DNAT (DNAT 行
#     本身不含表名), 会把本表规则也列为"其他表 DNAT"。
# v3 的修复全部保留: DNAT 加 fib daddr type local、MASQUERADE 加 ct status dnat、
# 不主动 enable nftables.service、route_localnet 按需开启、端口冲突查 DNAT+Docker、
# check 命令、forward policy accept、原子加载等。
# 仍不支持 IPv6 转发 (只支持 IPv4 目标)。
#
# 一键安装:  bash nft-forward.sh install   (或直接 bash nft-forward.sh, 无参数自动进菜单)
# 呼出菜单:  nft-forward   或   zf   (安装后任意目录直接输)
# 命令行:    nft-forward add 8080 1.2.3.4 80 tcp
# 上线前检查: nft-forward check
# v25 修复 (基于 v24 复核):
#  1. del 参数未校验就拼入 grep/sed 正则, `del .*` 等输入可能误删多条规则。
#     现在先校验端口并规范化, 阻断正则注入/误删。
#  2. 脚本只支持 IPv4 转发, install 却无条件开启 IPv6 forwarding, 可能改变
#     VPS 的 IPv6 路由/RA 行为。移除无关 IPv6 sysctl 修改。
#  3. clear 在规则文件原先不存在时没有备份, apply 失败无法恢复原始状态。
#     现在先创建空规则文件再备份, 失败时可恢复为空文件。
#  4. Docker CLI 存在但 daemon 查询失败/超时时, 原来被当成"无冲突"。
#     改为明确报错并拒绝 add, check 也将其计为风险。
#  5. 拒绝 IPv4 八进制/歧义形式的前导零, 避免不同解析器对地址含义不一致。
set -euo pipefail

#  1. [高危, 代理失效根因] DNAT 只对本机地址生效: 加 fib daddr type local。
#     v2 的 DNAT 是 "$proto dport X dnat to ..." 不限目的 IP, 会劫持所有经过本机
#     prerouting 且目的端口相同的流量, 包括:
#       - Docker 容器出站、Xray/mihomo 出站、WireGuard/WARP 出站要去外部服务器的流量
#       - 经本机转发的其他代理流量 (WireGuard 对端、TUN 流量、内网客户端经本机去外网)
#     只要目的端口撞上转发端口, 就会被改写到转发目标, 代理就断了。
#     修后只有目的地址是本机 IP (公网 IP / 私网 IP / 云厂商 NAT 后翻译成的私网 IP)
#     的包才会被 DNAT, 其他流量原样通过。这是 Docker / systemd 用的标准写法。
#  2. [高危] MASQUERADE 只对被 DNAT 过的连接生效: 加 ct status dnat。
#     v2 的 masquerade 是 "ip daddr 目标 tcp dport 端口 masquerade", 会改写本机代理
#     进程自己主动去连同一个目标 IP:端口时的源地址 (如 Xray 出站连落地机)。
#     修后只有 ct status dnat 的包才 masquerade, 本机出站流量不动。
#     forward 链的放行规则同样加 ct status dnat, 只放行被 DNAT 过的流。
#  3. [高危] 不再 enable nftables.service。v2 的 install 会 systemctl enable
#     nftables.service, 可能激活一台之前处于禁用状态的默认防火墙配置
#     (/etc/nftables.conf 里自带的 filter 表), 下次开机就把代理端口挡掉。
#     v3 不动 nftables.service 的启用状态, 只用自己的 nft-forward.service 开机恢复。
#     自己的服务也不再 After=nftables.service, 只 After=network-online.target。
#  4. include 只在 nftables.service 本来就已启用时才加。
#     v2 是只要 /etc/nftables.conf 存在就追加 include; v3 先查
#     systemctl is-enabled nftables.service, 本来没启用的就不改那个文件,
#     只靠自己的服务开机恢复, 避免把一个 dormant 的配置激活。
#  5. route_localnet 不再安装时全局开启。v2 的 install 就写
#     net.ipv4.conf.all.route_localnet=1, 会放宽 127.0.0.0/8 的路由。
#     v3 只在 apply 时、且确实有规则要转到 127.0.0.1 时才开, 没有这种规则就不开。
#  6. 端口冲突检查补上 ss 查不到的两类:
#     a) 其他表已有的 DNAT: 查 nft list ruleset 里非本表的 dnat 规则, 同端口/端口段
#        重叠就报警 (Docker / K8s / 其他面板的 DNAT 在 ss 里看不到监听端口)。
#     b) Docker 已发布端口: 查 docker ps 的 Ports 列, 已发布的主机端口同样报警。
#     之前只查 ss, Docker 容器端口和别的面板的 DNAT 是查不到的。
#  7. 新增 check / preflight 命令和菜单第 8 项: 上线前检查。
#     一次性列出本机所有监听端口、其他表的 DNAT、Docker 发布端口、代理相关服务
#     (xray/sing-box/mihomo/wg/docker/nginx 等)、本机 IP, 并逐条比对现有转发规则
#     有没有撞上, 没撞上才建议继续。
# v2 的修复全部保留: forward policy accept、原子加载、端口段长度校验、sysctl 容错、
# 加锁+备份、菜单终端判断、卸载延迟删本体、systemd 缺失容错。
# 仍不支持 IPv6 转发 (只支持 IPv4 目标)。
#
# 一键安装:  bash nft-forward.sh install   (或直接 bash nft-forward.sh, 无参数自动进菜单)
# 呼出菜单:  nft-forward   或   zf   (安装后任意目录直接输)
# 命令行:    nft-forward add 8080 1.2.3.4 80 tcp
# 上线前检查: nft-forward check
set -euo pipefail

SCRIPT_VERSION="v30"
SCRIPT_PATH="/usr/local/bin/nft-forward.sh"
SHORTCUT_PATH="/usr/local/bin/nft-forward"
SHORTCUT_PATH2="/usr/local/bin/zf"
RULES_DIR="/etc/nft-forward"
RULES_FILE="$RULES_DIR/rules.conf"
RULES_NFT="$RULES_DIR/rules.nft"
SYSCTL_FILE="/etc/sysctl.d/99-nft-forward.conf"
SERVICE_FILE="/etc/systemd/system/nft-forward.service"
NFTABLES_CONF="/etc/nftables.conf"
LOCK_FILE="/run/nft-forward.lock"
NAT_TABLE="nft-forward-nat"
FILTER_TABLE="nft-forward-filter"

red()   { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
yellow(){ echo -e "\033[33m$*\033[0m"; }
die()   { red "错误: $*" >&2; exit 1; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "请用 root 运行: sudo $0"
}

has_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

# v29: 没包管理器时, 按系统给一句能照着做的报错, 而不是只说"手动安装"。
# 读 /etc/os-release 拿发行版 (只 grep 几个字段, 不 source 整个文件);
# 参数是可选的文件路径, 只是为了方便单测 (生产调用不传, 默认读系统文件)。
distro_hint() {
    local f="${1:-/etc/os-release}"
    local id="" ver="" codename="" arch=""
    if [ -f "$f" ]; then
        id=$(grep -E '^ID=' "$f" 2>/dev/null | cut -d= -f2 | tr -d '"')
        ver=$(grep -E '^VERSION_ID=' "$f" 2>/dev/null | cut -d= -f2 | tr -d '"')
        codename=$(grep -E '^VERSION_CODENAME=' "$f" 2>/dev/null | cut -d= -f2 | tr -d '"')
    fi
    arch=$(dpkg --print-architecture 2>/dev/null || uname -m 2>/dev/null || echo "?")
    local base="本机没有 apt-get/apt/dnf/yum/apk/pacman/zypper"
    case "$id" in
        ubuntu|debian)
            if command -v dpkg >/dev/null 2>&1; then
                local pool="http://deb.debian.org/debian/pool/main/a/apt/"
                [ "$id" = "ubuntu" ] && pool="http://archive.ubuntu.com/ubuntu/pool/main/a/apt/"
                echo "${base}。本机是 ${id} ${ver} (${codename}, ${arch}), 有 dpkg 但没有 apt: 请从 ${pool} 下载对应版本的 apt_*.deb 后 dpkg -i 安装, 再跑 install"
            else
                echo "${base}。本机是 ${id} ${ver} (${codename}, ${arch}), 连 dpkg 都没有 (系统镜像被精简过或已损坏), 请用完整系统镜像重装, 或手动安装 nftables 后重试"
            fi
            ;;
        alpine|arch|opensuse*|sles)
            echo "${base}。本机是 ${id}, 但它的包管理器不在了 (镜像被精简过), 请用完整系统镜像重装, 或手动安装 nftables 后重试"
            ;;
        *)
            if [ -n "$id" ]; then
                echo "${base}。本机是 ${id} ${ver}, 请手动安装 nftables 后重试"
            else
                echo "${base}, 也读不到发行版信息, 请手动安装 nftables 后重试"
            fi
            ;;
    esac
    return 0
}

check_nft() {
    command -v nft >/dev/null 2>&1 && return 0
    yellow "未找到 nft, 正在尝试安装..."
    # v28: apt-get 本身装不了——它就是装软件的工具, 没有包管理器就没法装
    # 包管理器 (鸡生蛋问题)。能做的是把检测范围扩到主流发行版都有的那几
    # 个: apt-get 没有就试 apt, 再依次试 dnf/yum/apk/pacman/zypper, 哪个
    # 在就用哪个。7 个全没有才报错让手动装。
    if command -v apt-get >/dev/null 2>&1; then
        # v14: 安装命令失败时 (断网、锁冲突、源问题) 不能让它在 set -e 下
        # 直接退出、只剩 apt 自身的报错。|| true 先接住失败, 下面统一校验。
        apt-get update && apt-get install -y nftables || true
    elif command -v apt >/dev/null 2>&1; then
        apt update && apt install -y nftables || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y nftables || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y nftables || true
    elif command -v apk >/dev/null 2>&1; then
        apk add nftables || true
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm nftables || true
    elif command -v zypper >/dev/null 2>&1; then
        zypper install -y nftables || true
    else
        # v29: 没有包管理器是装不了 apt-get 的 (apt-get 就是安装器本身),
        # 所以这里不硬装, 改成按系统给一句能照着做的办法。
        die "无法自动安装 nftables: $(distro_hint /etc/os-release)"
    fi
    # v14: 装完必须能找到 nft 才算成功, 否则给一句明白话 (之前 apt 失败时
    # 脚本在 set -e 下直接退出, 只剩 apt 的报错, 用户不知道是没装上)。
    command -v nft >/dev/null 2>&1 || die "nftables 自动安装失败 (上面是包管理器的报错), 请检查网络/源后手动安装 nftables 再重试"
}

acquire_lock() {
    [ -n "${LOCK_HELD:-}" ] && return 0
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || LOCK_FILE="/tmp/nft-forward.lock"
    # v10: 千万别在这行加 2>/dev/null。exec 不带命令时, 重定向作用于当前 shell,
    # 2>/dev/null 会把整个进程的 stderr 永久指到 /dev/null, 之后所有 die 的
    # 报错 (端口不合法、IP 不合法、锁冲突等) 都看不见, 只剩一个光秃秃的 exit 1。
    # 实测: add 99999 / add 999.1.1.1 都只返回 exit 1、没有任何报错信息。
    # v16: flock 缺失时 (精简系统、busybox) 不能直接调 flock -w 10, 命令不存
    # 在会返回 127, 被当成"拿不到锁"报"另一个正在运行", 误导用户。没 flock
    # 就跳过加锁并提示, 一次只跑一个命令即可。
    if ! command -v flock >/dev/null 2>&1; then
        yellow "提示: 本机没有 flock, 跳过加锁 (请一次只跑一个 nft-forward 命令, 避免互相覆盖规则)"
        LOCK_HELD=1  # 标记已处理, 同一进程里不再重复提示
        return 0
    fi
    exec 9>"$LOCK_FILE" || { yellow "提示: 无法创建锁文件, 跳过加锁"; return 0; }
    # v15: 原来 flock -n 一碰上锁就失败。两个 add 同时跑 (两个 SSH 会话、
    # 脚本并行加规则) 时, 一个成功、另一个直接报错, 10 个并行 add 只成 1 个、
    # 剩下 9 个都要手动重跑。改成最多等 10 秒 (flock -w 10), 前一个做完就
    # 轮到下一个; 10 秒还拿不到才报错, 卡住的锁也不会无限等。
    if ! flock -w 10 9 2>/dev/null; then
        die "另一个 nft-forward 正在运行 (等了 10 秒还是拿不到锁), 请等它结束再试"
    fi
    LOCK_HELD=1
}

backup_rules() {
    # v10: 文件不存在时也必须返回 0。原来 `[ -f ] && cp` 在文件不存在时返回 1,
    # 在 set -e 下调用它的命令 (如没安装过时的 clear) 会直接退出, 且没有任何报错。
    if [ -f "$RULES_FILE" ]; then
        cp -f "$RULES_FILE" "$RULES_FILE.bak"
    fi
    return 0
}

valid_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local -a o=()
    IFS='.' read -ra o <<< "$ip"
    for n in "${o[@]}"; do
        # 只接受标准十进制写法; 例如 010.0.0.1 在不同工具中可能被解释不一致。
        [[ "$n" == "0" || "$n" =~ ^[1-9][0-9]{0,2}$ ]] || return 1
        [ "$n" -le 255 ] 2>/dev/null || return 1
    done
    return 0
}

# v27: 把"目标"解析成 IPv4。已经是合法 IP 就原样用; 是域名就 DNS 解析一次,
# 返回解析到的第一个 IPv4, 调用方把它存进 rules.conf (只存 IP, 不存域名)。
# 为什么不在每次 apply 时重新解析: 开机时 systemd 跑 apply, 那时 DNS 可能
# 还没好, 解析失败会让整批规则加载失败、转发全断。添加时解析一次, 之后不再
# 依赖 DNS; 域名 IP 变了要 del 了重加 (那时再解析一次)。
# 返回值: 0 成功 (stdout 是 IP); 1 不是合法 IP、域名也解析不到 IPv4;
# 2 本机没有任何可用的解析工具。
resolve_target() {
    local input="$1"
    if valid_ip "$input"; then
        echo "$input"
        return 0
    fi
    # 含冒号的是 IPv6 地址 (仍不支持), 其它连域名长相都不是的直接拒掉,
    # 不拿去问 DNS。
    if [[ "$input" == *:* ]] || [[ ! "$input" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]] || [ "${#input}" -gt 253 ]; then
        return 1
    fi
    # v27 补: 最后一节必须以字母开头。否则 "010.0.0.1"、"1.2.3"、"0x7f.0.0.1"
    # 这类数字串会被解析器按 inet_aton 规则曲解 (010 当八进制变成 8、1.2.3
    # 变成 1.2.0.3、0x7f 当十六进制变成 127), 明明不是合法 IP 却"解析成功"。
    # 真域名的最后一节 (TLD 或主机名) 一定以字母开头。
    local _last="${input##*.}"
    [[ "$_last" =~ ^[A-Za-z] ]] || return 1
    local ip="" out="" _tried=0
    # getent 最常见 (glibc 自带, Ubuntu/Debian/CentOS 精简版都有); 有 timeout
    # 就套 8 秒, DNS hang 住时不让 add 卡死。多个 A 记录取第一个 IPv4;
    # getent 可能先给 IPv6 行, awk 只认点分十进制的第一字段。
    if command -v getent >/dev/null 2>&1; then
        _tried=1
        if command -v timeout >/dev/null 2>&1; then
            out=$(timeout 8 getent hosts "$input" 2>/dev/null || true)
        else
            out=$(getent hosts "$input" 2>/dev/null || true)
        fi
        ip=$(printf '%s\n' "$out" | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1; exit}')
    fi
    # nslookup: 输出里第一个 Address 是 DNS 服务器本身 (带 #53 后缀),
    # 取最后一个匹配的 Address 行才是答案。
    if [ -z "$ip" ] && command -v nslookup >/dev/null 2>&1; then
        _tried=1
        out=$(nslookup "$input" 2>/dev/null || true)
        ip=$(printf '%s\n' "$out" | awk '/^Address: [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {ip=$2} END {if (ip) print ip}')
    fi
    if [ -z "$ip" ] && command -v dig >/dev/null 2>&1; then
        _tried=1
        out=$(dig +short +time=5 +tries=1 "$input" A 2>/dev/null || true)
        ip=$(printf '%s\n' "$out" | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1; exit}')
    fi
    if [ -z "$ip" ] && command -v host >/dev/null 2>&1; then
        _tried=1
        out=$(host "$input" 2>/dev/null || true)
        ip=$(printf '%s\n' "$out" | awk '/has address / {print $NF; exit}')
    fi
    if [ -z "$ip" ] && command -v python3 >/dev/null 2>&1; then
        _tried=1
        ip=$(python3 -c 'import socket,sys; print(socket.gethostbyname(sys.argv[1]))' "$input" 2>/dev/null || true)
    fi
    [ "$_tried" -eq 0 ] && return 2
    if [ -z "$ip" ] || ! valid_ip "$ip"; then
        return 1
    fi
    echo "$ip"
    return 0
}

valid_port() {
    local p="$1"
    if [[ "$p" =~ ^[0-9]+$ ]]; then
        [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
    elif [[ "$p" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        [ "${BASH_REMATCH[1]}" -ge 1 ] && [ "${BASH_REMATCH[2]}" -le 65535 ] \
            && [ "${BASH_REMATCH[1]}" -lt "${BASH_REMATCH[2]}" ]
    else
        return 1
    fi
}

port_len() {
    local p="$1"
    if [[ "$p" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        # v5: 用 10# 强制十进制, 否则 010 会被当八进制 (010-020 算成 9 而不是 11),
        # 08/09 会直接报 "value too great for base" 崩溃。
        echo $((10#${BASH_REMATCH[2]} - 10#${BASH_REMATCH[1]} + 1))
    else
        echo 1
    fi
}

# 把端口/端口段归一化成标准十进制 (去掉前导零): 010-020 -> 10-20, 08 -> 8。
# 不归一化的话, 生成的 nft 文件里会出现 dport 010-020, 万一 nft 按八进制
# 解析, 转发的就是 8-16 而不是 10-20, 错得悄无声息。
norm_port() {
    local p="$1"
    if [[ "$p" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        echo "$((10#${BASH_REMATCH[1]}))-$((10#${BASH_REMATCH[2]}))"
    else
        echo "$((10#$p))"
    fi
}

# 判断两个端口段是否重叠: $1=段A (单个或 a-b), $2=段B, 重叠返回 0
ports_overlap() {
    local a="$1" b="$2" a1 a2 b1 b2
    if [[ "$a" =~ ^([0-9]+)-([0-9]+)$ ]]; then a1="${BASH_REMATCH[1]}"; a2="${BASH_REMATCH[2]}"; else a1="$a"; a2="$a"; fi
    if [[ "$b" =~ ^([0-9]+)-([0-9]+)$ ]]; then b1="${BASH_REMATCH[1]}"; b2="${BASH_REMATCH[2]}"; else b1="$b"; b2="$b"; fi
    # v5: 同样用 10# 强制十进制, 避免前导零被当八进制。
    (( 10#$a1 <= 10#$b2 && 10#$b1 <= 10#$a2 ))
}

validate_rule() {
    local proto="$1" lport="$2" tip="$3" tport="$4"
    case "$proto" in tcp|udp) ;; *) die "规则非法: 协议只能是 tcp/udp, 得到: $proto";; esac
    valid_port "$lport" || die "规则非法: 本机端口不合法: $lport"
    valid_port "$tport" || die "规则非法: 目标端口不合法: $tport"
    valid_ip "$tip" || die "规则非法: 目标 IP 不合法: $tip (只支持 IPv4 目标, 不支持 IPv6)"
    # v7: 0.0.0.0 是无效地址、255.255.255.255 是广播地址, DNAT 到它们要么
    # 加载失败、要么建出不通的规则, 不能等 nft 报错才发现。
    case "$tip" in
        0.0.0.0|255.255.255.255|0.*) die "规则非法: 目标 IP 不能是 $tip (无效/广播地址)" ;;
    esac
    local llen tlen
    llen=$(port_len "$lport"); tlen=$(port_len "$tport")
    [ "$llen" -eq "$tlen" ] || die "规则非法: 本机端口段有 $llen 个端口, 目标端口段有 $tlen 个, 数量必须一致 (如 10000-10010 只能转到同样 11 个端口的段)"
}

validate_rules_file() {
    [ -f "$RULES_FILE" ] || return 0
    local seen=""
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"  # v5: 去掉 Windows 换行 \r
        [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
        local proto lport tip tport
        read -r proto lport tip tport <<< "$line"
        if [ -z "${proto:-}" ] || [ -z "${lport:-}" ] || [ -z "${tip:-}" ] || [ -z "${tport:-}" ]; then
            die "规则文件非法: 这一行缺字段: $line (应为: 协议 本机端口 目标IP 目标端口)"
        fi
        validate_rule "$proto" "$lport" "$tip" "$tport"
        # v7: 同一协议的本机端口不能重复/重叠, 否则两条 DNAT 里只有第一条生效,
        # 第二条是死规则。add 命令本身有去重, 这里防的是手写 rules.conf。
        while IFS= read -r sline; do
            [ -n "$sline" ] || continue
            local sprot slport
            read -r sprot slport <<< "$sline"
            [ "$sprot" = "$proto" ] || continue
            if ports_overlap "$lport" "$slport"; then
                die "规则文件非法: 本机端口 $proto $lport 与已有规则 $sprot $slport 重叠, 同一协议的同一端口只能转到一个目标"
            fi
        done <<< "$seen"
        seen="$seen
$proto $lport"
    done < "$RULES_FILE"
}

listening_ports() {
    local proto="$1"
    command -v ss >/dev/null 2>&1 || return 0
    if [ "$proto" = "tcp" ]; then
        ss -tln 2>/dev/null | tail -n +2 | awk '{print $4}' | while IFS= read -r f; do echo "${f##*:}"; done
    else
        ss -uln 2>/dev/null | tail -n +2 | awk '{print $4}' | while IFS= read -r f; do echo "${f##*:}"; done
    fi
}

# 查其他表 (非本表) 已有的 DNAT, 输出冲突行 (空表示无冲突)
# $1=本机端口(单个或范围), $2=协议(tcp/udp)
existing_dnat_conflicts() {
    local lport="$1" proto="$2"
    # v25: 原来 nft 缺失或 nft list 失败时 return 0, 调用方会当成"没有冲突"。
    # 这是 fail-open: 恰恰在最需要检查的时候 (没权限读规则集) 假装查过了,
    # add 会继续把规则加上, check 第 6 节也会报 "OK, 未发现碰撞"。
    # 改成返回 2 表示"查不了", 调用方各自处理: add 拒绝添加, check 计一条风险。
    command -v nft >/dev/null 2>&1 || return 2
    local ruleset=""
    ruleset=$(nft list ruleset 2>/dev/null) || return 2
    [ -n "$ruleset" ] || return 0
    # v7: 在 awk 里直接解析 dport, 单端口、范围、集合都认。
    # 旧写法只取 dport 后第一个词, 集合 `dport { 18081, 18082 } dnat` 会取到 "{",
    # 后面的 DPORT 正则匹配不上, 集合里的端口一个都查不到。
    echo "$ruleset" | awk -v proto="$proto" -v want="$lport" -v nat_table="$NAT_TABLE" -v filter_table="$FILTER_TABLE" '
        function parse_range(s,   p, q) {
            if (index(s, "-") > 0) { split(s, p, "-"); return p[1] + 0 SUBSEP p[2] + 0 }
            return s + 0 SUBSEP s + 0
        }
        function overlaps(a1, a2, b1, b2) { return (a1 <= b2 && b1 <= a2) }
        BEGIN {
            if (index(want, "-") > 0) { split(want, w, "-"); w1 = w[1] + 0; w2 = w[2] + 0 }
            else { w1 = want + 0; w2 = want + 0 }
        }
        # v22: 表名原来用 index() 子串匹配, 另一张表叫 x-nft-forward-nat
        # 这种名字也会被当成自己的表、它的 DNAT 全漏掉。改成精确取表名比对。
        /^table / { table=$0; split($0, _tp, /[ \t{]+/); in_ours = (_tp[3] == nat_table || _tp[3] == filter_table); next }
        /dnat to/ {
            if (in_ours) next
            # v22: 没有 dport 的 DNAT (如 ip daddr X dnat to Y) 是全端口 DNAT,
            # 任何端口都可能被它抢走, 原来因没有 "tcp dport " 直接跳过、漏报。
            # 这种行直接报出来, 不按端口比对。
            if ($0 !~ / dport /) { print table " :: " $0 " (全端口 DNAT, 无 dport 限制)"; next }
            if ($0 !~ proto " dport ") next
            # 取 dport 后、dnat 前的那一段, 如 "18080"、"10000-10010"、
            # "{ 18081, 18082 }"、"{ 19000-19010 }"
            n = split($0, a, "dport ")
            if (n < 2) next
            spec = a[2]
            sub(/ dnat.*$/, "", spec)
            gsub(/[{}]/, " ", spec)
            gsub(/,/, " ", spec)
            # spec 里现在只剩若干个端口/范围, 逐个比对, 有一个重叠就报这一行
            m = split(spec, toks, /[ \t]+/)
            for (i = 1; i <= m; i++) {
                if (toks[i] == "") continue
                r = parse_range(toks[i])
                split(r, rr, SUBSEP)
                if (overlaps(w1, w2, rr[1], rr[2])) { print table " :: " $0; break }
            }
        }
    '
}

# 查 Docker 已发布的主机端口, 输出冲突的主机端口 (空表示无冲突)
docker_published_conflicts() {
    local lport="$1" proto="$2"
    command -v docker >/dev/null 2>&1 || return 0
    # v5: 之前是 `grep -oE ':[0-9]+->' | tr -d ':->'`, tr 会把 '-' 当成
    # ':' 到 '>' 的字符范围 (ASCII 58-62), 删不掉 '-', 主机端口变成 "8080-",
    # 后面的 ^[0-9]+$ 永远失败, Docker 检查从 v2 起就从没报过任何一次。
    # 现在直接取 "主机端口->容器端口/协议", 只报同协议的冲突
    # (Docker 只发布了 tcp 8080 时, 加 udp 8080 不应误报)。
    # v8: docker daemon 僵住时 docker ps 可能一直不返回, 加 5 秒超时, 超时按查不到处理。
    local _docker_out=""
    if command -v timeout >/dev/null 2>&1; then
        _docker_out=$(timeout 5 docker ps --format '{{.Ports}}' 2>/dev/null) \
            || { yellow "错误: Docker 查询失败或超时, 无法确认端口是否冲突" >&2; return 2; }
    else
        _docker_out=$(docker ps --format '{{.Ports}}' 2>/dev/null) \
            || { yellow "错误: Docker 查询失败, 无法确认端口是否冲突" >&2; return 2; }
    fi
    # v22: 正则原来只认单个端口 `:[0-9]+->`, Docker 发布端口段时
    # `0.0.0.0:10000-10010->10000-10010/tcp` 一行都匹配不上, 段里的端口
    # 全漏报, check 第 6 节会假放行。改成端口段也认, hp 的校验也放宽到段,
    # ports_overlap 本来就支持段 (v5), 直接复用。
    echo "$_docker_out" | grep -oE ':[0-9]+(-[0-9]+)?->[0-9]+(-[0-9]+)?/(tcp|udp)' | while IFS= read -r m; do
        local hp="${m#:}" pproto="${m##*/}"
        hp="${hp%%->*}"
        [[ "$hp" =~ ^[0-9]+(-[0-9]+)?$ ]] || continue
        [ "$proto" = "both" ] || [ "$proto" = "$pproto" ] || continue
        if ports_overlap "$lport" "$hp"; then
            echo "docker 已发布主机端口 $hp ($pproto)"
        fi
    done
    # v26: 必须显式 return 0。上面管道里 grep 找不到匹配时退出 1, 在
    # set -o pipefail 下整个函数会返回 1, v25 的 fail-closed 调用方会误以为
    # Docker 查询失败而拒绝添加——实测 v25 在 docker 正常、端口没被发布时
    # add 也会被拒, check 也误报风险。查询成功但无冲突就是 0; 真正查不了
    # (daemon 挂/超时) 时上面已经 return 2 了。
    return 0
}

# 端口冲突检查: ss 监听 + 其他表 DNAT + Docker 发布端口, 三项都查
# 有冲突: 交互时问是否继续, 非交互直接拒绝
check_port_conflict() {
    local lport="$1" proto="$2"
    local found="" dnat_conf="" docker_conf=""
    local protos=""
    case "$proto" in tcp) protos="tcp";; udp) protos="udp";; *) protos="tcp udp";; esac

    # 1) ss 监听
    if command -v ss >/dev/null 2>&1; then
        for p in $protos; do
            while IFS= read -r lp; do
                [[ "$lp" =~ ^[0-9]+$ ]] || continue
                if ports_overlap "$lport" "$lp"; then
                    found="$found $p:$lp"
                fi
            done < <(listening_ports "$p")
        done
    else
        yellow "提示: 未找到 ss, 跳过监听端口检查"
    fi
    # 2) 其他表的 DNAT (ss 看不到, 必须单独查)
    # v25: existing_dnat_conflicts 返回非 0 表示"查不了" (nft 缺失 / list 失败)。
    # 查不了就直接拒绝添加, 不假装查过。
    local _dnc_rc=0 _dc=""
    for p in $protos; do
        _dc=$(existing_dnat_conflicts "$lport" "$p") || _dnc_rc=$?
        [ "$_dnc_rc" -ne 0 ] && die "无法读取 nft 规则集, 查不到其他表的 DNAT 冲突, 拒绝添加 (请用 root 且有 NET_ADMIN 权限再试)"
        dnat_conf="$dnat_conf
$_dc"
    done
    dnat_conf=$(echo "$dnat_conf" | grep -v '^[[:space:]]*$' || true)
    # 3) Docker 发布端口
    if command -v docker >/dev/null 2>&1; then
        docker_conf=$(docker_published_conflicts "$lport" "$proto") \
            || die "无法确认 Docker 端口占用情况, 为避免误抢端口已拒绝添加"
        docker_conf=$(printf '%s\n' "$docker_conf" | sort -u)
    fi

    if [ -n "$found" ]; then
        yellow "警告: 本机端口已被监听占用:$found"
        for item in $found; do
            local pr="${item%%:*}" pt="${item##*:}"
            if [ "$pr" = "tcp" ]; then ss -tlnp 2>/dev/null | grep -E ":${pt}[[:space:]]" | head -2
            else ss -ulnp 2>/dev/null | grep -E ":${pt}[[:space:]]" | head -2; fi
        done
    fi
    if [ -n "$dnat_conf" ]; then
        yellow "警告: 其他表已有 DNAT 占用相同端口 (ss 看不到, 转发会抢走它的流量):"
        echo "$dnat_conf"
    fi
    if [ -n "$docker_conf" ]; then
        yellow "警告: Docker 已发布相同主机端口:"
        echo "$docker_conf"
    fi
    if [ -z "$found" ] && [ -z "$dnat_conf" ] && [ -z "$docker_conf" ]; then
        return 0
    fi
    yellow "继续转发会抢走上面服务的流量。"
    if [ ! -t 0 ]; then
        die "本机端口已被占用, 请先停掉该服务或换个端口再试 (交互终端里运行会提示是否继续)"
    fi
    local ans=""
    read -r -p "确认还要继续转发吗? [y/N] " ans || die "已取消"
    [[ "$ans" =~ ^[Yy]$ ]] || die "已取消"
}

# v3: install 时不再写 route_localnet, 只开 IPv4 ip_forward (v25 起不再碰 IPv6 转发)。
# route_localnet 只在 apply 时、且确实有规则转到 127.0.0.1 时才开。
enable_forwarding() {
    mkdir -p "$(dirname "$SYSCTL_FILE")"
    # 本脚本只生成 IPv4 DNAT 规则, 不应擅自改变 VPS 的 IPv6 路由行为。
    cat > "$SYSCTL_FILE" <<'EOF'
net.ipv4.ip_forward=1
EOF
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || die "开启 IPv4 转发失败"
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    green "已开启 IP 转发并持久化到 $SYSCTL_FILE"
}

build_nft_file() {
    local out="$1" with_delete="$2"
    : > "$out"
    if [ "$with_delete" = "yes" ]; then
        nft list table ip "$NAT_TABLE" >/dev/null 2>&1 && echo "delete table ip $NAT_TABLE" >> "$out"
        nft list table ip "$FILTER_TABLE" >/dev/null 2>&1 && echo "delete table ip $FILTER_TABLE" >> "$out"
    fi
    {
        echo "table ip $NAT_TABLE {"
        echo "  chain prerouting { type nat hook prerouting priority dstnat; policy accept;"
        if [ -f "$RULES_FILE" ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                line="${line%$'\r'}"  # v5: 去掉 Windows 换行 \r
                [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
                local proto lport tip tport
                read -r proto lport tip tport <<< "$line"
                lport=$(norm_port "$lport"); tport=$(norm_port "$tport")
                # v3 关键修复: fib daddr type local — 只有目的地址是本机 IP 的包才 DNAT。
                # 不加这一句, Docker 容器出站、Xray/mihomo 出站、WireGuard 对端经本机去外网
                # 的流量, 只要目的端口撞上, 都会被改写到转发目标, 代理就断了。
                echo "    fib daddr type local $proto dport $lport dnat to $tip:$tport"
            done < "$RULES_FILE"
        fi
        echo "  }"
        echo "  chain postrouting { type nat hook postrouting priority srcnat; policy accept;"
        if [ -f "$RULES_FILE" ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                line="${line%$'\r'}"  # v5: 去掉 Windows 换行 \r
                [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
                local proto lport tip tport
                read -r proto lport tip tport <<< "$line"
                lport=$(norm_port "$lport"); tport=$(norm_port "$tport")
                if [ "$tip" != "127.0.0.1" ]; then
                    # v3 关键修复: ct status dnat — 只有被 DNAT 过的连接才 masquerade。
                    # 不加这一句, 本机代理进程自己主动连同一个目标 IP:端口时, 源地址也会被改写。
                    echo "    ip daddr $tip $proto dport $tport ct status dnat masquerade"
                fi
            done < "$RULES_FILE"
        fi
        echo "  }"
        echo "}"
        echo "table ip $FILTER_TABLE {"
        echo "  chain forward { type filter hook forward priority filter; policy accept;"
        echo "    ct state established,related accept"
        if [ -f "$RULES_FILE" ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                line="${line%$'\r'}"  # v5: 去掉 Windows 换行 \r
                [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
                local proto lport tip tport
                read -r proto lport tip tport <<< "$line"
                lport=$(norm_port "$lport"); tport=$(norm_port "$tport")
                echo "    ip daddr $tip $proto dport $tport ct status dnat accept"
            done < "$RULES_FILE"
        fi
        echo "  }"
        echo "}"
    } >> "$out"
}

apply_rules() {
    acquire_lock
    check_nft
    validate_rules_file
    if [ -f "$RULES_FILE" ] && grep -q " 127\.0\.0\.1 " "$RULES_FILE" 2>/dev/null; then
        sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>&1 \
            || yellow "提示: route_localnet 开启失败, 转发到 127.0.0.1 可能不通"
    fi
    mkdir -p "$RULES_DIR"
    # v15: 清掉上次被杀 (Ctrl+C、断电、OOM) 时留在规则目录里的临时文件,
    # 锁保证了此刻没有别的 apply 在跑, 这些一定是死文件。
    rm -f "$RULES_DIR"/.nft-forward-persist.*.nft 2>/dev/null
    local persistent_tmp atomic_tmp count=0
    # v15: 持久化临时文件建在规则目录里 (和 rules.nft 同一文件系统), 这样
    # 最后一步能用 mv 原子替换, 见下面。
    persistent_tmp=$(mktemp "$RULES_DIR/.nft-forward-persist.XXXXXX.nft")
    atomic_tmp=$(mktemp /tmp/nft-forward-atomic.XXXXXX.nft)
    build_nft_file "$persistent_tmp" "no"
    build_nft_file "$atomic_tmp" "yes"
    if ! nft -f "$atomic_tmp" 2>/tmp/nft-forward.err; then
        red "nft 加载失败, 旧转发规则未动 (原子回滚):"
        cat /tmp/nft-forward.err >&2
        red "常见原因: 不是 root、或在容器/LXC 里没有 NET_ADMIN 权限。"
        red "在正常 VPS 上用 root 跑即可; 容器里需给 --cap-add=NET_ADMIN --privileged。"
        rm -f "$persistent_tmp" "$atomic_tmp"
        exit 1
    fi
    rm -f "$atomic_tmp"
    # v15: 持久化文件用同目录临时文件 + mv 原子替换, 不用 cp -f。cp 会先截断
    # 目标再写, 中途被杀 (Ctrl+C、断电、OOM) 会留下一个写了一半的 rules.nft,
    # 下次开机 nftables 加载 include 时失败, 连 nftables 服务都起不来。
    # mv 在同一文件系统内是原子重命名, 要么是旧文件、要么是新文件, 不会有半截。
    # v25: 持久化失败时退出码用 2 不用 die (die 是 1)。到这一步 nft 已经加载
    # 了新规则, 内核已是新状态; 调用方 (add/del/clear 的 apply_or_restore)
    # 收到 2 就知道不该把 rules.conf 恢复成旧的, 否则文件和内核反向不一致。
    # 1 = 加载/校验失败 (内核没动, 可以恢复), 2 = 已加载但持久化失败 (不恢复)。
    mv -f "$persistent_tmp" "$RULES_NFT" || { rm -f "$persistent_tmp"; red "错误: 持久化转发规则失败 (nft 已加载新规则, 但 rules.nft 未更新, 下次开机可能恢复旧规则, 请检查磁盘/权限后重跑 apply)"; exit 2; }
    [ -f "$RULES_FILE" ] && count=$(awk 'NF && $1 !~ /^#/ {c++} END{print c+0}' "$RULES_FILE" 2>/dev/null)
    green "已应用 $count 条转发规则 (原子加载, 失败自动回滚)"
}

# v4: 只有 nftables.service 本来就已启用、且 /etc/nftables.conf 里有 flush ruleset,
# 才往 /etc/nftables.conf 加 include。没有 flush 时, 重启加载会因表已存在而整个失败,
# 所以宁可不加, 只靠自己的服务开机恢复。
ensure_nftables_include() {
    [ -f "$NFTABLES_CONF" ] || {
        yellow "提示: 未找到 /etc/nftables.conf, 只靠 nft-forward 服务开机恢复 (nftables 重启后需手动 apply)"
        return 0
    }
    if ! has_systemd || ! systemctl is-enabled nftables.service >/dev/null 2>&1; then
        yellow "提示: nftables 服务本来就没启用, 不改 /etc/nftables.conf (只靠 nft-forward 服务开机恢复, 不激活默认防火墙)"
        return 0
    fi
    if ! grep -q "flush ruleset" "$NFTABLES_CONF" 2>/dev/null; then
        yellow "提示: /etc/nftables.conf 里没有 flush ruleset, 不加 include (否则重启加载时表已存在会失败), 只靠 nft-forward 服务开机恢复"
        return 0
    fi
    grep -q "nft-forward/rules.nft" "$NFTABLES_CONF" 2>/dev/null && return 0
    # v8: 每次 install 都刷新备份 (原来只在备份不存在时才建, 重装后备份会是
    # 旧文件的, 卸载时拿它对照末尾换行就错了)。
    cp -f "$NFTABLES_CONF" "$NFTABLES_CONF.bak.nft-forward"
    # v8: 先把文件末尾有没有换行读到变量里, 再打开文件追加, 不要在同一个
    # brace group 里一边读一边写同一个文件 (shellcheck SC2094)。
    local _last_byte=""
    _last_byte=$(tail -c1 "$NFTABLES_CONF" 2>/dev/null || true)
    {
        # 只在文件末尾没有换行时补一个换行, 不多加空行, 这样卸载时删掉下面两行
        # 就能把文件恢复成原样 (之前多加的空行会在卸载后留下一个孤儿空行)。
        # _last_byte 为空表示文件以换行结尾 (command substitution 会去掉末尾换行)
        # 或文件为空, 两种情况都不用补换行; 非空则表示末尾没有换行, 补一个。
        [ -n "$_last_byte" ] && echo ""
        echo "# nft-forward: 转发规则 (由 nft-forward.sh 管理, 卸载时自动删除此行)"
        echo "include \"$RULES_NFT\""
    } >> "$NFTABLES_CONF"
    green "已在 $NFTABLES_CONF 追加 include, nftables 重启后转发规则仍在 (原文件备份在 .bak.nft-forward)"
}

# 上线前检查: 列出所有可能和转发撞车的代理/服务, 并逐条比对现有转发规则
cmd_check() {
    echo "=== 1) 本机监听端口 (ss) ==="
    echo "--- TCP ---"
    ss -tlnp 2>/dev/null || echo "(ss 不可用或无监听)"
    echo "--- UDP ---"
    ss -ulnp 2>/dev/null || echo "(ss 不可用或无监听)"
    echo
    echo "=== 2) 其他表的 DNAT 规则 (本表除外) ==="
    if command -v nft >/dev/null 2>&1; then
        # v4: 先判 nft list 是否成功, 失败就明确说无法检查, 不再用空结果假装无冲突
        local _ruleset=""
        if _ruleset=$(nft list ruleset 2>/tmp/nft-forward-check.err); then
            # 只认真正的 DNAT 行 (含 "dnat to"), 排除 "ct status dnat masquerade/accept";
            # 按表名排除本表 (nat+filter), 不能只 grep -v nft-forward, 因为 DNAT 行
            # 本身不含表名, 那样会把本表的 DNAT 也当成其他表的。
            # v22: 表名精确匹配, 见 existing_dnat_conflicts 里的说明。
            echo "$_ruleset" | awk -v nat_table="$NAT_TABLE" -v filter_table="$FILTER_TABLE" '
                /^table / { split($0, _tp, /[ \t{]+/); in_ours = (_tp[3] == nat_table || _tp[3] == filter_table); next }
                /dnat to/ && !in_ours { print; found=1 }
                END { if (!found) print "(无其他 DNAT)" }
            '
        else
            red "(nft list 失败, 无法检查其他 DNAT, 请用 root 且有 NET_ADMIN 权限再跑; 报错见 /tmp/nft-forward-check.err)"
        fi
        echo "--- 本表的 DNAT (应只有下面这些, 且都带 fib daddr type local) ---"
        nft list table ip "$NAT_TABLE" 2>/dev/null | grep -i "dnat to" || echo "(本表未创建或无规则)"
    else
        echo "(未安装 nft)"
    fi
    echo
    echo "=== 3) Docker 已发布端口 ==="
    if command -v docker >/dev/null 2>&1; then
        # v8: 同样加 5 秒超时, 防止 docker daemon 僵住时 check 一直等。
        if command -v timeout >/dev/null 2>&1; then
            timeout 5 docker ps --format 'table {{.Names}}\t{{.Ports}}' 2>/dev/null || echo "(docker ps 失败或超时)"
        else
            docker ps --format 'table {{.Names}}\t{{.Ports}}' 2>/dev/null || echo "(docker ps 失败)"
        fi
    else
        echo "(未安装 docker)"
    fi
    echo
    echo "=== 4) 代理相关服务状态 ==="
    if has_systemd; then
        systemctl list-units --type=service --no-pager 2>/dev/null \
            | grep -i -E 'xray|sing-box|mihomo|clash|warp|wgcf|wireguard|docker|nginx|flvx|miaomiao' \
            || echo "(未发现相关 systemd 服务, 或服务名不在上述关键词里)"
    else
        echo "(本机没有 systemd)"
        # v22: 原来这支的关键词比 systemd 分支少了 flvx|miaomiao|wireguard|wgcf,
        # 没 systemd 的机器上这几个代理的进程查不到。对齐两支的关键词。
        ps aux 2>/dev/null | grep -i -E 'xray|sing-box|mihomo|clash|warp|wgcf|wireguard|docker|nginx|flvx|miaomiao' | grep -v grep || echo "(进程里未发现相关代理)"
    fi
    echo
    echo "=== 5) 本机 IP (fib daddr type local 只匹配这些地址) ==="
    # v16: ip 缺失时 (精简系统), 上面这行整个返回非零, 在 set -e 下 check 会
    # 在第 5 节直接退出、后面的碰撞检查都不跑。先查有没有 ip, 没有就明说。
    if command -v ip >/dev/null 2>&1; then
        ip -brief addr 2>/dev/null || ip addr 2>/dev/null | grep -E 'inet ' || true
    else
        echo "(本机没有 ip 命令, 查不到本机 IP; fib 规则需要本机 IP 在网卡上, 请用 hostname -I 或 ip addr 手动确认)"
    fi
    echo
    echo "=== 6) 现有转发规则与上面各项的碰撞检查 ==="
    if [ ! -f "$RULES_FILE" ] || [ ! -s "$RULES_FILE" ]; then
        echo "(还没有任何转发规则)"
        return 0
    fi
    local bad=0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"  # v5: 去掉 Windows 换行 \r
        [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
        local proto lport tip tport
        read -r proto lport tip tport <<< "$line"
        echo "检查: $proto $lport -> $tip:$tport"
        # v12: 先校验规则本身是否合法, 再查碰撞。之前不校验, 手写了 sctp、
        # 缺字段等非法规则时 check 也会报 "OK, 未发现碰撞"、结论说"可以继续",
        # 但 apply 根本加载不了这条规则, 属于假放行。validate_rule 失败时会
        # die, 放在子 shell 里跑, 失败就记一笔 bad、跳到下一条, 不让 check 退出。
        if [ -z "${proto:-}" ] || [ -z "${lport:-}" ] || [ -z "${tip:-}" ] || [ -z "${tport:-}" ]; then
            red "  !! 规则非法: 这一行缺字段 (应为: 协议 本机端口 目标IP 目标端口)"
            bad=$((bad + 1))
            continue
        fi
        local _verr_file="/tmp/nft-forward-validate.err"
        if ! ( validate_rule "$proto" "$lport" "$tip" "$tport" ) 2>"$_verr_file"; then
            # die 的报错自带红色和 "错误: " 前缀, 先去掉颜色码和前缀, 再由外层 red 包一次,
            # 否则会出现双重颜色码。
            local _msg=""
            _msg=$(cat "$_verr_file" 2>/dev/null | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^错误: //')
            red "  !! $_msg"
            bad=$((bad + 1))
            continue
        fi
        # 用 check 的逻辑, 但只报不问 (非交互也适用): 临时把 stdin 关掉会让它直接拒绝,
        # 所以这里只做只读比对, 不调用会交互的 check_port_conflict
        local hit="" _dnc_failed=0
        for p in tcp udp; do
            [ "$proto" = "both" ] || [ "$proto" = "$p" ] || continue
            while IFS= read -r lp; do
                [[ "$lp" =~ ^[0-9]+$ ]] || continue
                ports_overlap "$lport" "$lp" && hit="$hit $p 监听端口 $lp"
            done < <(listening_ports "$p")
            local dc="" _dnc_rc=0
            # v25: 返回非 0 表示"查不了" (nft 缺失 / list 失败), 不是"没有冲突"。
            # 计一条风险, 不报 "OK, 未发现碰撞"。
            dc=$(existing_dnat_conflicts "$lport" "$p") || _dnc_rc=$?
            if [ "$_dnc_rc" -ne 0 ]; then
                # 同一条规则两个协议都查不了时只记一次
                [ "$_dnc_failed" -eq 0 ] && hit="$hit | 其他表 DNAT 查不了 (nft list 失败)"
                _dnc_failed=1
            elif [ -n "$dc" ]; then
                hit="$hit | 其他表 DNAT: $dc"
            fi
        done
        local dkc="" _docker_rc=0
        if command -v docker >/dev/null 2>&1; then
            dkc=$(docker_published_conflicts "$lport" "$proto") || _docker_rc=$?
            if [ "$_docker_rc" -ne 0 ]; then
                hit="$hit | Docker 端口查询失败/超时, 无法排除冲突"
            elif [ -n "$dkc" ]; then
                hit="$hit | $dkc"
            fi
        fi
        if [ -n "$hit" ]; then
            red "  !! 碰撞:$hit"
            bad=$((bad + 1))
        else
            green "  OK, 未发现碰撞"
        fi
    done < "$RULES_FILE"
    echo
    if [ "$bad" -gt 0 ]; then
        red "结论: 有 $bad 条规则存在碰撞风险, 先处理上面标 !! 的再上线, 否则对应代理可能失效。"
        # v18: 发现问题时返回 1 (原来永远返回 0, 自动化里 check && install 会
        # 误以为没问题就继续装)。人看输出不受影响, 菜单第 8 项已用 || true 接住,
        # 不会因此闪退。
        return 1
    else
        green "结论: 现有规则未发现与监听端口 / 其他 DNAT / Docker 发布端口的碰撞, 可以继续。"
        echo "注意: 这只能查到当前正在运行的服务。还没启动的代理 (如之后才启动的 Xray inbound / Docker 容器)"
        echo "查不到, 加新规则前请先确认那个端口以后也不会被代理占用。"
    fi
}

# v25: add/del/clear 的共用收尾: 先改 rules.conf 再 apply, apply 失败时把
# 规则文件恢复到修改前。原来只备份不恢复, rules.conf 会和内核实际状态不一致:
# add 失败后文件里有规则、内核里没有; del/clear 失败后文件里没了、内核里还在。
# apply 在子 shell 里跑, 它里面的 exit/die 只杀子 shell, 父进程才能在失败后
# 恢复。退出码 1 = 加载/校验失败 (内核没动, 恢复); 退出码 2 = nft 已加载但
# 持久化失败 (内核已是新规则, 不恢复, 只报错)。
apply_or_restore() {
    local _rc=0
    ( apply_rules ) || _rc=$?
    if [ "$_rc" -eq 1 ]; then
        if cp -f "$RULES_FILE.bak" "$RULES_FILE" 2>/dev/null; then
            die "转发应用失败, 规则文件已恢复到修改前 (备份在 $RULES_FILE.bak)"
        else
            die "转发应用失败, 且规则文件恢复失败 (备份在 $RULES_FILE.bak, 请手动恢复)"
        fi
    elif [ "$_rc" -ne 0 ]; then
        die "转发应用失败, 规则文件未动, 请检查上面报错后重跑 apply"
    fi
}

cmd_install() {
    need_root
    acquire_lock
    check_nft
    enable_forwarding
    mkdir -p "$RULES_DIR"
    touch "$RULES_FILE"
    # v16: readlink 缺失时 (busybox) 直接用会报 "readlink: command not found"
    # (报错虽不致命, 但会吓人; 且 $( ) 为空时比较恒为真, 本来就该复制)。
    # 先查有没有, 没有就直接用 $0 比较, 反正结果一样是复制。
    local _self="$0"
    if command -v readlink >/dev/null 2>&1; then
        _self=$(readlink -f "$0" 2>/dev/null || echo "$0")
    fi
    if [ "$_self" != "$SCRIPT_PATH" ]; then
        cp "$0" "$SCRIPT_PATH"
        # v16: 用 755 而不是只加 +x。源文件可能是 770, cp 过来还是 770, 非 root
        # 跑 list/check/status 时会直接 "Permission denied", 连脚本自己的
        # "请用 root 运行" 都看不到。755 让只读命令对所有人可用, 写命令仍由
        # need_root 挡。
        chmod 755 "$SCRIPT_PATH"
        green "已安装到 $SCRIPT_PATH"
    fi
    ln -sf "$SCRIPT_PATH" "$SHORTCUT_PATH"
    ln -sf "$SCRIPT_PATH" "$SHORTCUT_PATH2"
    chmod 755 "$SCRIPT_PATH"
    green "快捷命令已创建: nft-forward  /  zf"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=nftables port forwarding (nft-forward)
# v17: 加 After=nftables.service (只有顺序, 没有 Wants/Requires, 不会把
# 一个本来没启用的 nftables.service 拉起来)。开机时如果 nftables.service
# 也跑 (它的 conf 里有 flush ruleset), 它会清空全部表; 没有这一行,
# 两个服务谁先谁后不一定, nft-forward.service 先跑的话, 表建好后又被
# nftables 的 flush 清掉, 转发就断了, 要手动 apply 才恢复。加了这一行,
# nftables.service 先 flush, nft-forward.service 再 apply 重建, 顺序固定。
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    if has_systemd; then
        systemctl daemon-reload 2>/dev/null || true
        # v4: 只 enable, 不用 --now。--now 会立即启动服务, 服务里的 apply 也要拿同一把
        # flock 锁, 而 install 进程正持有这把锁, 服务会直接报锁冲突失败。
        # 立即生效靠下面直接调的 apply_rules, 不靠服务启动。
        systemctl enable nft-forward.service 2>/dev/null \
            || yellow "提示: nft-forward 开机自启注册失败, 重启后需手动跑 nft-forward apply"
        # v3/v4: 不再 enable nftables.service, 不激活 dormant 的默认防火墙
    else
        yellow "提示: 本机没有 systemd, 开机自启未注册, 重启后请手动跑 nft-forward apply"
    fi
    apply_rules
    ensure_nftables_include
    green "安装完成 ($SCRIPT_VERSION)。开机自动恢复转发规则。"
    echo "安装后请先跑一次上线前检查, 确认代理没受影响:"
    echo "  nft-forward check"
    echo "以后在任意目录输入以下任一命令即可呼出菜单:"
    echo "  nft-forward    或    zf"
}

cmd_add() {
    need_root
    acquire_lock
    check_nft
    # v6: 多余参数直接报错, 不能静默丢掉 (之前 `add ... tcp extra` 会成功并丢掉 extra)
    [ -n "${5:-}" ] && die "参数过多: add 只接受 4 个参数, 多余的是: $5"
    local lport="${1:-}" tip="${2:-}" tport="${3:-}" proto="${4:-both}"
    if [[ "$tport" =~ ^(tcp|udp|both)$ ]]; then proto="$tport"; tport=""; fi
    if [ -z "$lport" ] || [ -z "$tip" ]; then
        echo "用法: $0 add <本机端口> <目标IP或域名> [目标端口] [tcp|udp|both]"
        echo "示例: $0 add 8080 1.2.3.4 80 tcp"
        echo "示例: $0 add 8080 example.com 80   # 域名添加时解析一次, 存解析到的 IP"
        echo "示例: $0 add 51820 1.2.3.4        # 目标端口同本机端口, 默认 tcp+udp"
        echo "示例: $0 add 10000-10010 1.2.3.4  # 端口段转发"
        exit 1
    fi
    valid_port "$lport" || die "本机端口不合法: $lport (1-65535, 或范围如 10000-10010)"
    # v27: 目标可以是域名。resolve_target 已经是 IP 就原样返回, 是域名就
    # 解析一次返回 IP; 失败时分两种报错 (2 = 本机没解析工具, 1 = 解析不到)。
    # 注意: 先用 _resolved 接住, 不能直接 tip=$(...) 再用 $tip 报错——
    # 解析失败时命令替换会把 tip 清空, 报错里就看不到用户填了什么。
    local _resolved="" _resolve_rc=0
    _resolved=$(resolve_target "$tip") || _resolve_rc=$?
    if [ "$_resolve_rc" -eq 2 ]; then
        die "无法解析域名 $tip: 本机没有可用的 DNS 解析工具 (getent/nslookup/dig/host/python3 都没有), 请直接填目标 IP"
    elif [ "$_resolve_rc" -ne 0 ]; then
        die "目标不合法: $tip (不是合法 IPv4, 域名也解析不到 IPv4 地址; 只支持 IPv4, 不支持 IPv6)"
    fi
    if [ "$_resolved" != "$tip" ]; then
        green "域名 $tip 解析到 $_resolved, 已按 IP 添加 (域名 IP 变化后需删除重加)"
        tip="$_resolved"
    fi
    case "$tip" in
        0.0.0.0|255.255.255.255|0.*) die "目标 IP 不能是 $tip (无效/广播地址)" ;;
    esac
    [ -z "$tport" ] && tport="$lport"
    # v5: 删掉了原来的静默覆盖 `if lport 是段且 tport 是单个, tport=lport`。
    # 那段会把用户显式填的 `add 10000-10010 1.2.3.4 80` 悄悄改成 10000-10010,
    # 用户填的 80 不声不响就没了。现在显式填单个 80 时, 下面的长度校验会
    # 直接报错, 告诉用户段只能转同样数量的段; 不填目标端口时仍默认 1:1。
    valid_port "$tport" || die "目标端口不合法: $tport"
    case "$proto" in tcp|udp|both) ;; *) die "协议只能是 tcp / udp / both, 你填的是: $proto";; esac
    local llen tlen
    llen=$(port_len "$lport"); tlen=$(port_len "$tport")
    [ "$llen" -eq "$tlen" ] || die "本机端口段有 $llen 个端口, 目标端口段有 $tlen 个, 数量必须一致"
    # v5: 归一化前导零, 010-020 写进 rules.conf 时变成 10-20, 不留八进制隐患
    lport=$(norm_port "$lport"); tport=$(norm_port "$tport")

    if [ "$lport" = "22" ]; then
        yellow "警告: 你要转发 22 端口, 转发后本机 SSH 可能无法直连, 确认无误再继续。"
        # v20: 非交互时 stdin 可能是永远不 EOF 的管道, 裸 read 会一直挂起。
        # ss 冲突提示 (check_port_conflicts) 早有 [ ! -t 0 ] 守卫, 这里补上同样守卫,
        # 非交互直接报错退出, 不挂起。
        if [ ! -t 0 ]; then
            die "转发 22 需要交互确认, 请在终端里运行"
        fi
        read -r -p "确认转发 22 吗? [y/N] " ans || die "已取消"
        [[ "$ans" =~ ^[Yy]$ ]] || die "已取消"
        # v5: 之前 22 直接跳过全部冲突检查, 其他表 DNAT / Docker 占了 22 也查不到。
        # 现在仍查 DNAT 和 Docker, 有冲突直接拒绝; 只跳过 ss 监听检查
        # (sshd 本来就占着 22, 那是预期内的, 不应再报一次)。
        local _dnat_conf="" _docker_conf=""
        # v25: 同 check_port_conflict, existing_dnat_conflicts 返回非 0 表示
        # "查不了", 拒绝添加, 不假装查过。
        local _dnc_rc=0 _dc=""
        for _p in tcp udp; do
            [ "$proto" = "both" ] || [ "$proto" = "$_p" ] || continue
            _dc=$(existing_dnat_conflicts "$lport" "$_p") || _dnc_rc=$?
            [ "$_dnc_rc" -ne 0 ] && die "无法读取 nft 规则集, 查不到其他表的 DNAT 冲突, 拒绝添加 (请用 root 且有 NET_ADMIN 权限再试)"
            _dnat_conf="$_dnat_conf
$_dc"
        done
        _dnat_conf=$(echo "$_dnat_conf" | grep -v '^[[:space:]]*$' || true)
        if command -v docker >/dev/null 2>&1; then
            _docker_conf=$(docker_published_conflicts "$lport" "$proto") \
                || die "无法确认 Docker 端口占用情况, 为避免误抢 22 端口已拒绝添加"
            _docker_conf=$(printf '%s\n' "$_docker_conf" | sort -u)
        fi
        [ -n "$_dnat_conf" ] && die "其他表已有 DNAT 占用 22 端口, 拒绝转发: $_dnat_conf"
        [ -n "$_docker_conf" ] && die "Docker 已发布 22 端口, 拒绝转发: $_docker_conf"
    else
        check_port_conflict "$lport" "$proto"
    fi

    mkdir -p "$RULES_DIR"
    touch "$RULES_FILE"
    backup_rules
    if [ "$proto" = "both" ]; then
        sed -i "/^[[:space:]]*tcp $lport /d; /^[[:space:]]*udp $lport /d" "$RULES_FILE"
        echo "tcp $lport $tip $tport" >> "$RULES_FILE"
        echo "udp $lport $tip $tport" >> "$RULES_FILE"
    else
        sed -i "/^[[:space:]]*$proto $lport /d" "$RULES_FILE"
        echo "$proto $lport $tip $tport" >> "$RULES_FILE"
    fi
    apply_or_restore
    green "已添加: 本机 $lport ($proto) -> $tip:$tport"
    echo "加完请跑一次检查确认代理没受影响: nft-forward check"
    echo "验证转发本身: curl -v telnet://127.0.0.1:$lport (单端口时)"
}

cmd_del() {
    need_root
    acquire_lock
    # v6: 多余参数直接报错
    [ -n "${3:-}" ] && die "参数过多: del 只接受 2 个参数, 多余的是: $3"
    local lport="${1:-}" proto="${2:-both}"
    [ -n "$lport" ] || { echo "用法: $0 del <本机端口> [tcp|udp|both]"; exit 1; }
    # 必须先校验再拼入 grep/sed 正则, 否则 .*、[0-9]+ 等输入会变成正则表达式。
    valid_port "$lport" || die "本机端口不合法: $lport (1-65535, 或范围如 10000-10010)"
    lport=$(norm_port "$lport")
    [ -f "$RULES_FILE" ] || die "还没有任何规则"
    case "$proto" in tcp|udp|both) ;; *) die "协议只能是 tcp / udp / both";; esac
    # v6: 先查规则在不在, 不在就直接报错, 不备份、不 apply、不谎报"已删除"
    # (之前 del 不存在的端口也会 exit 0 并绿字"已删除")。匹配允许行首空白。
    local _found=0
    if [ "$proto" = "both" ]; then
        grep -qE "^[[:space:]]*(tcp|udp) $lport " "$RULES_FILE" 2>/dev/null && _found=1
    else
        grep -qE "^[[:space:]]*$proto $lport " "$RULES_FILE" 2>/dev/null && _found=1
    fi
    [ "$_found" = "1" ] || die "没有这条规则: 本机端口 $lport ($proto) 不在规则文件里, 没删任何东西"
    backup_rules
    if [ "$proto" = "both" ]; then
        sed -i "/^[[:space:]]*tcp $lport /d; /^[[:space:]]*udp $lport /d" "$RULES_FILE"
    else
        sed -i "/^[[:space:]]*$proto $lport /d" "$RULES_FILE"
    fi
    apply_or_restore
    green "已删除本机端口 $lport ($proto) 的转发 (旧规则备份在 $RULES_FILE.bak)"
}

cmd_list() {
    echo "=== 规则文件 $RULES_FILE ==="
    if [ -f "$RULES_FILE" ] && [ -s "$RULES_FILE" ]; then
        printf "%-6s %-15s %-15s %-10s\n" "协议" "本机端口" "目标IP" "目标端口"
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%$'\r'}"  # v5: 去掉 Windows 换行 \r
            [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
            # v21: 行里字段不是 4 个时 (手写多字段/少字段), 原来的
            # printf "%-6s ..." $line 会把多余字段当成新一行印出来,
            # 出一行 "额外字段" 这种垃圾。字段不对就原样印出来并标注,
            # apply 本来就会拒绝这种行, list 不应把它印成像真规则。
            # 注意: 字段数不能用 wc -w 数——C locale 下 wc -w 会把
            # "额外字段" 这类非 ASCII 字段数成 0 个词, 5 字段的行会被
            # 误判成 4 字段, 垃圾行照样印出来 (实测)。用 read -ra 数数组,
            # 与 locale 无关; 顺带把 $line 换成数组展开, 避免字段里的
            # * 被当成通配符展开。
            local -a _fields=()
            read -ra _fields <<< "$line"
            if [ "${#_fields[@]}" -eq 4 ]; then
                printf "%-6s %-15s %-15s %-10s\n" "${_fields[@]}"
            else
                echo "(!) 格式不对, apply 会拒绝这行: $line"
            fi
        done < "$RULES_FILE"
    else
        echo "(无规则)"
    fi
    echo
    echo "=== 实时 nft 规则 (ip $NAT_TABLE / $FILTER_TABLE) ==="
    # v21: nat 表没了但规则文件里还有规则时 (比如 nftables restart 把表清了),
    # 原来的提示 "先跑 install 或 add" 是错的——规则都在文件里, 该跑的是 apply。
    # 没规则时才是 install/add。filter 表没了原来静默 (|| true), 现在也明说。
    if nft list table ip "$NAT_TABLE" 2>/dev/null; then
        :
    elif [ -s "$RULES_FILE" ]; then
        echo "(nat 表未创建, 但规则文件里还有规则, 跑 nft-forward apply 恢复)"
    else
        echo "(nat 表未创建, 先跑 install 或 add)"
    fi
    nft list table ip "$FILTER_TABLE" 2>/dev/null || echo "(filter 表未创建, 跑 nft-forward apply 恢复)"
    echo
    echo "=== 持久化 ==="
    [ -f "$RULES_NFT" ] && echo "规则 nft 文件: $RULES_NFT (已生成)" || echo "规则 nft 文件: 未生成"
    if [ -f "$NFTABLES_CONF" ]; then
        grep -q "nft-forward/rules.nft" "$NFTABLES_CONF" 2>/dev/null \
            && echo "/etc/nftables.conf: 已 include, nftables 重启不丢规则" \
            || echo "/etc/nftables.conf: 未 include (只有 nftables 服务本来就启用时才加, 开机自启不受影响)"
    else
        # v21: conf 不存在时原来这节静默少一行, 像输出断了。明说不存在。
        echo "/etc/nftables.conf: 不存在 (nftables 未配置, 开机自启不受影响)"
    fi
}

cmd_status() {
    echo "--- IP 转发开关 ---"
    # v14: 原来 sysctl 一次查两个键, 第二个键报错时整个命令返回非零,
    # 触发 || cat /proc/sys/net/ipv4/ip_forward, 只打印一个没标签的 0/1,
    # 用户不知道这个数字是哪个开关。改成逐个查、逐个标, 查不到就写 "?",
    # 两个开关的状态永远看得明白。
    local _ipf _rln
    _ipf=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "?")
    _rln=$(sysctl -n net.ipv4.conf.all.route_localnet 2>/dev/null || cat /proc/sys/net/ipv4/conf/all/route_localnet 2>/dev/null || echo "?")
    echo "net.ipv4.ip_forward = $_ipf"
    echo "net.ipv4.conf.all.route_localnet = $_rln"
    echo
    echo "--- nftables 服务 ---"
    if has_systemd; then
        # v9: is-enabled 不加 --quiet 时会在 stdout 打印光秃秃的 enabled/disabled,
        # 2>/dev/null 挡不住, status 里就多一行没标签的字。--quiet 只返回退出码。
        if systemctl is-enabled --quiet nftables.service 2>/dev/null; then
            echo "nftables 服务: 已启用"
        else
            echo "nftables 服务: 未启用 (不主动启用, 正常)"
        fi
        if systemctl is-enabled --quiet nft-forward.service 2>/dev/null; then
            echo "nft-forward 服务: 已启用 (开机自启)"
        elif [ -f "$SERVICE_FILE" ]; then
            # v21: 服务文件存在但被 disable 时说 "未安装" 是错的,
            # 它明明装了, 只是没启用。分开说, 否则用户会以为要重装。
            echo "nft-forward 服务: 已安装但未启用 (跑 install 或 systemctl enable nft-forward 重新启用)"
        else
            echo "nft-forward 服务: 未安装 (跑 install 开启开机自启)"
        fi
    else
        echo "本机没有 systemd, 开机自启未注册"
    fi
    echo
    cmd_list
}

cmd_clear() {
    need_root
    acquire_lock
    # v20: 同上, 非交互直接报错退出, 不在 read 上挂起。
    if [ ! -t 0 ]; then
        die "清空规则需要交互确认, 请在终端里运行"
    fi
    read -r -p "确认清空全部转发规则吗? [y/N] " ans || die "已取消"
    [[ "$ans" =~ ^[Yy]$ ]] || die "已取消"
    mkdir -p "$RULES_DIR"
    [ -f "$RULES_FILE" ] || : > "$RULES_FILE"
    backup_rules
    : > "$RULES_FILE"
    apply_or_restore
    green "已清空全部转发规则 (旧规则备份在 $RULES_FILE.bak)"
}

cmd_uninstall() {
    need_root
    # v5: 先加锁, 否则可能和正在跑的 apply/add 并发删表/删规则文件。
    acquire_lock
    # v20: 同上, 非交互直接报错退出, 不在 read 上挂起。
    if [ ! -t 0 ]; then
        die "卸载需要交互确认, 请在终端里运行"
    fi
    read -r -p "确认卸载吗? 会删除转发规则、systemd 服务和 sysctl 配置 [y/N] " ans || die "已取消"
    [[ "$ans" =~ ^[Yy]$ ]] || die "已取消"
    if has_systemd; then
        systemctl disable --now nft-forward.service 2>/dev/null || true
    fi
    if [ -f "$NFTABLES_CONF" ]; then
        sed -i '/nft-forward\/rules.nft/d; /nft-forward: 转发规则/d' "$NFTABLES_CONF" 2>/dev/null || true
        # v8: 原文件末尾如果没有换行, install 时补的那个换行会留下来, 卸载后
        # 文件就多了一个末尾换行, 恢复不成原样。备份文件是安装前的原样,
        # 以它为准: 备份末尾没换行、当前文件末尾有换行时, 去掉末尾一个换行。
        if [ -f "$NFTABLES_CONF.bak.nft-forward" ] && [ -s "$NFTABLES_CONF" ]; then
            local _bak_last="" _cur_last=""
            _bak_last=$(tail -c1 "$NFTABLES_CONF.bak.nft-forward" 2>/dev/null || true)
            _cur_last=$(tail -c1 "$NFTABLES_CONF" 2>/dev/null || true)
            # command substitution 会去掉末尾换行, 所以 _bak_last 非空 = 备份末尾没换行,
            # _cur_last 为空 = 当前文件末尾有换行 (或文件为空, 但上面已判 -s, 不为空)。
            if [ -n "$_bak_last" ] && [ -z "$_cur_last" ]; then
                truncate -s -1 "$NFTABLES_CONF" 2>/dev/null || true
            fi
        fi
    fi
    # v19: 卸载也要删掉 /etc/nftables.conf.bak.nft-forward (install 时建的备份)。
    # 之前卸载只删了 include 行、没删这个备份, 每次装卸循环都会留下一个。
    # 注意: 它在上面换行恢复逻辑里还用着, 所以只能在这里、逻辑跑完后再删。
    # 锁文件 /run/nft-forward.lock 不删 (锁文件惯例: 删了反而会让等锁的进程
    # 和新进程锁到不同的 inode, /run 是 tmpfs、重启就清了, 留着无害)。
    rm -f "$SERVICE_FILE" "$SYSCTL_FILE" "$SHORTCUT_PATH" "$SHORTCUT_PATH2" "$NFTABLES_CONF.bak.nft-forward"
    nft delete table ip "$NAT_TABLE" 2>/dev/null || true
    nft delete table ip "$FILTER_TABLE" 2>/dev/null || true
    rm -rf "$RULES_DIR"
    if has_systemd; then
        systemctl daemon-reload 2>/dev/null || true
    fi
    green "已卸载 (ip_forward 开关已随 sysctl 文件删除, 重启后恢复默认; 快捷命令已删除)"
    echo "脚本本体将在 1 秒后由后台进程删除, 不影响本次输出。"
    # v5: 先关掉锁 fd, 否则后台删脚本的进程会继承锁 fd, 锁住 1 秒。
    exec 9>&- || true
    ( sleep 1; rm -f "$SCRIPT_PATH" ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

pause() { read -r -p "按回车返回菜单..." _ || true; }

choose_proto() {
    echo "协议: 1) TCP  2) UDP  3) TCP+UDP (默认)" >&2
    local c=""
    read -r -p "选 [1/2/3, 默认 3]: " c || true
    case "$c" in
        1) echo "tcp" ;;
        2) echo "udp" ;;
        *) echo "both" ;;
    esac
}

menu_add() {
    local lport="" tip="" tport="" proto=""
    echo "--- 添加转发规则 ---"
    # v23: EOF 时裸 return 返回的是 read 的退出码 1, 在 set -e 下会直接
    # 杀掉整个菜单 (实测: 选 1 后按 Ctrl-D, 脚本 exit 1, 没有任何提示)。
    # 本来想写的是 "取消这次添加、回菜单", 所以必须 return 0。
    read -r -p "本机端口 (如 8080, 或范围 10000-10010): " lport || return 0
    read -r -p "目标 IP 或域名 (如 1.2.3.4 或 example.com): " tip || return 0
    read -r -p "目标端口 (回车 = 跟本机端口一样): " tport || return 0
    proto="$(choose_proto)"
    echo
    ( cmd_add "$lport" "$tip" "$tport" "$proto" ) || red "添加失败, 看上面报错再试一次"
    echo
    pause
}

menu_del() {
    local lport="" proto=""
    echo "--- 删除转发规则 ---"
    cmd_list
    echo
    # v23: 同上, EOF 时 return 0 回菜单, 不让 set -e 杀掉脚本。
    read -r -p "要删的本机端口 (如 8080): " lport || return 0
    [ -n "$lport" ] || { echo "端口为空, 已取消"; pause; return; }
    proto="$(choose_proto)"
    ( cmd_del "$lport" "$proto" ) || red "删除失败, 看上面报错"
    echo
    pause
}

cmd_menu() {
    if [ ! -t 0 ]; then
        cmd_help
        echo
        yellow "提示: 菜单需要交互终端, 请在 SSH 终端里运行 nft-forward, 命令行用法见上面帮助。"
        exit 1
    fi
    need_root
    if [ ! -f "$SERVICE_FILE" ] || [ ! -f "$SCRIPT_PATH" ]; then
        yellow "还没安装 (未创建开机自启服务和快捷命令)。"
        local ans=""
        read -r -p "现在一键安装吗? [Y/n] " ans || { echo "已取消"; exit 0; }
        if [[ ! "$ans" =~ ^[Nn]$ ]]; then
            ( cmd_install ) || die "安装失败, 看上面报错"
            echo
            pause
        fi
    fi
    while true; do
        clear 2>/dev/null || true
        local count=0
        # v23: 原来数的是 "非空非注释行", 手写多字段/少字段/乱写的行也被数进去
        # (实测: 1 条真规则 + garbage + 缺字段行, 菜单显示 "当前规则: 3 条")。
        # 改成只数 4 字段且协议是 tcp/udp/both 的行, 和 list 的显示口径一致。
        [ -f "$RULES_FILE" ] && count=$(awk 'NF==4 && $1 ~ /^(tcp|udp|both)$/ {c++} END{print c+0}' "$RULES_FILE" 2>/dev/null)
        echo "=================================="
        echo "  nftables 端口转发 $SCRIPT_VERSION  (nft-forward / zf)"
        echo "=================================="
        echo "  当前规则: $count 条   配置: $RULES_FILE"
        echo "----------------------------------"
        echo "  1) 添加转发规则"
        echo "  2) 删除转发规则"
        echo "  3) 查看转发规则"
        echo "  4) 查看状态 (转发开关 + 服务 + 规则)"
        echo "  5) 重新应用规则 (改完配置/重启后用)"
        echo "  6) 清空全部规则"
        echo "  7) 卸载"
        echo "  8) 上线前检查 (代理是否会受影响)"
        echo "  0) 退出"
        echo "=================================="
        local choice=""
        read -r -p "请输入数字 [0-8]: " choice || { echo "输入结束, 退出"; exit 0; }
        case "$choice" in
            1) menu_add ;;
            2) menu_del ;;
            3) cmd_list; echo; pause ;;
            4) cmd_status; echo; pause ;;
            5) ( apply_rules ) || red "应用失败, 看上面报错"; echo; pause ;;
            6) ( cmd_clear ) || echo "已取消"; echo; pause ;;
            7) ( cmd_uninstall ) && exit 0; echo; pause ;;
            8) cmd_check || true; echo; pause ;;
            0|q|Q) echo "退出"; exit 0 ;;
            *) echo "没有这个选项, 请输入 0-8"; sleep 1 ;;
        esac
    done
}

cmd_help() {
    cat <<'EOF'
nft-forward.sh v27 (最终版) — 多 VPS nftables 端口转发 (一键安装 + 交互菜单 + 快捷命令)

在“中转机”上运行, 把本机端口转发到另一台机器 (落地机/内网服务)。

一键安装 + 呼出菜单 (每台中转机只跑一次):
  bash nft-forward.sh install
  # 或直接 bash nft-forward.sh / nft-forward / zf (无参数进菜单, 未安装会先提示安装)
  # 安装后在任意目录输入以下任一命令即可呼出菜单:
  #   nft-forward    或    zf

菜单里能做的事: 1 添加  2 删除  3 查看  4 状态  5 重新应用  6 清空  7 卸载  8 上线前检查  0 退出

上线前检查 (装完、加规则前后都建议跑一次):
  sudo nft-forward check
  # 列出监听端口、其他表的 DNAT、Docker 发布端口、代理服务、本机 IP,
  # 并逐条比对现有转发规则有没有撞上。

添加转发:
  sudo nft-forward add <本机端口> <目标IP或域名> [目标端口] [tcp|udp|both]
  sudo nft-forward add 8080 1.2.3.4 80 tcp        # 本机 8080 -> 1.2.3.4:80, 仅 TCP
  sudo nft-forward add 8080 example.com 80       # 域名添加时解析一次, 存解析到的 IP
  sudo nft-forward add 51820 1.2.3.4             # 本机 51820 -> 1.2.3.4:51820, TCP+UDP
  sudo nft-forward add 10000-10010 1.2.3.4       # 端口段转发
  sudo nft-forward add 443 10.0.0.5 8443 both    # 转发到内网 IP 也可以

管理:
  sudo nft-forward list      # 看规则文件 + 实时 nft 规则 + 持久化状态
  sudo nft-forward status    # 看转发开关 + 服务状态 + 规则
  sudo nft-forward del 8080 [tcp|udp|both]  # 删除某端口转发
  sudo nft-forward clear     # 清空全部转发
  sudo nft-forward apply     # 按规则文件重建 (改完文件/重启后用)
  sudo nft-forward uninstall # 卸载
  sudo nft-forward menu      # 呼出菜单 (需要交互终端)
  sudo nft-forward version   # 显示当前版本 (下完文件就能先确认, 不用装)

注意:
  - 只支持 IPv4 目标, 不支持 IPv6 转发。目标可以填域名, 添加时解析一次存 IP, IP 变了要删除重加。
  - DNAT 只对目的地址是本机的包生效 (fib daddr type local), 不会劫持
    Docker 容器出站、Xray/mihomo 出站、WireGuard 对端经本机去外网的流量。
  - MASQUERADE 只对被 DNAT 过的连接生效 (ct status dnat), 本机代理出站不动。
  - forward 链是 policy accept, 不会断掉 Docker / WireGuard 等其他项目的转发。
  - 不主动 enable nftables.service, 不改一个本来就没启用的默认防火墙配置。
  - 只动自己的两张表, 不 flush 全局, 不动 SSH (转发 22 端口会二次确认)。
  - 规则存在 /etc/nft-forward/rules.conf, 持久化 nft 文件在 /etc/nft-forward/rules.nft,
    重启后 systemd 自动恢复。
  - 落地机那边如果有防火墙, 记得放行目标端口; 中转机云厂商安全组也要放行本机端口。
EOF
}

case "${1:-menu}" in
    install)   cmd_install ;;
    menu)      cmd_menu ;;
    check|preflight)
        # v6: 无参命令多余参数直接报错, 之前 `clear foo` 也会真的清空全部规则
        [ "$#" -gt 1 ] && { red "错误: $1 不接受多余参数: $2"; exit 1; }
        cmd_check ;;
    add)       shift; cmd_add "$@" ;;
    del|delete|remove) shift; cmd_del "$@" ;;
    list|ls)
        [ "$#" -gt 1 ] && { red "错误: $1 不接受多余参数: $2"; exit 1; }
        cmd_list ;;
    status)
        [ "$#" -gt 1 ] && { red "错误: $1 不接受多余参数: $2"; exit 1; }
        cmd_status ;;
    clear)
        [ "$#" -gt 1 ] && { red "错误: $1 不接受多余参数: $2"; exit 1; }
        cmd_clear ;;
    apply|reload)
        [ "$#" -gt 1 ] && { red "错误: $1 不接受多余参数: $2"; exit 1; }
        apply_rules ;;
    uninstall)
        [ "$#" -gt 1 ] && { red "错误: $1 不接受多余参数: $2"; exit 1; }
        cmd_uninstall ;;
    version)
        # v30: 显示当前版本。不需要 root、不碰 nft, 下完文件就能先确认版本。
        # 直接读 SCRIPT_VERSION 变量, 不写死, 以后升版不会又过期 (v11 教训)。
        [ "$#" -gt 1 ] && { red "错误: $1 不接受多余参数: $2"; exit 1; }
        echo "nft-forward $SCRIPT_VERSION" ;;
    help|--help|-h) cmd_help ;;
    *) red "未知命令: $1"; cmd_help; exit 1 ;;
esac
