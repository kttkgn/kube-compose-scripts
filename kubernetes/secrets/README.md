## nginx 配置 测试一般不需要
1. 生成自签证书 测试用，实际由云服务商提供
```shell
# 生成私钥（server.key），设置密码为123456（测试用，生产环境需用强密码）
openssl genrsa -des3 -out server.key 2048
# 生成证书请求文件（CSR）
openssl req -new -key server.key -out server.csr
# 移除私钥密码（避免Nginx启动时需手动输入密码）
cp server.key server.key.org
openssl rsa -in server.key.org -out server.key
# 生成自签证书（server.crt，有效期365天）
openssl x509 -req -days 365 -in server.csr -signkey server.key -out server.crt
```

2.1 命令行创建 Secrets
```shell

# 创建名为 "nginx-ssl-secrets" 的Secrets，指定证书和私钥路径
kubectl create secret tls nginx-ssl-secrets \
  --cert=./server.crt \  # 证书文件路径（替换为你的实际路径）
  --key=./server.key \   # 私钥文件路径（替换为你的实际路径）
  -n default  # 命名空间，需与Nginx Deployment一致

```
2.2 YAML 文件创建 Secrets
2.2.1 对敏感文件进行 Base64 编码
```shell
# 编码证书文件（server.crt）
cat server.crt | base64 -w 0  # -w 0 表示不换行，输出完整编码值
# 编码私钥文件（server.key）
cat server.key | base64 -w 0
```

2.2.2 编写 Secrets YAML 文件
```
apiVersion: v1
kind: Secret
metadata:
  name: nginx-ssl-secrets  # Secrets名称，需与Deployment挂载时一致
  namespace: default
type: kubernetes.io/tls  # 类型为TLS，K8s会自动识别证书和私钥
data:
  # 证书文件（Base64编码值，替换为步骤1中server.crt的编码结果）
  tls.crt: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUN5RENDQWJDZ0F3SUJBZ0lCQURBTkJna3Foa2lHOXcwQkFRRUZBQVNDQktnd2dnU2tBZ0VBQW9JQkFRQzF...
  # 私钥文件（Base64编码值，替换为步骤1中server.key的编码结果）
  tls.key: LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQpNSUlFcFFJQkFBS0NBUUVBd0VGRWdFS0t3V2dFS0t3V2dETkFOQmdrcWhraUc5dzBCQVFFRkFBT0NBUTh...

```
