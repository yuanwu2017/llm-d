# kgateway 版本兼容性问题修复指南

## 问题根因

在部署 llm-d PD disaggregation 时遇到了以下版本兼容性问题：

### 1. BackendTLSPolicy CRD 版本冲突

| 组件 | 版本 | BackendTLSPolicy |
|------|------|------------------|
| Gateway API v1.4.0 | v1 | 只支持 `v1` |
| Gateway API v1.2.0 | v1alpha3 | 支持 `v1alpha3` |
| kgateway v2.1.1 | 需要 v1alpha3 | ❌ 与 v1.4.0 不兼容 |

**症状**：kgateway 日志报错 `BackendTLSPolicy.gateway.networking.k8s.io "xxx" not found`

### 2. BackendConfigPolicy CRD 缺失

kgateway v2.1.1 需要 `backendconfigpolicies.gateway.kgateway.dev` CRD，这需要 kgateway-crds v2.1.1。

**症状**：kgateway 启动时报 CRD 不存在

### 3. 脚本安装顺序问题

`install-gateway-provider-dependencies.sh` 只安装 Gateway API CRDs，但不安装 kgateway-crds。
当用户先运行该脚本（安装 v1.4.0），再用 helmfile 安装 kgateway 时，版本就冲突了。

## 解决方案

### 方案 A：修改 Gateway API 版本

将 `install-gateway-provider-dependencies.sh` 中的版本从 `v1.4.0` 改为 `v1.2.0`：

```bash
# 原来
GATEWAY_API_CRD_REVISION=${GATEWAY_API_CRD_REVISION:-"v1.4.0"}

# 改为
GATEWAY_API_CRD_REVISION=${GATEWAY_API_CRD_REVISION:-"v1.2.0"}
```

### 方案 B：使用一体化安装脚本

使用新创建的 `fix-kgateway-versions.sh` 脚本：

```bash
# 1. 清理旧组件
./fix-kgateway-versions.sh clean

# 2. 安装兼容版本
./fix-kgateway-versions.sh install
```

## 兼容版本矩阵

经过测试，以下版本组合是兼容的：

| 组件 | 推荐版本 |
|------|----------|
| Gateway API CRDs | v1.2.0 |
| Gateway API Inference Extension | v1.2.0 |
| kgateway | v2.1.1 |
| kgateway-crds | v2.1.1 |

## 验证方法

```bash
# 检查 BackendTLSPolicy 版本
kubectl get crd backendtlspolicies.gateway.networking.k8s.io -o jsonpath='{.spec.versions[*].name}'
# 应该包含 v1alpha3

# 检查 BackendConfigPolicy
kubectl get crd backendconfigpolicies.gateway.kgateway.dev
# 应该存在

# 检查 InferencePool
kubectl get crd inferencepools.inference.networking.k8s.io
# 应该存在

# 检查 kgateway 日志
kubectl logs -n kgateway-system deploy/kgateway --tail=20
# 不应有 CRD 相关错误
```

## 清理和重新部署步骤

```bash
# 1. 删除 llm-d-pd namespace
export NAMESPACE=llm-d-pd
helmfile -e hpu destroy
kubectl delete namespace $NAMESPACE --ignore-not-found

# 2. 清理 kgateway 组件
./fix-kgateway-versions.sh clean

# 3. 重新安装兼容版本
./fix-kgateway-versions.sh install

# 4. 部署 llm-d PD
cd /home/ubuntu/yuanwu/llm-d/guides/pd-disaggregation
NAMESPACE=llm-d-pd helmfile -e hpu apply
kubectl apply -f httproute.yaml -n $NAMESPACE

# 5. 测试
kubectl port-forward -n $NAMESPACE svc/infra-pd-inference-gateway 8080:80 &
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B", "messages": [{"role": "user", "content": "Hello"}], "max_tokens": 30}'
```
