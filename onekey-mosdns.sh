#!/bin/bash
# 切到安全目录（防止当前工作目录被安装过程删除导致 getcwd 报错）
cd /tmp
# ============================================================
# onekey-mosdns — mosdns 一键安装/升级/卸载脚本
# 适用环境: Debian 13 (fresh LXC)
# 功能: 国内+国外DNS分流 + 广告屏蔽 + 缓存
# ============================================================
set -e

trap 'echo -e "\033[0;31m[ERROR] 脚本执行失败，请检查:\033[0m
  - 网络连接（能否访问 github.com）
  - 是否以 root 运行" >&2' ERR

# ---------- 配置 ----------
FALLBACK_VER="v5.3.4"
INSTALL_DIR="/opt/mosdns"
RULE_DIR="${INSTALL_DIR}/rule"
BIN="/usr/local/bin/mosdns"
V2RAY_DIR="/usr/share/v2ray"

# ---------- 彩色输出 ----------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ---------- 检测 root ----------
if [ "$(id -u)" -ne 0 ]; then
  err "请以 root 用户运行 (当前非 root)"
fi

# ---------- 获取最新版本 ----------
fetch_latest_ver() {
  curl -s --connect-timeout 5 \
    https://api.github.com/repos/IrineSistiana/mosdns/releases/latest \
    | grep -o '"tag_name": *"[^"]*"' | grep -o 'v[^\"]*' 2>/dev/null || echo ""
}

# ---------- 获取当前版本 ----------
get_current_ver() {
  if [ ! -f "$BIN" ]; then
    echo ""; return
  fi
  "$BIN" version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo ""
}

# ---------- 卸载 ----------
uninstall_mosdns() {
  echo ""
  warn "========== 卸载 mosdns =========="
  echo ""
  systemctl stop mosdns 2>/dev/null || true
  systemctl disable mosdns 2>/dev/null || true
  rm -f /etc/systemd/system/mosdns.service
  systemctl daemon-reload

  rm -f "$BIN"
  rm -rf "$INSTALL_DIR"
  rm -rf /var/log/mosdns

  # 清除 crontab
  (crontab -l 2>/dev/null | grep -v update-mosdns) | crontab - 2>/dev/null || true

  # 恢复 DNS（如果当前是 127.0.0.1，改成公共 DNS 否则断网）
  if grep -q 'nameserver 127.0.0.1' /etc/resolv.conf 2>/dev/null; then
    echo "nameserver 223.5.5.5" > /etc/resolv.conf
    info "  /etc/resolv.conf 已恢复 (223.5.5.5)"
  fi

  info "✓ mosdns 已卸载"
  info "  安装目录 ${INSTALL_DIR} 已删除"
  info "  crontab 已清除"
  echo ""
  exit 0
}

# ---------- 安装 ----------
do_install() {
  MOSDNS_VER="$1"

  # 1. 安装依赖
  info "=== 1/9 安装系统依赖 ==="
  apt update -qq
  apt install -y -qq wget unzip curl dnsutils python3

  # 2. 关闭冲突服务
  info "=== 2/9 关闭可能占用 :53 的服务 ==="
  if systemctl is-active systemd-resolved &>/dev/null; then
    systemctl stop systemd-resolved
    systemctl disable systemd-resolved
    warn "  已停止 systemd-resolved"
  fi
  if [ -L /etc/resolv.conf ]; then
    rm -f /etc/resolv.conf
    echo "nameserver 223.5.5.5" > /etc/resolv.conf
    chmod 644 /etc/resolv.conf
  fi

  # 3. 下载 mosdns
  info "=== 3/9 下载 mosdns ${MOSDNS_VER} ==="
  MOSDNS_URL="https://github.com/IrineSistiana/mosdns/releases/download/${MOSDNS_VER}/mosdns-linux-amd64.zip"
  TMPDIR=$(mktemp -d)
  cd "$TMPDIR"
  wget -q "$MOSDNS_URL" -O mosdns.zip
  unzip -q mosdns.zip
  install -m 755 mosdns "$BIN"
  chmod +x "$BIN"
  rm -rf "$TMPDIR"
  "$BIN" version 2>/dev/null | head -1 || info "  ✓ mosdns 已安装"

  # 4. 创建目录结构
  info "=== 4/9 创建目录结构 ==="
  mkdir -p "$RULE_DIR" "$INSTALL_DIR" /var/log/mosdns

  # 5. 安装 GEO 数据解包工具
  info "=== 5/9 安装 GEO 数据解包工具 ==="
  UNPACK_SCRIPT="${INSTALL_DIR}/geoip-unpack.py"
  cat > "$UNPACK_SCRIPT" << 'UNPACKEOF'
#!/usr/bin/env python3
"""从 geoip.dat / geosite.dat 解包指定 tag 到纯文本"""
import struct, sys, ipaddress

def _read_varint(data, offset):
    result = 0; shift = 0
    while offset < len(data):
        byte = data[offset]
        result |= (byte & 0x7F) << shift
        shift += 7; offset += 1
        if not (byte & 0x80): return result, offset
    raise ValueError("truncated varint")

def _read_bytes(data, offset):
    length, offset = _read_varint(data, offset)
    return data[offset:offset + length], offset + length

def unpack_geoip(dat_path, target_tags):
    target_tags = set(target_tags)
    with open(dat_path, 'rb') as f: raw = f.read()
    offset = 0; results = []
    while offset < len(raw):
        field, offset = _read_varint(raw, offset)
        if (field & 0x7) != 2: continue
        length, offset = _read_varint(raw, offset)
        entry_data = raw[offset:offset + length]; offset += length
        if (field >> 3) != 1: continue
        eo = 0; country_code = None; cidrs = []
        while eo < len(entry_data):
            ef, eo = _read_varint(entry_data, eo)
            ew = ef & 0x7; en = ef >> 3
            if en == 1 and ew == 2:
                country_code, eo = _read_bytes(entry_data, eo)
                country_code = country_code.decode()
            elif en == 2 and ew == 2:
                cl, eo = _read_varint(entry_data, eo)
                cd = entry_data[eo:eo+cl]; eo += cl
                co = 0; ipb = None; pre = None
                while co < len(cd):
                    cf, co = _read_varint(cd, co)
                    cw = cf & 0x7; cn = cf >> 3
                    if cn == 1 and cw == 2:
                        ipb, co = _read_bytes(cd, co)
                    elif cn == 2 and cw == 0:
                        pre, co = _read_varint(cd, co)
                if ipb and pre is not None:
                    cidrs.append(f"{ipaddress.ip_address(ipb)}/{pre}")
        if country_code in target_tags:
            results.extend(cidrs)
    return results

_TYPE_MAP = {0: "keyword", 1: "regexp", 2: None, 3: "full"}

def unpack_geosite(dat_path, target_tags):
    target_tags = set(target_tags)
    with open(dat_path, 'rb') as f: raw = f.read()
    offset = 0; results = []
    while offset < len(raw):
        field, offset = _read_varint(raw, offset)
        if (field & 0x7) != 2: continue
        length, offset = _read_varint(raw, offset)
        entry_data = raw[offset:offset + length]; offset += length
        if (field >> 3) != 1: continue
        eo = 0; country_code = None; domains = []
        while eo < len(entry_data):
            ef, eo = _read_varint(entry_data, eo)
            ew = ef & 0x7; en = ef >> 3
            if en == 1 and ew == 2:
                country_code, eo = _read_bytes(entry_data, eo)
                country_code = country_code.decode()
            elif en == 2 and ew == 2:
                dl, eo = _read_varint(entry_data, eo)
                dd = entry_data[eo:eo+dl]; eo += dl
                do = 0; dtype = None; dval = None
                while do < len(dd):
                    df, do = _read_varint(dd, do)
                    dw = df & 0x7; dn = df >> 3
                    if dn == 1 and dw == 0:
                        dtype, do = _read_varint(dd, do)
                    elif dn == 2 and dw == 2:
                        dval, do = _read_bytes(dd, do)
                        dval = dval.decode()
                    else:
                        if dw == 0: _, do = _read_varint(dd, do)
                        elif dw == 2: sl, do = _read_varint(dd, do); do += sl
                if dval:
                    prefix = _TYPE_MAP.get(dtype)
                    if prefix:
                        domains.append(f"{prefix}:{dval}")
                    else:
                        domains.append(dval)
        if country_code in target_tags:
            results.extend(domains)
    return results

if __name__ == '__main__':
    if len(sys.argv) < 4:
        print(f"Usage: {sys.argv[0]} <geoip|geosite> <dat_file> <tag> [tag...]", file=sys.stderr)
        sys.exit(1)
    mode = sys.argv[1]
    dat_path = sys.argv[2]
    tags = sys.argv[3:]
    if mode == "geoip":
        entries = unpack_geoip(dat_path, tags)
        entries.sort(key=lambda x: int(ipaddress.ip_address(x.split('/')[0])))
    elif mode == "geosite":
        entries = unpack_geosite(dat_path, tags)
        entries.sort()
    else:
        print(f"Unknown mode: {mode}", file=sys.stderr)
        sys.exit(1)
    for e in entries:
        print(e)
UNPACKEOF
  chmod +x "$UNPACK_SCRIPT"
  info "  ✓ 解包脚本已安装"

  # 6. 下载 GEO 数据并解包
  info "=== 6/9 下载 GEO 数据 ==="
  mkdir -p "$V2RAY_DIR"
  echo -n "  下载 geoip.dat ... "
  wget -q "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -O "${V2RAY_DIR}/geoip.dat"
  echo "done ($(du -h "${V2RAY_DIR}/geoip.dat" | cut -f1))"
  echo -n "  下载 geosite.dat ... "
  wget -q "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -O "${V2RAY_DIR}/geosite.dat"
  echo "done ($(du -h "${V2RAY_DIR}/geosite.dat" | cut -f1))"

  info "  --- 解包规则 ---"
  echo -n "  解包 geosite_cn.txt ... "
  python3 "$UNPACK_SCRIPT" geosite "${V2RAY_DIR}/geosite.dat" CN > "${RULE_DIR}/geosite_cn.txt"
  echo "done ($(wc -l < "${RULE_DIR}/geosite_cn.txt") 条)"
  echo -n "  解包 geosite_geolocation-!cn.txt ... "
  python3 "$UNPACK_SCRIPT" geosite "${V2RAY_DIR}/geosite.dat" GEOLOCATION-!CN > "${RULE_DIR}/geosite_geolocation-!cn.txt"
  echo "done ($(wc -l < "${RULE_DIR}/geosite_geolocation-!cn.txt") 条)"
  echo -n "  解包 geosite_category-ads-all.txt ... "
  python3 "$UNPACK_SCRIPT" geosite "${V2RAY_DIR}/geosite.dat" CATEGORY-ADS-ALL > "${RULE_DIR}/geosite_category-ads-all.txt"
  echo "done ($(wc -l < "${RULE_DIR}/geosite_category-ads-all.txt") 条)"
  echo -n "  解包 geoip_cn.txt ... "
  python3 "$UNPACK_SCRIPT" geoip "${V2RAY_DIR}/geoip.dat" CN > "${RULE_DIR}/geoip_cn.txt"
  echo "done ($(wc -l < "${RULE_DIR}/geoip_cn.txt") 条)"

  # 创建自定义规则模板文件
  for f in whitelist.txt blocklist.txt hosts.txt; do
    [ -f "${RULE_DIR}/$f" ] || touch "${RULE_DIR}/$f"
  done
  # Tailscale 域名规则
  echo 'keyword:ts.net' > "${RULE_DIR}/ts_domain.txt"
  info "  ✓ 自定义规则模板已创建 (whitelist/blocklist/hosts/ts_domain)"

  # 7. 写入 config.yaml
  info "=== 7/9 写入 config.yaml ==="
  cat > "${INSTALL_DIR}/config.yaml" << 'CONFIGEOF'
log:
  level: info
  file: "/var/log/mosdns/mosdns.log"

api:
  http: "127.0.0.1:9091"

plugins:
  # ========== 域名/IP 数据集 ==========
  # 国内域名
  - tag: geosite_cn
    type: domain_set
    args:
      files: ["/opt/mosdns/rule/geosite_cn.txt"]

  # 国外域名
  - tag: geosite_no_cn
    type: domain_set
    args:
      files: ["/opt/mosdns/rule/geosite_geolocation-!cn.txt"]

  # 国内 IP
  - tag: geoip_cn
    type: ip_set
    args:
      files: ["/opt/mosdns/rule/geoip_cn.txt"]

  # 广告域名
  - tag: ad_domain
    type: domain_set
    args:
      files: ["/opt/mosdns/rule/geosite_category-ads-all.txt"]

  - tag: blocklist
    type: domain_set
    args:
      files: ["/opt/mosdns/rule/blocklist.txt"]

  - tag: whitelist
    type: domain_set
    args:
      files: ["/opt/mosdns/rule/whitelist.txt"]

  - tag: hosts
    type: hosts
    args:
      files: ["/opt/mosdns/rule/hosts.txt"]

  # Tailscale域名后缀（需手动添加）
  - tag: ts_domain
    type: domain_set
    args:
      files: ["/opt/mosdns/rule/ts_domain.txt"]

  # ========== 缓存 ==========
  - tag: lazy_cache
    type: cache
    args:
      size: 20000
      lazy_cache_ttl: 86400
      dump_file: "./cache.dump"
      dump_interval: 600

  # ========== 转发 ==========
  # 转发至本地服务器
  - tag: forward_local
    type: forward
    args:
      concurrent: 3
      upstreams:
        - addr: "202.99.192.66"
        - addr: "202.99.192.68"
        - addr: "223.5.5.5"
        - addr: "223.6.6.6"

  # 转发至远程服务器
  - tag: forward_remote
    type: forward
    args:
      concurrent: 3
      upstreams:
        - addr: "tls://1.1.1.1"
          enable_pipeline: true
        - addr: "tls://8.8.8.8"
          enable_pipeline: true
        - addr: "https://1.1.1.1/dns-query"
          bootstrap: "223.5.5.5"
        - addr: "https://8.8.8.8/dns-query"
          bootstrap: "223.5.5.5"

  # 转发至tailscale服务器
  - tag: forward_tailscale
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: "100.100.100.100"
        - addr: "fd7a:115c:a1e0::53"

  # ========== 序列 ==========
  # 国内解析
  - tag: local_sequence
    type: sequence
    args:
      - exec: $forward_local

  # 国外解析
  - tag: remote_sequence
    type: sequence
    args:
      - exec: prefer_ipv4
      - exec: $forward_remote

  # 有响应终止返回
  - tag: has_resp_sequence
    type: sequence
    args:
      - matches: has_resp
        exec: accept

  # fallback 用本地服务器 sequence
  # 返回非国内 ip 则 drop_resp
  - tag: query_is_local_ip
    type: sequence
    args:
      - exec: $local_sequence
      - matches: "!resp_ip $geoip_cn"
        exec: drop_resp

  # fallback 用远程服务器 sequence
  - tag: query_is_remote
    type: sequence
    args:
      - exec: $remote_sequence

  # fallback 用远程服务器 sequence
  - tag: fallback
    type: fallback
    args:
      primary: query_is_remote
      secondary: query_is_remote
      threshold: 500
      always_standby: true

  # 查询国内域名
  - tag: query_is_local_domain
    type: sequence
    args:
      - matches: qname $geosite_cn
        exec: $local_sequence

  # 查询国外域名
  - tag: query_is_no_local_domain
    type: sequence
    args:
      - matches: qname $geosite_no_cn
        exec: $remote_sequence

  # ========== 主流程 ==========
  - tag: main_sequence
    type: sequence
    args:
      # 1. 白名单直通国内
      - matches: qname $whitelist
        exec: $forward_local
      - matches: has_resp
        exec: accept
      # 2. 广告拦截
      - matches: qname $ad_domain
        exec: reject 3
      - matches: qname $blocklist
        exec: reject 3
      - matches: qtype 65
        exec: reject 3
      # 3. 缓存命中
      - exec: $lazy_cache
      - matches: has_resp
        exec: accept
      # 3.5 Tailscale → Tailscale DNS
      - matches: qname $ts_domain
        exec: $forward_tailscale
      - matches: has_resp
        exec: accept
      # 4. 国内域名 → 国内 DNS
      - matches: qname $geosite_cn
        exec: $local_sequence
      - matches: has_resp
        exec: accept
      # 5. 非 CN 域名 → 远程 DNS
      - matches: qname $geosite_no_cn
        exec: $remote_sequence
      - matches: has_resp
        exec: accept
      # 6. 剩余域名 → fallback 双检
      - exec: $fallback

  # ========== 服务器 ==========
  - tag: udp_server
    type: udp_server
    args:
      entry: main_sequence
      listen: ":53"

  - tag: tcp_server
    type: tcp_server
    args:
      entry: main_sequence
      listen: ":53"
CONFIGEOF

  # 8. 创建 systemd 服务
  info "=== 8/9 创建 systemd 服务 ==="
  cat > /etc/systemd/system/mosdns.service << 'SERVICEEOF'
[Unit]
Description=mosdns - pluginable DNS forwarder
Documentation=https://irine-sistiana.gitbook.io/mosdns-wiki/
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/mosdns
ExecStart=/usr/local/bin/mosdns start -c /opt/mosdns/config.yaml -d /opt/mosdns
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

StandardOutput=append:/var/log/mosdns/mosdns.log
StandardError=append:/var/log/mosdns/mosdns.log

[Install]
WantedBy=multi-user.target
SERVICEEOF
  systemctl daemon-reload

  # 9. 启动
  info "=== 9/9 启动 mosdns 服务 ==="
  systemctl enable mosdns
  systemctl start mosdns
  sleep 2
  if systemctl is-active mosdns &>/dev/null; then
    info "  ✓ mosdns 已成功启动！"
  else
    warn "  ⚠ mosdns 启动失败，检查日志: journalctl -u mosdns -n 50 --no-pager"
    systemctl status mosdns --no-pager
    exit 1
  fi

  # 验证
  info ""
  info "========== 安装完成 =========="
  info " mosdns 版本: ${MOSDNS_VER}"
  info " 安装目录:    ${INSTALL_DIR}"
  info " 配置文件:    ${INSTALL_DIR}/config.yaml"
  info " API 接口:    http://127.0.0.1:9091"

  info ""
  info "========== 快速验证 =========="
  echo -n "   国内域名 www.baidu.com ........ "
  BAIDU_IP=$(dig +short @127.0.0.1 www.baidu.com | head -1)
  [ -n "$BAIDU_IP" ] && echo -e "${GREEN}✓${NC} $BAIDU_IP" || echo -e "${RED}✗${NC} 无应答"
  echo -n "   国外域名 www.google.com ....... "
  GOOGLE_IP=$(dig +short @127.0.0.1 www.google.com | head -1)
  [ -n "$GOOGLE_IP" ] && echo -e "${GREEN}✓${NC} $GOOGLE_IP" || echo -e "${RED}✗${NC} 无应答"
  echo -n "   广告域名 doubleclick.net ..... "
  AD_RC=$(dig +short @127.0.0.1 doubleclick.net 2>&1 | head -1)
  [ -z "$AD_RC" ] && echo -e "${GREEN}✓${NC} 已屏蔽 (空应答)" || echo -e "${YELLOW}?${NC} 有返回值: $AD_RC"

  # 设置 DNS
  echo ""
  warn "将本机 DNS 设为 127.0.0.1 才能使用 mosdns"
  read -p "是否立即设置？(y/n) " -n 1 -r </dev/tty
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    info "  ✓ /etc/resolv.conf 已设置"
  fi

  # 自动更新脚本（crontab）
  info "=== 安装自动更新脚本（每周一 03:00） ==="
  cat > /opt/mosdns/update-mosdns.sh << 'UPDATEEOF'
#!/bin/bash
set -e
RULE_DIR="/opt/mosdns/rule"
BIN="/usr/local/bin/mosdns"
LOG="/var/log/mosdns/update-mosdns.log"
FALLBACK_VER="v5.3.4"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }
log "=== 开始更新 ==="

log "1/2 更新 GEO 数据..."
V2RAY_DIR="/usr/share/v2ray"
mkdir -p "$V2RAY_DIR"
wget -q "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -O "${V2RAY_DIR}/geoip.dat.new" || { log "  ✗ geoip.dat 下载失败"; exit 1; }
mv "${V2RAY_DIR}/geoip.dat.new" "${V2RAY_DIR}/geoip.dat"
wget -q "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -O "${V2RAY_DIR}/geosite.dat.new" || { log "  ✗ geosite.dat 下载失败"; exit 1; }
mv "${V2RAY_DIR}/geosite.dat.new" "${V2RAY_DIR}/geosite.dat"
python3 /opt/mosdns/geoip-unpack.py geosite "${V2RAY_DIR}/geosite.dat" CN              > "${RULE_DIR}/geosite_cn.txt" 2>/dev/null
python3 /opt/mosdns/geoip-unpack.py geosite "${V2RAY_DIR}/geosite.dat" GEOLOCATION-!CN > "${RULE_DIR}/geosite_geolocation-!cn.txt" 2>/dev/null
python3 /opt/mosdns/geoip-unpack.py geosite "${V2RAY_DIR}/geosite.dat" CATEGORY-ADS-ALL > "${RULE_DIR}/geosite_category-ads-all.txt" 2>/dev/null
python3 /opt/mosdns/geoip-unpack.py geoip   "${V2RAY_DIR}/geoip.dat" CN                 > "${RULE_DIR}/geoip_cn.txt" 2>/dev/null
CN_CNT=$(wc -l < "$RULE_DIR/geosite_cn.txt")
REMOTE_CNT=$(wc -l < "$RULE_DIR/geosite_geolocation-!cn.txt")
AD_CNT=$(wc -l < "$RULE_DIR/geosite_category-ads-all.txt")
IP_CNT=$(wc -l < "$RULE_DIR/geoip_cn.txt")
log "  ✓ 规则已更新: CN=${CN_CNT}, Remote=${REMOTE_CNT}, Ads=${AD_CNT}, GeoIP_CN=${IP_CNT}"

log "2/2 检查 mosdns 新版本..."
CURRENT_VER=$("$BIN" version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
LATEST_VER=$(curl -s --connect-timeout 5 https://api.github.com/repos/IrineSistiana/mosdns/releases/latest | grep -o '"tag_name": *"[^"]*"' | grep -o 'v[^"]*' 2>/dev/null || echo "$FALLBACK_VER")
log "  当前版本: ${CURRENT_VER}, 最新版本: ${LATEST_VER}"
if [ "$CURRENT_VER" != "$LATEST_VER" ] && [ "$LATEST_VER" != "$FALLBACK_VER" ]; then
  log "  发现新版本 ${LATEST_VER}，开始更新..."
  TMPDIR=$(mktemp -d); cd "$TMPDIR"
  wget -q "https://github.com/IrineSistiana/mosdns/releases/download/${LATEST_VER}/mosdns-linux-amd64.zip" -O mosdns.zip
  unzip -q mosdns.zip; install -m 755 mosdns "$BIN"; chmod +x "$BIN"; rm -rf "$TMPDIR"
  log "  ✓ 已升级到 ${LATEST_VER}"
else
  log "  - 已是最新版本，无需更新"
fi
systemctl restart mosdns
log "✓ mosdns 已重启，更新完成"
UPDATEEOF
  chmod +x /opt/mosdns/update-mosdns.sh
  # 🔴 子 shell 内必须 set +e：空 crontab 时 `crontab -l | grep -v` 的 grep 退出码 1，
  #    继承的 set -e 会杀死子 shell → echo 不执行 → crontab - 收到空输入（清空/不写入）
  (set +e; crontab -l 2>/dev/null | grep -v update-mosdns; echo "0 3 * * 1 /opt/mosdns/update-mosdns.sh >/dev/null 2>&1") | crontab -
  info "  ✓ 已创建 update-mosdns.sh 并添加 crontab（每周一 03:00）"
  info "     📍 定时任务保存位置: root 用户 crontab（/var/spool/cron/crontabs/root），crontab -l 查看"

  info ""
  info "✅ 全部完成！mosdns 已在 :53 提供服务"
}

# ---------- 升级 ----------
do_upgrade() {
  MOSDNS_VER="$1"
  CURRENT_VER="$2"

  if [ -f "/opt/mosdns/update-mosdns.sh" ]; then
    info "调用自动更新脚本（GEO 数据更新 + mosdns 升级）..."
    bash /opt/mosdns/update-mosdns.sh
  else
    info "=== 升级 mosdns: ${CURRENT_VER:-未知} → ${MOSDNS_VER} ==="
    MOSDNS_URL="https://github.com/IrineSistiana/mosdns/releases/download/${MOSDNS_VER}/mosdns-linux-amd64.zip"
    TMPDIR=$(mktemp -d)
    cd "$TMPDIR"
    wget -q "$MOSDNS_URL" -O mosdns.zip
    unzip -q mosdns.zip
    install -m 755 mosdns "$BIN"
    chmod +x "$BIN"
    rm -rf "$TMPDIR"
    systemctl restart mosdns
    info "  ✓ mosdns 已升级到 ${MOSDNS_VER} 并重启"
  fi
}

# =================== 主菜单 ===================
echo ""
echo "========================================"
echo "  mosdns 一键安装/升级/卸载脚本"
echo "  https://github.com/IrineSistiana/mosdns"
echo "========================================"
echo ""

INSTALLED=false
CURRENT_VER=$(get_current_ver)
if [ -f "$BIN" ]; then
  INSTALLED=true
  if [ -n "$CURRENT_VER" ]; then
    info "检测到 mosdns ${CURRENT_VER} 已安装"
  else
    info "检测到 mosdns 已安装（版本未知）"
  fi
else
  info "mosdns 未安装"
fi

echo ""
echo "请选择操作："
echo "  1. 安装 / 升级 mosdns"
echo "  2. 卸载 mosdns"
echo "  0. 退出"
echo ""
read -p "请输入选项 (0-2): " ACTION </dev/tty
echo ""

case "$ACTION" in
  2)
    uninstall_mosdns
    ;;
  0)
    info "已退出"
    exit 0
    ;;
  1|"")
    LATEST_VER=$(fetch_latest_ver)
    if [ -z "$LATEST_VER" ]; then
      LATEST_VER="$FALLBACK_VER"
      warn "GitHub API 不可用，使用后备版本 ${FALLBACK_VER}"
    fi

    if [ "$INSTALLED" = true ]; then
      if [ -f "/opt/mosdns/update-mosdns.sh" ]; then
        info "更新 GEO 数据并检查 mosdns 新版本..."
        bash /opt/mosdns/update-mosdns.sh
      else
        # 没有 update-mosdns.sh 时使用内置升级逻辑
        if [ -n "$CURRENT_VER" ] && [ "$CURRENT_VER" = "$LATEST_VER" ]; then
          info "当前版本: ${CURRENT_VER}"
          info "✓ 已是最新版本"
          exit 0
        fi
        do_upgrade "$LATEST_VER" "$CURRENT_VER"
      fi
    else
      do_install "$LATEST_VER"
    fi
    ;;
  *)
    err "无效选项: ${ACTION}"
    ;;
esac
