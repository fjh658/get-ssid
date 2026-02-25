# get-ssid — 在 **不打开定位（TCC）** 的情况下读取 macOS 的 Wi‑Fi SSID

[English](./README.md) | **中文**

> 🧩 **目标**：在 macOS 11+（含“macOS 26”）上，在**不启用定位权限**（TCC）、**不依赖定位受限 CLI** 的前提下，输出当前 Wi‑Fi 的 SSID。

---

## 概览 ✨

在新版 macOS 中，许多 SSID 获取途径都被 **定位权限（TCC）** 限制。关闭定位后，这些工具会**隐藏**或**拒绝**返回 SSID。**get‑ssid** 会先走不依赖定位授权的 CoreWLAN/IORegistry 路径，再在必要时把当前网络环境与**系统已知网络**数据库做**关联匹配**来推断 SSID。

**要点**  
- 不用 CoreLocation / 外部命令。  
- 组合使用 CoreWLAN（实时/配置）、IORegistry、SystemConfiguration（DHCP/Router）。  
- known‑networks plist 仅作为最后兜底，若当前用户不可读则可能需要 `sudo`。

---

## 常见方法为何失败 🔎

### 1) `airport`（旧 Apple80211 工具）
```bash
/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -i

zsh: no such file or directory: /System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport
```
- ❌ **关键问题**：在新系统中传统路径/二进制已移除或位置变化；即使存在包装器，SSID 通常也被定位权限（TCC）拦截。

### 2) `networksetup -getairportnetwork en0`
```bash
/usr/sbin/networksetup -getairportnetwork en0
You are not associated with an AirPort network.
```
- ❌ **关键问题**：定位关闭时，底层 API **拒绝暴露** 关联/SSID，统一返回 *未关联*，即使实际上已连接。

### 3) `wdutil info`（Wi‑Fi 诊断）
```bash
sudo wdutil info
…
WIFI
  Interface Name : en0
  Power          : On
  Op Mode        : STA
  SSID           : <redacted>
  BSSID          : <redacted>
```
- ❌ **关键问题**：未授权定位时，诊断工具会**打码** SSID。

### 4) `system_profiler SPAirPortDataType -json`
```bash
/usr/sbin/system_profiler SPAirPortDataType -detailLevel basic -json
{
  "SPAirPortDataType" : [
    {
      "spairport_airport_interfaces" : [
        {
          "_name" : "en0",
          …
          "spairport_current_network_information" : {
            "_name" : "<redacted>"
```
- ❌ **关键问题**：`system_profiler` 遵循隐私策略，在定位关闭时**打码** JSON 输出中的 SSID。

---

## 实现原理 🧠

- **默认路径（当前 macOS）：**  
  1) 优先走 CoreWLAN 实时关联（`CWInterface.ssid()`）；  
  2) 退化到 CoreWLAN 配置（`networkProfiles`）；  
  3) 再退化到接口范围 IORegistry SSID 键（`IO80211SSID_STR` / `IO80211SSID` / `SSID_STR`）；  
  4) 最后兜底：用 SystemConfiguration（DHCP/Router）与 `/Library/Preferences/com.apple.wifi.known-networks.plist` 做相关性推断。  
- **仅 known-networks 阶段：**进行候选打分，并以**最近关联时间**打破并列。
- **当 CoreWLAN 不可用时：**直接回退到接口范围 IORegistry 查询。
- 优先级策略：默认优先非提权路径；只有必要时才走 known-networks 兼容兜底。

---

## 构建 ⚙️

> 需安装 Xcode Command Line Tools；源码文件：`get_ssid.swift`

```bash
# 推荐：通过 Makefile 构建通用二进制
make universal

# 运行测试（单元 + 集成）
make test
```

---

## 🍺 Homebrew Tap 安装

Homebrew 安装会使用 `dist/` 中的预编译包，不会在用户机器上编译。

本地把当前仓库作为 tap：

```bash
brew tap fjh658/get-ssid /path/to/get-ssid
brew install get-ssid
```

从 GitHub tap 安装：

```bash
brew tap fjh658/get-ssid https://github.com/fjh658/get-ssid.git
brew install get-ssid
```

发布前刷新预编译包：

```bash
make package
```

`make package` 还会基于 `Formula/get-ssid.rb.tmpl` 自动刷新 `Formula/get-ssid.rb`，并注入当前版本（来自 `get_ssid.swift`）与 tarball 的 `sha256`。

---

## 安装与提权 📦

通过 Homebrew 安装后，直接运行 `get-ssid` 即可。
在当前 macOS API 行为不变的前提下，不需要 `sudo`。

只有你明确需要 known-networks 兜底，且系统 plist 对当前用户不可读时，才按需重试一次 `sudo`：

```bash
get-ssid en0
# 若确实需要兜底：
sudo get-ssid en0
```

---

## 使用方法 🚀

```bash
# 默认：自动选择活跃 Wi‑Fi 服务
get-ssid
# MyWiFi-5G

# 严格绑定到指定接口（例如 en0）
get-ssid en0
# MyWiFi-5G

# 帮助 / 版本
get-ssid --help
get-ssid --version
```

**行为说明**  
- 显式传入**非 Wi‑Fi 接口**（strict 模式）：返回 `error: interface '<iface>' is not a Wi-Fi interface (strict mode)`，退出码 `2`。  
- Wi‑Fi 接口但当前未关联：输出 `Unknown (not associated)`，退出码 `0`（非错误）。  
- **不存在的接口名**：退出码 `3`。  
- **用法错误**：退出码 `2`。

**退出码**
| Code | 含义                               |
|-----:|------------------------------------|
| 0    | 成功（含 “Unknown …”）             |
| 1    | 内部安全错误                       |
| 2    | 用法错误                           |
| 3    | 接口不存在（显式指定时）           |

---

## 安全与隐私 🔐

- 打开系统 plist 时使用 **`O_NOFOLLOW`** 并校验属主；读取后**立即降权**。  
- 避免解析不受信路径；最好使用硬编码绝对路径。  
- 若对外分发，建议配合沙箱。

---

## 局限 ⚠️

- 这些限制仅在 `networkProfiles`/IORegistry 未能给出 SSID、且工具进入 known-networks 相关性兜底时才会触发。  
- 在该兜底阶段，若当前网络**未保存**到系统“已知网络”，或 DHCP/Router 特征**不具区分度**，推断可能失败。  
- Apple 未来可能调整 plist 格式/字段，这会影响该兜底路径。

---

## 许可证 📝

MIT — 请保留版权与许可文本。

---

## 致谢 🙏

- Apple SystemConfiguration、IOKit 与 macOS Wi‑Fi 栈。  
- 社区对 Wi‑Fi 诊断与 known‑networks 的研究。
