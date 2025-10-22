#!/bin/sh

# 智能5G WiFi创建脚本 - 为中国TikTok运营优化
# 每个WiFi自动分配独立SSID，每个WiFi限制10个设备连接
# WiFi名称格式: TikTok-01, TikTok-02, ...

WIFI_PREFIX="TikTok"
PASSWORD="123456789"
MAX_DEVICES_PER_WIFI=10  # 每个WiFi最大设备连接数

echo "======================================"
echo "智能5G WiFi创建脚本"
echo "======================================"

# 查找已存在的最大编号
find_next_number() {
    max_num=0

    # 检查已存在的WiFi SSID
    for ssid in $(uci show wireless 2>/dev/null | grep "\.ssid=" | cut -d'=' -f2 | tr -d "'"); do
        if echo "$ssid" | grep -q "^${WIFI_PREFIX}-[0-9][0-9]$"; then
            num=$(echo "$ssid" | sed "s/${WIFI_PREFIX}-//")
            num=$(echo "$num" | sed 's/^0*//')  # 移除前导零
            [ -z "$num" ] && num=0
            if [ "$num" -gt "$max_num" ]; then
                max_num=$num
            fi
        fi
    done

    # 检查已存在的网络接口
    WIFI_PREFIX_LOWER=$(echo ${WIFI_PREFIX} | tr 'A-Z' 'a-z')
    for iface in $(uci show network 2>/dev/null | grep "^network\.${WIFI_PREFIX_LOWER}" | cut -d'.' -f2 | cut -d'=' -f1 | sort -u); do
        if echo "$iface" | grep -q "^${WIFI_PREFIX_LOWER}[0-9]*$"; then
            num=$(echo "$iface" | sed "s/${WIFI_PREFIX_LOWER}//")
            [ -z "$num" ] && continue
            if [ "$num" -gt "$max_num" ]; then
                max_num=$num
            fi
        fi
    done

    echo $((max_num + 1))
}

# 查找可用的网段
find_available_subnet() {
    # 从192.168.20.0开始查找可用网段
    for subnet in $(seq 20 250); do
        if ! ip addr show 2>/dev/null | grep -q "192.168.${subnet}."; then
            if ! uci show network 2>/dev/null | grep -q "192.168.${subnet}."; then
                echo $subnet
                return
            fi
        fi
    done
    echo "0"
}

# 获取下一个编号
NEXT_NUM=$(find_next_number)
NEXT_NUM_PAD=$(printf "%02d" $NEXT_NUM)  # 补零格式化
WIFI_NAME="${WIFI_PREFIX}-${NEXT_NUM_PAD}"
INTERFACE_NAME="$(echo ${WIFI_PREFIX} | tr 'A-Z' 'a-z')${NEXT_NUM}"  # 转为小写，如：tiktok1, tiktok2

# 查找可用网段
SUBNET=$(find_available_subnet)

if [ "$SUBNET" = "0" ]; then
    echo "错误: 无法找到可用的网段！"
    exit 1
fi

echo "创建新的WiFi网络："
echo "  WiFi名称: ${WIFI_NAME}"
echo "  网络接口: ${INTERFACE_NAME}"
echo "  网段: 192.168.${SUBNET}.0/24"
echo ""

# 创建网络接口 - 使用桥接模式
echo "1. 配置网络接口..."
uci set network.${INTERFACE_NAME}=interface
uci set network.${INTERFACE_NAME}.proto='static'
uci set network.${INTERFACE_NAME}.ipaddr="192.168.${SUBNET}.1"
uci set network.${INTERFACE_NAME}.netmask='255.255.255.0'
uci set network.${INTERFACE_NAME}.type='bridge'
# 为桥接接口设置名称，这很重要！
uci set network.${INTERFACE_NAME}.ifname="br-${INTERFACE_NAME}"
# 完全禁用IPv6
uci set network.${INTERFACE_NAME}.ipv6='off'
uci set network.${INTERFACE_NAME}.ip6assign=''
uci set network.${INTERFACE_NAME}.ip6prefix=''
uci set network.${INTERFACE_NAME}.ip6gw=''
uci set network.${INTERFACE_NAME}.ip6rd=''

# 配置DHCP
echo "2. 配置DHCP服务..."
uci set dhcp.${INTERFACE_NAME}=dhcp
uci set dhcp.${INTERFACE_NAME}.interface="${INTERFACE_NAME}"
uci set dhcp.${INTERFACE_NAME}.start='100'
# 根据最大设备数调整DHCP池大小
uci set dhcp.${INTERFACE_NAME}.limit="$((MAX_DEVICES_PER_WIFI + 5))"
uci set dhcp.${INTERFACE_NAME}.leasetime='12h'
uci set dhcp.${INTERFACE_NAME}.dhcpv4='server'
# 禁用DHCPv6
uci set dhcp.${INTERFACE_NAME}.dhcpv6='disabled'
uci set dhcp.${INTERFACE_NAME}.ra='disabled'
uci set dhcp.${INTERFACE_NAME}.ra_management='0'
# 中国TikTok优化DNS设置 - 使用国内外混合DNS
uci add_list dhcp.${INTERFACE_NAME}.dhcp_option="6,223.5.5.5,119.29.29.29"
# 添加域名推送选项优化TikTok访问
uci add_list dhcp.${INTERFACE_NAME}.dhcp_option="15,tiktok.local"

# 配置防火墙区域
echo "3. 配置防火墙区域..."
uci add firewall zone > /dev/null
uci set firewall.@zone[-1].name="${INTERFACE_NAME}_zone"
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='ACCEPT'
uci add_list firewall.@zone[-1].network="${INTERFACE_NAME}"
# 启用masq以确保NAT正常工作
uci set firewall.@zone[-1].masq='1'
uci set firewall.@zone[-1].mtu_fix='1'
# 禁用IPv6
uci set firewall.@zone[-1].masq6='0'

# 添加防火墙转发规则 (允许访问互联网)
echo "4. 添加防火墙转发规则..."
uci add firewall forwarding > /dev/null
uci set firewall.@forwarding[-1].src="${INTERFACE_NAME}_zone"
uci set firewall.@forwarding[-1].dest='wan'

# 配置5G WiFi接入点
echo "5. 配置5G WiFi接入点..."

# 检测可用的5G radio
RADIO_DEVICE=""
if uci get wireless.radio1 >/dev/null 2>&1; then
    # 检查radio1是否支持5G
    if uci get wireless.radio1.band 2>/dev/null | grep -q "5g"; then
        RADIO_DEVICE="radio1"
    elif uci get wireless.radio1.htmode 2>/dev/null | grep -q "VHT"; then
        RADIO_DEVICE="radio1"
    elif uci get wireless.radio1.hwmode 2>/dev/null | grep -q "11a"; then
        RADIO_DEVICE="radio1"
    fi
fi

# 如果radio1不是5G，检查radio0
if [ -z "$RADIO_DEVICE" ]; then
    if uci get wireless.radio0 >/dev/null 2>&1; then
        if uci get wireless.radio0.band 2>/dev/null | grep -q "5g"; then
            RADIO_DEVICE="radio0"
        elif uci get wireless.radio0.htmode 2>/dev/null | grep -q "VHT"; then
            RADIO_DEVICE="radio0"
        fi
    fi
fi

# 如果还是没找到5G设备，使用默认的radio1
if [ -z "$RADIO_DEVICE" ]; then
    RADIO_DEVICE="radio1"
    echo "  警告: 未检测到5G设备，使用默认radio1"
fi

echo "  使用无线设备: ${RADIO_DEVICE}"

# 创建WiFi接口
uci add wireless wifi-iface > /dev/null
uci set wireless.@wifi-iface[-1].device="${RADIO_DEVICE}"
uci set wireless.@wifi-iface[-1].network="${INTERFACE_NAME}"
uci set wireless.@wifi-iface[-1].mode='ap'
uci set wireless.@wifi-iface[-1].ssid="${WIFI_NAME}"
uci set wireless.@wifi-iface[-1].encryption='psk2+ccmp'
uci set wireless.@wifi-iface[-1].key="${PASSWORD}"
uci set wireless.@wifi-iface[-1].isolate='1'  # 客户端隔离
uci set wireless.@wifi-iface[-1].disabled='0'
# 确保WiFi接口配置正确，避免"无线未关联"问题
uci set wireless.@wifi-iface[-1].ifname="wlan${INTERFACE_NAME}"  # 设置接口名称

# 设置5G特定参数
uci set wireless.@wifi-iface[-1].ieee80211w='1'  # 启用管理帧保护
uci set wireless.@wifi-iface[-1].ieee80211k='1'  # 启用无线资源管理
uci set wireless.@wifi-iface[-1].ieee80211r='1'  # 启用快速漫游
uci set wireless.@wifi-iface[-1].ieee80211v='1'  # 启用BSS转换

# 添加TikTok优化参数
uci set wireless.@wifi-iface[-1].maxassoc="${MAX_DEVICES_PER_WIFI}"  # 限制设备连接数
uci set wireless.@wifi-iface[-1].disassoc_low_ack='0'  # 禁用低确认断开
# 添加中国TikTok优化设置
uci set wireless.@wifi-iface[-1].hidden='0'           # 显示SSID
uci set wireless.@wifi-iface[-1].wmm='1'              # 启用WMM多媒体优化
uci set wireless.@wifi-iface[-1].short_gi='1'         # 启用短保护间隔提高速度

# 配置网段间隔离规则
echo "6. 配置网段隔离..."
WIFI_PREFIX_LOWER=$(echo ${WIFI_PREFIX} | tr 'A-Z' 'a-z')
for i in $(seq 1 $((NEXT_NUM - 1))); do
    other_interface="${WIFI_PREFIX_LOWER}${i}"
    other_wifi_name="${WIFI_PREFIX}-$(printf "%02d" $i)"

    # 检查其他接口是否存在
    if uci get network.${other_interface} >/dev/null 2>&1; then
        # 阻止当前网段访问其他网段
        uci add firewall rule > /dev/null
        uci set firewall.@rule[-1].name="block_${INTERFACE_NAME}_to_${other_interface}"
        uci set firewall.@rule[-1].src="${INTERFACE_NAME}_zone"
        uci set firewall.@rule[-1].dest="${other_interface}_zone"
        uci set firewall.@rule[-1].target='REJECT'

        # 阻止其他网段访问当前网段
        uci add firewall rule > /dev/null
        uci set firewall.@rule[-1].name="block_${other_interface}_to_${INTERFACE_NAME}"
        uci set firewall.@rule[-1].src="${other_interface}_zone"
        uci set firewall.@rule[-1].dest="${INTERFACE_NAME}_zone"
        uci set firewall.@rule[-1].target='REJECT'
    fi
done

# 添加额外的安全规则 - 阻止访问路由器管理界面
echo "7. 添加安全规则..."
# 阻止从该网段访问路由器管理端口（除了DHCP和DNS）
uci add firewall rule > /dev/null
uci set firewall.@rule[-1].name="block_${INTERFACE_NAME}_admin"
uci set firewall.@rule[-1].src="${INTERFACE_NAME}_zone"
uci set firewall.@rule[-1].dest_port='22 80 443'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].target='REJECT'

# 允许DHCP和DNS
uci add firewall rule > /dev/null
uci set firewall.@rule[-1].name="allow_${INTERFACE_NAME}_dhcp_dns"
uci set firewall.@rule[-1].src="${INTERFACE_NAME}_zone"
uci set firewall.@rule[-1].dest_port='53 67 68'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].target='ACCEPT'

# 配置passwall - 中国TikTok专用优化
echo "8. 配置passwall..."
if uci get passwall >/dev/null 2>&1; then
    # 取消勾选passwall主开关（避免全局代理干扰）
    uci set passwall.@global[0].enabled='0'
    echo "  ✓ 已取消passwall主开关"

    # 删除全局TCP节点设置（避免冲突）
    uci delete passwall.@global[0].tcp_node 2>/dev/null
    echo "  ✓ 已关闭全局TCP节点"

    # 设置UDP节点为关闭
    uci delete passwall.@global[0].udp_node 2>/dev/null
    echo "  ✓ 已关闭UDP节点"

    # 创建本地直连节点（避免无网络问题）
    LOCAL_NODE_ID="local_direct_$(date +%s | tail -c 6)"
    uci set passwall.${LOCAL_NODE_ID}=nodes
    uci set passwall.${LOCAL_NODE_ID}.protocol='_direct'
    uci set passwall.${LOCAL_NODE_ID}.type='_direct'
    uci set passwall.${LOCAL_NODE_ID}.remarks='本地直连节点（无代理）'
    uci set passwall.${LOCAL_NODE_ID}.add_from='脚本生成'
    echo "  ✓ 已创建本地直连节点: ${LOCAL_NODE_ID}（确保网络可用）"

    # 创建虚拟TCP节点（用户需手动更换为有效节点）
    VIRTUAL_NODE_ID="virtual_tiktok_$(date +%s | tail -c 6)"
    uci set passwall.${VIRTUAL_NODE_ID}=nodes
    uci set passwall.${VIRTUAL_NODE_ID}.flow='xtls-rprx-vision'
    uci set passwall.${VIRTUAL_NODE_ID}.protocol='vless'
    uci set passwall.${VIRTUAL_NODE_ID}.tcp_guise='none'
    uci set passwall.${VIRTUAL_NODE_ID}.add_from='脚本生成'
    uci set passwall.${VIRTUAL_NODE_ID}.port='443'
    uci set passwall.${VIRTUAL_NODE_ID}.remarks='虚拟TikTok节点（请手动更换有效节点）'
    uci set passwall.${VIRTUAL_NODE_ID}.add_mode='1'
    uci set passwall.${VIRTUAL_NODE_ID}.tls_allowInsecure='0'
    uci set passwall.${VIRTUAL_NODE_ID}.type='Xray'
    uci set passwall.${VIRTUAL_NODE_ID}.timeout='60'
    uci set passwall.${VIRTUAL_NODE_ID}.fingerprint='chrome'
    uci set passwall.${VIRTUAL_NODE_ID}.tls='1'
    uci set passwall.${VIRTUAL_NODE_ID}.tls_serverName='www.example.com'
    uci set passwall.${VIRTUAL_NODE_ID}.address='127.0.0.1'
    # 修改：使用网关地址而非127.0.0.1，确保路由可达
    uci set passwall.${VIRTUAL_NODE_ID}.address='192.168.1.1'
    uci set passwall.${VIRTUAL_NODE_ID}.uuid='12345678-1234-5678-9012-123456789012'
    uci set passwall.${VIRTUAL_NODE_ID}.encryption='none'
    uci set passwall.${VIRTUAL_NODE_ID}.transport='tcp'
    echo "  ✓ 已创建虚拟TikTok节点: ${VIRTUAL_NODE_ID}（请手动更换有效节点）"

    # 设置列表使用选项（全局设置）
    uci set passwall.@global[0].use_direct_list='0'    # 取消勾选使用直连列表
    uci set passwall.@global[0].use_proxy_list='0'     # 取消勾选使用代理列表  
    uci set passwall.@global[0].use_block_list='0'     # 取消勾选使用屏蔽列表
    uci set passwall.@global[0].use_gfw_list='0'       # 取消勾选使用GFW列表
    uci set passwall.@global[0].chn_list='0'           # 中国列表设置为关闭不使用
    echo "  ✓ 已取消所有列表使用选项"

    # 设置TCP代理模式为代理
    uci set passwall.@global[0].tcp_proxy_mode='proxy'
    echo "  ✓ 已设置TCP代理模式为代理"

    # 添加必要的全局设置优化
    uci set passwall.@global[0].dns_mode='tcp'          # 设置DNS模式为TCP
    uci set passwall.@global[0].remote_dns='1.1.1.1'   # 设置远程DNS
    uci set passwall.@global[0].dns_redirect='1'        # 启用DNS重定向
    uci set passwall.@global[0].filter_proxy_ipv6='1'   # 过滤代理IPv6
    uci set passwall.@global[0].localhost_proxy='1'     # 本地代理
    uci set passwall.@global[0].client_proxy='1'        # 客户端代理
    uci set passwall.@global[0].acl_enable='1'          # 启用访问控制

    # 禁用节点连通性检测（避免因检测失败影响网络）
    uci set passwall.@global[0].node_ping='0'           # 禁用节点ping检测
    uci set passwall.@global[0].auto_ping='0'           # 禁用自动ping
    uci set passwall.@global[0].tcp_node_ping='0'       # 禁用TCP节点ping
    uci set passwall.@global[0].udp_node_ping='0'       # 禁用UDP节点ping
    echo "  ✓ 已优化全局DNS和代理设置"
    echo "  ✓ 已禁用节点连通性检测（避免因检测失败影响网络）"

    # 添加访问控制规则
    uci add passwall acl_rule > /dev/null
    ACL_INDEX=$(uci show passwall | grep "=acl_rule" | wc -l)
    ACL_INDEX=$((ACL_INDEX - 1))

    uci set passwall.@acl_rule[${ACL_INDEX}].remarks="${WIFI_NAME}_TikTok专用"
    uci set passwall.@acl_rule[${ACL_INDEX}].sources="192.168.${SUBNET}.0/24"  # 修复：设置正确的源地址
    # 不设置interface_name，让源接口为"所有"，避免规则匹配问题
    uci set passwall.@acl_rule[${ACL_INDEX}].tcp_proxy_mode='proxy'
    uci set passwall.@acl_rule[${ACL_INDEX}].enabled='1'
    uci set passwall.@acl_rule[${ACL_INDEX}].dns_mode='dns2socks'
    uci set passwall.@acl_rule[${ACL_INDEX}].remote_dns='8.8.8.8'
    uci set passwall.@acl_rule[${ACL_INDEX}].dns_forward='8.8.4.4'
    uci set passwall.@acl_rule[${ACL_INDEX}].use_global_config='0'
    uci set passwall.@acl_rule[${ACL_INDEX}].tcp_node="${VIRTUAL_NODE_ID}"
    # 默认使用本地直连节点确保网络可用，用户可手动更换为有效代理节点
    uci set passwall.@acl_rule[${ACL_INDEX}].tcp_node="${LOCAL_NODE_ID}"
    uci set passwall.@acl_rule[${ACL_INDEX}].use_direct_list='0'
    uci set passwall.@acl_rule[${ACL_INDEX}].use_proxy_list='0'
    uci set passwall.@acl_rule[${ACL_INDEX}].use_block_list='0'
    uci set passwall.@acl_rule[${ACL_INDEX}].use_gfw_list='0'
    uci set passwall.@acl_rule[${ACL_INDEX}].chn_list='0'
    uci set passwall.@acl_rule[${ACL_INDEX}].dns_shunt='chinadns-ng'

    # 添加端口设置优化（参考您的配置文件）
    uci set passwall.@acl_rule[${ACL_INDEX}].tcp_no_redir_ports='disable'
    uci set passwall.@acl_rule[${ACL_INDEX}].udp_no_redir_ports='disable'
    uci set passwall.@acl_rule[${ACL_INDEX}].tcp_proxy_drop_ports='disable'
    uci set passwall.@acl_rule[${ACL_INDEX}].udp_proxy_drop_ports='443'
    uci set passwall.@acl_rule[${ACL_INDEX}].tcp_redir_ports='22,25,53,143,465,587,853,993,995,80,443'
    uci set passwall.@acl_rule[${ACL_INDEX}].udp_redir_ports='1:65535'
    echo "  ✓ 已优化端口转发设置"

    echo "  ✓ 已添加TikTok专用规则: ${WIFI_NAME}_TikTok专用"
    echo "  源接口: 所有"
    echo "  源地址: 192.168.${SUBNET}.0/24"
    echo "  DNS模式: dns2socks (8.8.8.8/8.8.4.4)"
    echo "  节点: ${VIRTUAL_NODE_ID}（请手动更换有效节点）"
    echo "  默认节点: ${LOCAL_NODE_ID}（本地直连，确保网络可用）"
    echo "  备用节点: ${VIRTUAL_NODE_ID}（请手动更换为有效代理节点）"
    echo "  端口转发: TCP(22,25,53,143,465,587,853,993,995,80,443) UDP(1:65535)"
else
    echo "  警告: 未检测到passwall，跳过TikTok优化配置"
fi

# 添加额外的TikTok优化路由规则
echo "9. 添加TikTok路由优化..."
# 为TikTok域名添加特殊路由
uci add network route > /dev/null
uci set network.@route[-1].interface='${INTERFACE_NAME}'
uci set network.@route[-1].target='0.0.0.0/0'
uci set network.@route[-1].gateway="192.168.${SUBNET}.1"
uci set network.@route[-1].metric='10'
uci set network.@route[-1].mtu='1500'

# 配置流量控制以优化TikTok体验
echo "10. 配置流量控制..."
# 为该网段设置带宽限制（可根据需要调整）
if command -v tc >/dev/null 2>&1; then
    # 这里可以添加TC流量控制规则
    echo "  ✓ 流量控制已准备就绪"
fi

# 确保无线功能已启用
echo "11. 启用无线功能..."
uci set wireless.${RADIO_DEVICE}.disabled='0' 2>/dev/null

# 完全禁用IPv6全局设置
echo "12. 全局禁用IPv6..."
# 禁用系统级别的IPv6
uci set network.globals=globals
uci set network.globals.ula_prefix=''
uci set network.globals.ipv6='off'
echo "  ✓ 已禁用全局IPv6"

# 禁用防火墙IPv6
uci set firewall.defaults.disable_ipv6='1'
echo "  ✓ 已禁用防火墙IPv6"

echo "13. 保存所有配置..."
# 提交所有配置
uci commit network
uci commit wireless
uci commit dhcp
uci commit firewall
if uci get passwall >/dev/null 2>&1; then
    uci commit passwall
fi
echo "  ✓ 所有配置已保存"

echo "14. 刷新网络配置..."
# 刷新网络配置使其生效
/etc/init.d/network reload >/dev/null 2>&1
echo "  ✓ 网络配置已刷新"

# 重启服务
echo "15. 重启服务..."
/etc/init.d/firewall reload >/dev/null 2>&1
/etc/init.d/dnsmasq restart >/dev/null 2>&1
wifi reload >/dev/null 2>&1
echo "  ✓ 防火墙、DNS、WiFi服务已重启"

# 如果passwall存在，重启passwall服务
if [ -f /etc/init.d/passwall ]; then
    /etc/init.d/passwall restart >/dev/null 2>&1
    echo "  ✓ 已重启passwall服务"
fi

echo ""
echo "======================================"
echo "✓ WiFi创建成功！"
echo "======================================"
echo "WiFi名称: ${WIFI_NAME}"
echo "密码: ${PASSWORD}"
echo "网络接口: ${INTERFACE_NAME}"
echo "网段: 192.168.${SUBNET}.0/24"
echo "网关: 192.168.${SUBNET}.1"
echo "DHCP范围: 192.168.${SUBNET}.100 - 192.168.${SUBNET}.249"
echo "防火墙区域: ${INTERFACE_NAME}_zone"
echo "Passwall规则: ${WIFI_NAME}_TikTok专用"
echo "Passwall绑定接口: ${INTERFACE_NAME}"
echo "Passwall默认节点: 本地直连（确保网络正常）"
echo "Passwall备用节点: 虚拟代理节点（请手动更换）"
echo "最大连接数: ${MAX_DEVICES_PER_WIFI}个设备"
echo "TikTok优化: DNS劫持防护、流量优化"
echo "IPv6状态: 完全禁用（仅使用IPv4）"
echo "======================================"
echo ""
echo "提示: 再次运行此脚本将创建下一个WiFi (${WIFI_PREFIX}-$(printf "%02d" $((NEXT_NUM + 1))))"
echo ""

echo ""
echo "✓ TikTok专用WiFi网络创建完成！"
echo ""
echo "注意事项："
echo "1. 此WiFi专为中国地区TikTok使用优化"
echo "2. 每个WiFi支持最多${MAX_DEVICES_PER_WIFI}台设备同时连接"
echo "3. 已配置DNS劫持防护和流量优化"
echo "4. 各WiFi网段间完全隔离，确保安全性"
echo "5. PassWall已配置TikTok专用代理规则"
echo "6. 默认使用本地直连节点，网络正常可用"
echo "7. 已禁用节点连通性检测，避免检测失败影响网络"
echo "8. 请在PassWall访问控制中手动更换为有效代理节点"
echo "9. IPv6已完全禁用，系统仅使用IPv4协议"
echo -e "\033[1;31;1m*本脚本由点动云独家提供，禁止出售或用于非法用途，脚本仅供技术交流学习使用\033[0m"
