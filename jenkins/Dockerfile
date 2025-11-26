# 基于官方 Jenkins LTS 镜像作为基础
FROM jenkins/jenkins:lts

# 切换到 root 用户以执行安装操作
USER root

# 安装必要的工具：curl, gnupg2, software-properties-common
# ca-certificates 确保 HTTPS 证书能被正确识别
RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# 下载并安装 kubectl
# 这个脚本会自动检测系统架构（amd64/arm64）并下载对应版本
RUN ARCH=$(dpkg --print-architecture) && \
    curl -LO "https://dl.k8s.io/release/$(curl -LSs https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl" && \
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && \
    rm kubectl  # 删除下载的安装包以减小镜像体积

# 验证 kubectl 安装是否成功
RUN kubectl version --client

# 切换回 jenkins 用户，这是 Jenkins 服务运行的默认用户
USER jenkins

# 可选：安装一些常用的 Jenkins 插件
# 这会在容器启动时自动安装插件，节省手动安装时间
RUN jenkins-plugin-cli --plugins \
    kubernetes-cli \
    kubernetes \
    git \
    workflow-aggregator \
    credentials-binding \
    docker-workflow
