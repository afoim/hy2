```bash
bash <(curl -sL https://raw.githubusercontent.com/afoim/hy2/refs/heads/main/hy2-quick.sh)
```

```bash
curl -sL https://raw.githubusercontent.com/afoim/hy2/refs/heads/main/hy2-quick.sh | HY2_PORT=443 HY2_SNI=www.microsoft.com bash
```

```bash
curl -sL https://raw.githubusercontent.com/afoim/hy2/refs/heads/main/hy2-quick.sh | HY2_UP="200 mbps" HY2_DOWN="200 mbps" bash
```

```bash
curl -sL https://raw.githubusercontent.com/afoim/hy2/refs/heads/main/hy2-quick.sh | HY2_IGNORE_CLIENT_BW=true bash
```
