#!/bin/sh

# 智能5G WiFi创建脚本 - 每次执行创建一个新的WiFi
# WiFi名称格式: TikTok-01, TikTok-02, ...

WIFI_PREFIX="TikTok"
PASSWORD="123456789"

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

# 配置DHCP
echo "2. 配置DHCP服务..."
uci set dhcp.${INTERFACE_NAME}=dhcp
uci set dhcp.${INTERFACE_NAME}.interface="${INTERFACE_NAME}"
uci set dhcp.${INTERFACE_NAME}.start='100'
uci set dhcp.${INTERFACE_NAME}.limit='150'
uci set dhcp.${INTERFACE_NAME}.leasetime='12h'
uci set dhcp.${INTERFACE_NAME}.dhcpv4='server'
# 添加DNS设置以避免DNS泄露
uci add_list dhcp.${INTERFACE_NAME}.dhcp_option="6,8.8.8.8,8.8.4.4"

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

# 设置5G特定参数
uci set wireless.@wifi-iface[-1].ieee80211w='1'  # 启用管理帧保护
uci set wireless.@wifi-iface[-1].ieee80211k='1'  # 启用无线资源管理
uci set wireless.@wifi-iface[-1].ieee80211r='1'  # 启用快速漫游
uci set wireless.@wifi-iface[-1].ieee80211v='1'  # 启用BSS转换

# 添加TikTok优化参数
uci set wireless.@wifi-iface[-1].maxassoc='1'     # 限制只允许1个设备连接
uci set wireless.@wifi-iface[-1].disassoc_low_ack='0'  # 禁用低确认断开

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

# 配置passwall访问控制 - 修复版本
echo "8. 配置passwall访问控制..."
if uci get passwall >/dev/null 2>&1; then
    # 添加访问控制规则
    uci add passwall acl_rule > /dev/null
    ACL_INDEX=$(uci show passwall | grep "=acl_rule" | wc -l)
    ACL_INDEX=$((ACL_INDEX - 1))
    
    uci set passwall.@acl_rule[${ACL_INDEX}].remarks="${WIFI_NAME}_访问控制"
    uci set passwall.@acl_rule[${ACL_INDEX}].sources="192.168.${SUBNET}.0/24"
    
    # 关键修复：正确设置接口名
    # 使用网络接口名而不是WiFi设备名
    uci set passwall.@acl_rule[${ACL_INDEX}].interface_name="${INTERFACE_NAME}"
    
    # 设置代理模式
    uci set passwall.@acl_rule[${ACL_INDEX}].tcp_proxy_mode='global'  # 全局代理
    uci set passwall.@acl_rule[${ACL_INDEX}].udp_proxy_mode='global'  # UDP也代理
    uci set passwall.@acl_rule[${ACL_INDEX}].enabled='1'
    
    # 如果有默认节点，设置节点
    DEFAULT_NODE=$(uci get passwall.@global[0].tcp_node 2>/dev/null)
    if [ ! -z "$DEFAULT_NODE" ]; then
        uci set passwall.@acl_rule[${ACL_INDEX}].tcp_node="$DEFAULT_NODE"
        uci set passwall.@acl_rule[${ACL_INDEX}].udp_node="$DEFAULT_NODE"
        echo "  ✓ 已设置默认节点: $DEFAULT_NODE"
    fi
    
    echo "  ✓ 已添加passwall访问控制规则: ${WIFI_NAME}_访问控制"
    echo "  源地址: 192.168.${SUBNET}.0/24"
    echo "  绑定接口: ${INTERFACE_NAME}"
else
    echo "  警告: 未检测到passwall，跳过访问控制配置"
fi

# 确保无线功能已启用
echo "9. 启用无线功能..."
uci set wireless.${RADIO_DEVICE}.disabled='0' 2>/dev/null

# 提交所有配置
echo "10. 提交配置..."
uci commit network
uci commit wireless
uci commit dhcp
uci commit firewall
if uci get passwall >/dev/null 2>&1; then
    uci commit passwall
fi

# 重启服务
echo "11. 重启服务..."
/etc/init.d/network reload >/dev/null 2>&1
/etc/init.d/firewall reload >/dev/null 2>&1
/etc/init.d/dnsmasq restart >/dev/null 2>&1
wifi reload >/dev/null 2>&1

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
echo "Passwall规则: ${WIFI_NAME}_访问控制"
echo "Passwall绑定接口: ${INTERFACE_NAME}"
echo "最大连接数: 1个设备"
echo "======================================"
echo ""
echo "提示: 再次运行此脚本将创建下一个WiFi (${WIFI_PREFIX}-$(printf "%02d" $((NEXT_NUM + 1))))"
echo ""

# 创建状态查看命令
cat > /tmp/show_wifi_list.sh << 'SCRIPT_END'
#!/bin/sh
echo "======================================"
echo "已配置的WiFi列表"
echo "======================================"
count=0
for section in $(uci show wireless | grep "=wifi-iface" | cut -d'.' -f2 | cut -d'=' -f1); do
    ssid=$(uci get wireless.${section}.ssid 2>/dev/null)
    if echo "$ssid" | grep -q "^TikTok-"; then
        count=$((count + 1))
        network=$(uci get wireless.${section}.network 2>/dev/null)
        if [ ! -z "$network" ]; then
            ip=$(uci get network.${network}.ipaddr 2>/dev/null)
            echo "$count. $ssid"
            echo "   网络接口: $network"
            echo "   网段: $ip/24"
            echo "   防火墙区域: ${network}_zone"
            
            # 检查设备连接数
            maxassoc=$(uci get wireless.${section}.maxassoc 2>/dev/null)
            if [ ! -z "$maxassoc" ]; then
                echo "   最大连接数: $maxassoc"
            fi
            
            # 检查passwall规则
            if uci get passwall >/dev/null 2>&1; then
                for acl_section in $(uci show passwall | grep "=acl_rule" | cut -d'.' -f2 | cut -d'=' -f1); do
                    remarks=$(uci get passwall.${acl_section}.remarks 2>/dev/null)
                    if [ "$remarks" = "${ssid}_访问控制" ]; then
                        interface_name=$(uci get passwall.${acl_section}.interface_name 2>/dev/null)
                        tcp_node=$(uci get passwall.${acl_section}.tcp_node 2>/dev/null)
                        echo "   Passwall规则: ${ssid}_访问控制"
                        echo "   Passwall接口: ${interface_name:-未设置}"
                        if [ ! -z "$tcp_node" ]; then
                            echo "   使用节点: $tcp_node"
                        fi
                        break
                    fi
                done
            fi
            
            # 显示当前连接的客户端
            echo -n "   当前连接设备: "
            connected=0
            if command -v iwinfo >/dev/null 2>&1; then
                for iface in $(iwinfo | grep "ESSID: \"$ssid\"" -B1 | grep -v ESSID | awk '{print $1}'); do
                    clients=$(iwinfo $iface assoclist 2>/dev/null | grep -c "dBm")
                    if [ $clients -gt 0 ]; then
                        connected=$clients
                    fi
                done
            fi
            echo "$connected 个"
            echo ""
        else
            echo "$count. $ssid (配置不完整)"
        fi
    fi
done
if [ $count -eq 0 ]; then
    echo "没有找到TikTok系列WiFi"
fi
echo "======================================"
echo ""
echo "提示："
echo "1. 每个WiFi限制只能连接1个设备"
echo "2. 各WiFi网段之间完全隔离"
echo "3. 通过Passwall可为每个WiFi设置不同的代理节点"
echo "======================================"
SCRIPT_END

chmod +x /tmp/show_wifi_list.sh

# 创建删除WiFi的脚本
cat > /tmp/delete_wifi.sh << 'DELETE_SCRIPT'
#!/bin/sh

if [ -z "$1" ]; then
    echo "用法: $0 <WiFi编号>"
    echo "例如: $0 01  (删除TikTok-01)"
    exit 1
fi

WIFI_NUM="$1"
WIFI_NAME="TikTok-${WIFI_NUM}"
INTERFACE_NAME="tiktok$(echo $WIFI_NUM | sed 's/^0*//')"

echo "准备删除WiFi: $WIFI_NAME"
echo "对应接口: $INTERFACE_NAME"
echo ""

# 删除wireless配置
for section in $(uci show wireless | grep "=wifi-iface" | cut -d'.' -f2 | cut -d'=' -f1); do
    ssid=$(uci get wireless.${section}.ssid 2>/dev/null)
    if [ "$ssid" = "$WIFI_NAME" ]; then
        echo "删除WiFi配置: $section"
        uci delete wireless.${section}
    fi
done

# 删除network接口
if uci get network.${INTERFACE_NAME} >/dev/null 2>&1; then
    echo "删除网络接口: $INTERFACE_NAME"
    uci delete network.${INTERFACE_NAME}
fi

# 删除DHCP配置
if uci get dhcp.${INTERFACE_NAME} >/dev/null 2>&1; then
    echo "删除DHCP配置: $INTERFACE_NAME"
    uci delete dhcp.${INTERFACE_NAME}
fi

# 删除防火墙区域和规则
for section in $(uci show firewall | grep "name='${INTERFACE_NAME}" | cut -d'.' -f2 | cut -d'=' -f1); do
    echo "删除防火墙配置: $section"
    uci delete firewall.${section}
done

# 删除passwall规则
if uci get passwall >/dev/null 2>&1; then
    for section in $(uci show passwall | grep "=acl_rule" | cut -d'.' -f2 | cut -d'=' -f1); do
        remarks=$(uci get passwall.${section}.remarks 2>/dev/null)
        if [ "$remarks" = "${WIFI_NAME}_访问控制" ]; then
            echo "删除Passwall规则: $section"
            uci delete passwall.${section}
        fi
    done
    uci commit passwall
fi

# 提交配置
uci commit wireless
uci commit network
uci commit dhcp
uci commit firewall

# 重启服务
/etc/init.d/network reload
/etc/init.d/firewall reload
/etc/init.d/dnsmasq restart
wifi reload

echo ""
echo "✓ 已删除WiFi: $WIFI_NAME"
DELETE_SCRIPT

chmod +x /tmp/delete_wifi.sh

echo "查看所有WiFi列表: /tmp/show_wifi_list.sh"
echo "删除指定WiFi: /tmp/delete_wifi.sh <编号>"
