### 默认安装

```bash
bash <(curl -sL https://raw.githubusercontent.com/afoim/hy2/refs/heads/main/hy2-quick.sh)
```

### 自定义端口和 SNI

```bash
curl -sL https://raw.githubusercontent.com/afoim/hy2/refs/heads/main/hy2-quick.sh | HY2_PORT=443 HY2_SNI=www.microsoft.com bash
```

### 限制带宽上限（适用于小带宽机器）

```bash
curl -sL https://raw.githubusercontent.com/afoim/hy2/refs/heads/main/hy2-quick.sh | HY2_UP="200 mbps" HY2_DOWN="200 mbps" bash
```

---

### 🚀 最终推荐命令（忽略客户端配置，全部拉满，默认伪装）

```bash
bash <(curl -sL https://raw.githubusercontent.com/afoim/hy2/refs/heads/main/hy2-quick.sh)
```
