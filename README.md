# Sakura LXDAPI Install

Sakura LXDAPI 一键安装仓库，支持 Debian/Ubuntu。面板界面尽量把“容器”显示为“服务器”，但 WHMCS/API 对接接口保持原版兼容，接口路径里的 `containers` 不要改。

## 一键安装

新服务器推荐直接执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/install_all.sh) install
```

这个命令会自动完成：

- 安装并初始化 LXD
- 安装 Sakura/LXDAPI 面板
- 导入 LXD 镜像
- 自动识别公网网卡，例如 `eth0`、`ens3`、`enp3s0`
- 自动配置 `lxdbr0`、IP 转发、入站端口转发和出站 NAT
- 安装 `sakura-lxdapi-repair.timer`，重启后也会自动补 NAT/SSH 规则

## 管理命令

```bash
# 打开菜单
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/install_all.sh)

# 完整安装：LXD + 面板 + 镜像
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/install_all.sh) install

# 只安装 LXD
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/install_all.sh) lxd

# 只安装面板
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/install_all.sh) panel

# 只导入镜像
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/install_all.sh) image

# 更新面板
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/install_all.sh) update

# 修复 NAT/SSH/面板文字/背景图/自定义公网端口
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/install_all.sh) fix

# 卸载面板，不删除 LXD 和已创建服务器
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/install_all.sh) uninstall
```

## 后台登录地址

安装完成后访问：

```text
https://服务器IP:8443/admin/login
```

示例：

```text
https://1.2.3.4:8443/admin/login
```

默认使用自签名证书，浏览器提示“不安全”是正常现象。WHMCS 对接时开启 SSL，模块一般会跳过证书验证。

## 修复已有安装

如果已经安装过，只想修复 NAT、SSH、网卡识别、面板文字、背景图 UI、ACME 卡死或自定义公网端口问题，执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/install_all.sh) fix
```

修复后可检查：

```bash
systemctl status sakura-lxdapi-repair.timer --no-pager
nft list ruleset | grep -E 'sakura_lxdapi_nat|sakura_lxdapi_snat|masquerade'
iptables -t nat -S POSTROUTING | grep MASQUERADE
```

## NAT 和端口转发说明

脚本会自动识别真实公网网卡，不需要手动写死 `eth0` 或 `enp3s0`。如果旧规则里残留不存在的网卡，`fix` 会自动清理，并只保留当前系统真实存在的出口网卡。

自动修复内容：

- 开启 `net.ipv4.ip_forward=1`
- 开启 LXD `lxdbr0` 的 `ipv4.nat` 和 `ipv4.dhcp`
- 为 LXD 网段添加出站 `MASQUERADE`
- 镜像面板创建的入站 DNAT 规则，避免旧网卡名导致端口连不上
- 自动启动服务器内的 SSH 服务
- 每 30 秒由 `sakura-lxdapi-repair.timer` 自动补规则

端口映射里：

- `公网端口` 是外部访问端口，留空时随机分配。
- `服务端口` 是服务器内部端口，例如 SSH 是 `22`，网站是 `80`。
- 手动自定义公网端口现在放开到 `1-65535`。
- 旧规则如果创建后无效，请先删除旧规则，再重新添加。

服务器内测试外网：

```bash
lxc exec 服务器名 -- sh -lc 'ip route; wget -T 15 -O- https://raw.githubusercontent.com 2>&1 | head'
```

## 品牌和背景图

`fix` 会修复后台品牌设置里的背景图透明度逻辑。现在 UI 里的“背景透明度 100%”表示背景图完全显示，“0%”表示白色遮罩最强。

旧环境执行 `fix` 后，需要在后台品牌设置里重新点一次保存，旧背景图设置才会按新逻辑写入。

## WHMCS API 对接插件

插件文件：`WHMCS API对接插件.tar.gz`

安装路径：将插件上传至 WHMCS 服务器的 `/modules/servers` 目录。

接口配置路径：

```text
系统设置 > 产品/服务 > 服务器
```

添加新服务器并填写：

```text
名称: 按需填写
主机名: 填写后端服务的 IP 或域名
最大账户数: 按需填写
模块: WHMCS-LXD对接插件 by xkatld
访问哈希: 填写后端 Hash
安全: 开启SSL
端口: 填写后端服务端口，例如 8443
```

API 测试：

```bash
curl -k -H "X-API-Hash: YOUR_API_HASH" https://127.0.0.1:8443/api/system/containers
curl -k -H "X-API-Hash: YOUR_API_HASH" https://服务器IP:8443/api/system/containers
```

正常返回示例：

```json
{"code":200,"msg":"success","data":[]}
```

注意：WHMCS 插件对接接口仍然使用 `/api/system/containers`，不要把接口里的 `containers` 改成 `servers`。

## 支付宝 WHMCS 支付插件

插件文件：`WHMSC支付宝插件.zip`

目录结构：

```text
modules/
├── gateways/
│   ├── alipaywhmcs.php
│   ├── alipay-whmcs/
│   │   └── config.php
│   └── callback/
│       └── alipay_callback.php
```

安装前需要在支付宝签约“当面付”和“电脑网站支付”：

```text
https://b.alipay.com/page/product-mall/all-product
```

安装步骤：

1. 将 `gateways` 目录下所有文件复制到 WHMCS 根目录对应位置
2. 建议文件权限设置为 `755`
3. 登录支付宝开放平台 `https://open.alipay.com`
4. 创建应用并获取 APPID、商户 RSA2 私钥、支付宝公钥
5. 登录 WHMCS 后台，进入 `设置 -> 支付网关`
6. 激活“支付宝支付”并填写 APPID、商户私钥、支付宝公钥
7. 测试环境勾选“测试模式”

回调地址：

```text
https://你的域名/modules/gateways/callback/alipay_callback.php
```

系统要求：

- PHP 7.0+
- WHMCS 7.0+
- OpenSSL 扩展
- 推荐使用 HTTPS

常见问题：

- 订单状态未更新：检查回调地址、防火墙和 WHMCS 系统日志
- 签名验证失败：确认密钥格式、应用 ID、公钥和私钥对应关系

## 单独脚本

```bash
# 安装 LXD
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/lxd_install.sh)

# 安装面板
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/lxdapi_install.sh)

# 更新面板
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/lxdapi_update.sh)

# 导入镜像
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/image_import.sh)

# 卸载面板
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/lxdapi_uninstall.sh)
```

## 注意事项

- `install_all.sh install` 是推荐入口，适合新服务器直接安装。
- `install_all.sh fix` 适合已有服务器修复网络、端口转发、SSH 和面板环境。
- ACME 默认关闭，避免纯 IP 安装时证书申请卡住。
- 卸载面板不会删除 LXD、镜像、存储池和已创建服务器。
- 只修改界面显示文字，API 路径和 WHMCS 对接字段保持原版兼容。

## 文件说明

- `install_all.sh`: 一键安装/管理入口
- `lxd_install.sh`: LXD 安装和初始化
- `lxdapi_install.sh`: Sakura/LXDAPI 面板安装
- `lxdapi_update.sh`: 面板更新
- `lxdapi_uninstall.sh`: 面板卸载
- `image_import.sh`: LXD 镜像导入
- `lxdapi-linux-amd64.tar.gz`: amd64 面板包
- `lxdapi-linux-arm64.tar.gz`: arm64 面板包
- `WHMCS API对接插件.tar.gz`: WHMCS API 对接插件
- `WHMSC支付宝插件.zip`: 支付宝 WHMCS 支付插件
