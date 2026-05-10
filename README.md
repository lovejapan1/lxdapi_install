# Sakura LXDAPI Install

Sakura 定制版 LXDAPI 安装仓库，支持 Debian/Ubuntu。

面板界面显示为 `服务器`，但 WHMCS 对接接口保持不变，API 路径仍然是 `/api/system/containers`，不要改这个接口路径。

```text
WHMCS对接插件上传目录/modules/servers
```

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

## WHMCS 对接

WHMCS 服务器配置填写：

```text
主机名或 IP: 服务器公网 IP
端口: 8443
访问哈希: 安装脚本输出的 API 密钥
用户名/密码: 按插件要求填写，接口主要使用访问哈希
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

## 注意事项

- ACME 默认关闭，因为纯 IP 安装经常无法通过证书验证。
- 浏览器提示自签名证书不安全是正常的；WHMCS 对接一般使用跳过证书验证。
- 安装脚本会创建 `/usr/local/bin/lxc` 指向 `/snap/bin/lxc`。
- systemd 服务已经包含 `/snap/bin` 到 `PATH`，避免 API 找不到 `lxc`。
- 不要把 API 路径里的 `containers` 改成别的名字，只改界面显示文字。

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
- `.github/workflows/rebuild-packages.yml`: 面板包重建工作流。
