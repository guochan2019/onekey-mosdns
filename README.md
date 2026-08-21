# onekey-mosdns

一键在 Debian 13 上部署 [mosdns](https://github.com/IrineSistiana/mosdns) v5 DNS 转发器，实现：

- **国内域名分流** → 阿里/天津公共 DNS（快速就近 CDN）
- **国外域名分流** → Cloudflare + Google DNS（DoT/DoH 加密）
- **广告屏蔽** → v2ray 广告规则 + 自定义 blocklist
- **GEO IP 数据** → 从 geoip.dat 解包国内 CIDR 至 ip_set，支持 IP 级匹配
- **DNS 缓存** → 内存缓存 + lazy cache + 磁盘持久化
- **自动更新** → 每周更新域名规则 + GEO 数据 + mosdns 自身版本

---

## 快速开始

> ⚠️ 需要 root 权限。脚本会自动检测并停用 systemd-resolved 以防端口冲突。

```bash
# 方式一：一键直达（推荐）
bash <(wget -qO- https://raw.githubusercontent.com/guochan2019/onekey-mosdns/main/onekey-mosdns.sh)

# 方式二：wget
wget -qO- https://raw.githubusercontent.com/guochan2019/onekey-mosdns/main/onekey-mosdns.sh | bash
```

---

## 使用方式

运行脚本后显示菜单：

```
========================================
  mosdns 一键安装/升级/卸载脚本
========================================

[INFO] 检测到 mosdns v5.3.4 已安装

请选择操作：
  1. 安装 / 升级 mosdns
  2. 卸载 mosdns
  0. 退出
```

| 选项 | 功能 |
|------|------|
| **1** | 未安装 → 9 步完整安装；已安装 → 检测版本并升级 |
| **2** | 卸载：停止服务、删除全部文件、清除 crontab、恢复 `/etc/resolv.conf` → 223.5.5.5 |
| **0** | 退出 |

## 安装流程

| 步骤 | 说明 |
|------|------|
| 1/9 | 安装依赖（wget、unzip、curl、dnsutils） |
| 2/9 | 停用 systemd-resolved，放行 :53 端口 |
| 3/9 | 下载并安装最新版 mosdns |
| 4/9 | 安装 GEO 数据解包工具（内嵌 Python 脚本） |
| 5/9 | 创建 `/opt/mosdns/{rule,}` 和日志目录 |
| 6/9 | 下载 GEO 数据（geoip.dat + geosite.dat），解包全部规则 |
| 7/9 | 写入 config.yaml |
| 8/9 | 创建 systemd 服务并启用开机自启 |
| 9/9 | 启动 mosdns，验证解析 |
| 可选 | 设置本机 DNS → 127.0.0.1 |

安装完成后自动进行三项验证：
- `www.baidu.com` → 国内 DNS 解析
- `www.google.com` → 国外 DNS 解析
- `doubleclick.net` → 广告屏蔽

---

## 目录结构

```
/opt/mosdns/
├── config.yaml                  # mosdns 配置文件
├── cache.dump                   # DNS 缓存持久化文件（自动生成）
├── geoip-unpack.py              # GEOIP 数据解包脚本（从 .dat 提取 CIDR）
├── rule/
│   ├── geosite_cn.txt           # 国内域名列表
│   ├── geosite_geolocation-!cn.txt  # 国外域名列表
│   ├── geosite_category-ads-all.txt # 广告/跟踪域名列表
│   ├── geoip_cn.txt             # 国内 IP 段列表（CIDR，从 geoip.dat 解包）
│   ├── whitelist.txt            # 白名单域名（走国内 DNS，可选）
│   ├── blocklist.txt            # 自定义拦截域名（可选）
│   └── hosts.txt                # 自定义 hosts 映射（可选）
└── update-mosdns.sh             # 自动更新脚本（crontab 每周一执行）

/usr/share/v2ray/                # 全局 GEO 共享目录
├── geoip.dat                    # IP 段数据库（二进制）
└── geosite.dat                  # 域名数据库（二进制）

/var/log/mosdns/
├── mosdns.log                   # mosdns 运行日志
└── update-mosdns.log            # 更新脚本日志
```

---

## 配置说明

### 国内上游 DNS

| 地址 | 提供商 |
|------|--------|
| `202.99.192.66` | 天津电信 |
| `202.99.192.68` | 天津电信 |
| `223.5.5.5` | 阿里 DNS |
| `223.6.6.6` | 阿里 DNS |

### 国外上游 DNS

| 地址 | 协议 | 说明 |
|------|------|------|
| `tls://1.1.1.1` | DoT | Cloudflare，pipeline 复用 |
| `tls://8.8.8.8` | DoT | Google，pipeline 复用 |
| `https://1.1.1.1/dns-query` | DoH | Cloudflare，bootstrap 阿里 |
| `https://8.8.8.8/dns-query` | DoH | Google，bootstrap 阿里 |

### GEO 数据来源

| 文件 | 来源 | 类型 | 用途 |
|------|------|------|------|
| `geosite_cn.txt` | 从 `geosite.dat` 解包 tag `CN` | 域名 | `domain_set` 国内域名 |
| `geosite_geolocation-!cn.txt` | 从 `geosite.dat` 解包 tag `GEOLOCATION-!CN` | 域名 | `domain_set` 国外域名 |
| `geosite_category-ads-all.txt` | 从 `geosite.dat` 解包 tag `CATEGORY-ADS-ALL` | 域名 | `domain_set` 广告屏蔽 |
| `geoip_cn.txt` | 从 `geoip.dat` 解包（Python protobuf） | CIDR | `ip_set` 国内 IP 段 |
| `whitelist.txt` | 自定义（空模板） | 域名 | `domain_set` 白名单，优先直通国内 DNS |
| `blocklist.txt` | 自定义（空模板） | 域名 | `domain_set` 额外拦截域名 |
| `hosts.txt` | 自定义（空模板） | hosts | 自定义域名映射 |
| `geoip.dat` + `geosite.dat` | [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat) release | 二进制 | 全局 GEO 共享数据 |

每周一 crontab 自动更新所有 GEO 数据。

### 处理流程

```
客户端请求 → mosdns :53
  ├─ 白名单域名 → 国内 DNS（优先级最高）
  ├─ 广告域名/blocklist → reject (NXDOMAIN)
  ├─ qtype 65 (HTTPS) → reject（减少 QUIC 泄漏）
  ├─ 查询缓存 → 命中则直接返回
  ├─ 国内域名 → 国内 DNS
  ├─ 国外域名 → 远程 DNS（prefer_ipv4）
  └─ 其余 → fallback 双检
       ├─ primary: 国内 DNS → 结果非国内 IP 则丢弃
       └─ secondary: 远程 DNS（500ms 超时）
```

---

## 服务管理

```bash
systemctl status mosdns       # 查看状态
systemctl restart mosdns      # 重启
systemctl stop mosdns         # 停止
journalctl -u mosdns -f       # 实时日志
```

### 升级 / 卸载

再次运行脚本选择对应选项即可：

```bash
bash onekey-mosdns.sh
# 选 1 → 升级；选 2 → 卸载
```

---

## API 接口

mosdns 在本机 9091 端口提供 HTTP API：

```bash
# 清空缓存
curl http://127.0.0.1:9091/flush

# 下载缓存快照
curl http://127.0.0.1:9091/dump -o cache.dump
```

---

## 自动更新

crontab 每周一 03:00 执行 `/opt/mosdns/update-mosdns.sh`，完成两件事：

1. **更新 GEO 数据** — 重下 `geoip.dat` + `geosite.dat` 至 `/usr/share/v2ray/`，解包全部域名规则 + geoip CIDR
2. **升级 mosdns** — 检测 GitHub 最新 release，版本不一致时自动下载替换

更新完成后自动重启 mosdns 使配置生效。

---

## 许可证

本项目基于 [GPL-3.0](LICENSE) 协议。mosdns 本身同样遵循 GPL-3.0。
