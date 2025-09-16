# get-ssid — 在 **不打开定位（TCC）** 的情况下读取 macOS 的 Wi‑Fi SSID

[English](./README.md) | **中文**

> 🧩 **目标**：在 macOS 11+（含“macOS 26”）上，在**不启用定位权限**、**不依赖** CoreLocation/CoreWLAN/外部命令的前提下，输出当前 Wi‑Fi 的 SSID。

---

## 概览 ✨

在新版 macOS 中，许多 SSID 获取途径都被 **定位权限（TCC）** 限制。关闭定位后，这些工具会**隐藏**或**拒绝**返回 SSID。**get‑ssid** 不调用会触发 TCC 的 API，而是把当前网络环境与**系统已知网络**数据库进行**关联匹配**来推断 SSID。

**要点**  
- 不用 CoreLocation / CoreWLAN / 外部命令。  
- 利用 SystemConfiguration（DHCP/Router）+ 系统 known‑networks plist；可选从 IORegistry 读取信道作加分项。  
- 读取系统级 plist 需要 **root** → 每次 **`sudo`** 或**一次性 setuid**。

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

- **macOS ≥ 11**（含“macOS 26”）：  
  1) 读取系统级 `/Library/Preferences/com.apple.wifi.known-networks.plist`；  
  2) 从 **SystemConfiguration** 获取当前环境：  
     - DHCP **ServerIdentifier**（强匹配）  
     - `IPv4NetworkSignature` 中的 **Router**（中匹配）  
     - 可选：从 **IORegistry** 读取 **channel**（加分项）  
  3) 候选打分；以**最近关联时间**打破并列，得到 SSID。  
- **macOS ≤ 10**：若可用，回退到 IORegistry（`IO80211SSID_STR` / `SSID_STR`）。

---

## 构建 ⚙️

> 需安装 Xcode Command Line Tools；源码文件：`get_ssid.swift`

```bash
# x86_64 架构（最低 10.13）
xcrun swiftc -parse-as-library -O   -target x86_64-apple-macos10.13   -o /tmp/get-ssid-x86_64 get_ssid.swift

# arm64 架构（最低 11.0）
xcrun swiftc -parse-as-library -O   -target arm64-apple-macos11.0   -o /tmp/get-ssid-arm64 get_ssid.swift

# 合并为通用二进制
lipo -create -output ./get-ssid   /tmp/get-ssid-x86_64 /tmp/get-ssid-arm64

# 若被 Gatekeeper 隔离（可选）
xattr -dr com.apple.quarantine ./get-ssid
```

---

## 安装与提权 📦

读取系统级 plist **必须**有 root。二选一：

### 方案 A — 每次用 `sudo`（简单，推荐）
```bash
sudo ./get-ssid en0
# MyWiFi-5G
```

### 方案 B — 一次性授予 setuid（谨慎）
> ⚠️ 会增加攻击面。请保证二进制最小化、已审计、只读且路径固定。

**你要求的最小命令：**
```bash
sudo chown root ./get-ssid && sudo chmod +s ./get-ssid
./get-ssid en0
# MyWiFi-5G
```

**更规范（安装到 /usr/local/bin）：**
```bash
sudo install -m 0755 get-ssid /usr/local/bin/get-ssid
sudo chown root:wheel /usr/local/bin/get-ssid
sudo chmod u+s /usr/local/bin/get-ssid

get-ssid en0
# MyWiFi-5G
```

---

## 使用方法 🚀

```bash
# 默认：使用主数据接口（Global/IPv4）
sudo ./get-ssid
# MyWiFi-5G

# 严格绑定到指定接口（例如 en0）
sudo ./get-ssid en0
# MyWiFi-5G

# 帮助 / 版本
./get-ssid --help
./get-ssid --version
```

**行为说明**  
- 显式传入**有线接口**：输出 `Unknown (not associated)`，退出码 `0`（非错误）。  
- **不存在的接口名**：退出码 `3`。  
- **用法错误**：退出码 `2`。

**退出码**
| Code | 含义                               |
|-----:|------------------------------------|
| 0    | 成功（含 “Unknown …”）             |
| 2    | 用法错误                           |
| 3    | 接口不存在（显式指定时）           |

---

## 安全与隐私 🔐

- 打开系统 plist 时使用 **`O_NOFOLLOW`** 并校验属主；读取后**立即降权**。  
- 避免解析不受信路径；最好使用硬编码绝对路径。  
- 若对外分发，建议配合沙箱。

---

## 局限 ⚠️

- 当前网络若**未保存**到系统“已知网络”，或 DHCP/Router 特征**不具区分度**，推断可能失败。  
- Apple 未来可能调整 plist 格式/字段，无法保证长期可用。

---

## 许可证 📝

MIT — 请保留版权与许可文本。

---

## 致谢 🙏

- Apple SystemConfiguration、IOKit 与 macOS Wi‑Fi 栈。  
- 社区对 Wi‑Fi 诊断与 known‑networks 的研究。
