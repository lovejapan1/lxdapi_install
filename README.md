# Sakura API Install

Sakura API 安装仓库，支持 Debian/Ubuntu。

面板界面显示为 `服务器`，但 WHMCS 对接接口保持不变，API 路径仍然是 `/api/system/containers`，不要改这个接口路径。

## 后台登录地址

安装完成后访问：

```text
https://服务器IP:8443/admin/login
```

例如：

```text
https://1.2.3.4:8443/admin/login
```

## 一键安装/管理菜单

推荐使用这个入口，里面可以选择完整安装、单独安装、更新、卸载：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/install_all.sh)
```

菜单功能：

```text
1. 一键完整安装（LXD + Sakura 面板 + 导入镜像）
2. 只安装/配置 LXD
3. 只安装 Sakura 面板
4. 导入 LXD 镜像
5. 更新 Sakura 面板
6. 卸载 Sakura 面板
0. 退出
```

也可以直接带参数执行：

```bash
# 一键完整安装
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/install_all.sh) install

# 只安装 LXD
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/install_all.sh) lxd

# 只安装面板
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/install_all.sh) panel

# 导入镜像
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/install_all.sh) image

# 更新面板
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/install_all.sh) update

# 卸载面板
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/install_all.sh) uninstall
```

## 单独脚本

安装并配置 LXD：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/lxd_install.sh)
```

安装 Sakura 面板：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/lxdapi_install.sh)
```

导入镜像：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/image_import.sh)
```

更新面板二进制：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/lxdapi_update.sh)
```

卸载 Sakura 面板：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lovejapan1/lxdapi_install/main/lxdapi_uninstall.sh)
```

卸载脚本只删除 Sakura/LXDAPI 面板，不删除 LXD、镜像和已创建的服务器。默认会询问是否备份 `/opt/lxdapi`。

## WHMCS API 对接插件

插件文件：`WHMCS API对接插件.tar.gz`

安装路径：将插件上传至服务器的 `/modules/servers` 目录。

接口配置：导航至 `系统设置 > 产品/服务 > 服务器`，添加新服务器并填写以下信息：

```text
名称: 按需填写
主机名: 填写后端服务的 IP 或域名
最大账户数: 按需填写
模块: WHMCS-LXD对接插件 by xkatld
访问哈希: 填写后端 Hash
安全: 开启SSL
端口: 填写后端服务端口
```

API 测试命令：

```bash
curl -k -H "X-API-Hash: YOUR_API_KEY" https://127.0.0.1:8443/api/system/containers
```

公网测试：

```bash
curl -k -H "X-API-Hash: YOUR_API_KEY" https://服务器IP:8443/api/system/containers
```

正常返回示例：

```json
{"code":200,"msg":"success","data":[]}
```

## 支付宝 WHMCS 支付插件

插件文件：`WHMSC支付宝插件.zip`

目录结构：

```text
modules/
├── gateways/
│   ├── alipaywhmcs.php            # 主模块文件
│   ├── alipay-whmcs/
│   │   └── config.php             # 配置文件
│   └── callback/
│       └── alipay_callback.php    # 回调处理文件
```

安装步骤：开始前需要在 `https://b.alipay.com/page/product-mall/all-product` 签约“当面付”和“电脑网站支付”。

文件部署：将 `gateways` 目录下的所有文件复制到 WHMCS 根目录对应位置，确保文件权限正确，建议 `755`。

获取支付宝配置：登录支付宝开放平台 `https://open.alipay.com`，创建应用并获取应用 ID（APPID）、商户私钥（RSA2 私钥）、支付宝公钥。

WHMCS 后台配置：登录 WHMCS 管理后台，进入 `设置 -> 支付网关`，找到“支付宝支付”并激活，填写支付宝应用 ID、商户私钥、支付宝公钥。测试环境请勾选“测试模式”。

配置回调地址：

```text
异步通知地址(Notify URL): https://你的域名/modules/gateways/callback/alipay_callback.php
```

使用说明：测试环境开启测试模式，使用支付宝沙箱账号测试并验证支付流程和订单状态。正式环境关闭测试模式，使用正式支付宝账号测试并确认回调正常工作。

系统要求：PHP 7.0+、WHMCS 7.0+、OpenSSL 扩展。

安全建议：使用 HTTPS 协议，妥善保管私钥，定期检查日志，开启 WHMCS 两步验证。

常见问题：订单状态未更新时检查回调地址配置、服务器防火墙和系统日志；签名验证失败时确认密钥格式正确并验证密钥对应关系。

## 注意事项

- ACME 默认关闭，因为纯 IP 安装经常无法通过证书验证。
- 浏览器提示自签名证书不安全是正常的；WHMCS 对接一般使用跳过证书验证。
- 安装脚本会创建 `/usr/local/bin/lxc` 指向 `/snap/bin/lxc`。
- systemd 服务已经包含 `/snap/bin` 到 `PATH`，避免 API 找不到 `lxc`。
- 不要把 API 路径里的 `containers` 改成别的名字，只改界面显示文字。
- 卸载面板不会删除 LXD、镜像、存储池和已创建的服务器。

## 文件说明

- `install_all.sh`: 一键安装/管理菜单入口。
- `lxd_install.sh`: LXD 安装、网络和存储配置脚本。
- `lxdapi_install.sh`: Sakura 面板安装脚本。
- `lxdapi_update.sh`: Sakura 面板更新脚本。
- `lxdapi_uninstall.sh`: Sakura 面板卸载脚本。
- `image_import.sh`: LXD 镜像导入脚本。
- `debian_zfs.sh`: Debian OpenZFS 编译安装辅助脚本。
- `lxdapi-linux-amd64.tar.gz`: amd64 面板包，由 GitHub Actions 生成。
- `lxdapi-linux-arm64.tar.gz`: arm64 面板包，由 GitHub Actions 生成。
- `WHMCS API对接插件.tar.gz`: WHMCS API 对接插件包。
- `WHMSC支付宝插件.zip`: 支付宝 WHMCS 支付插件包。
- `.github/workflows/rebuild-packages.yml`: 面板包重建工作流。
