bash <(curl -sL https://raw.githubusercontent.com/afoim/hy2/refs/heads/main/hy2-quick.sh)

带自定义参数的：

# 指定端口和SNI
curl -sL https://raw.githubusercontent.com/afoim/hy2/refs/heads/main/hy2-quick.sh | HY2_PORT=443 HY2_SNI=www.microsoft.com bash

# 指定带宽上限 (适合小带宽机器)
curl -sL https://raw.githubusercontent.com/afoim/hy2/refs/heads/main/hy2-quick.sh | HY2_UP="200 mbps" HY2_DOWN="200 mbps" bash

# 激进模式：忽略客户端报告，服务端全力推
curl -sL https://raw.githubusercontent.com/afoim/hy2/refs/heads/main/hy2-quick.sh | HY2_IGNORE_CLIENT_BW=true bash
