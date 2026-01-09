#!/bin/bash
# -*- indent-tabs-mode: nil; tab-width: 2; sh-indentation: 2; -*-
#
# 修复 kgateway 和 Gateway API 版本兼容性问题
# 
# 问题描述：
# 1. kgateway v2.1.1 需要 BackendTLSPolicy v1alpha3，但 Gateway API v1.4.0 只提供 v1
# 2. kgateway v2.1.1 需要 BackendConfigPolicy CRD，这需要 kgateway-crds v2.1.1
# 3. Gateway API Inference Extension v1.2.0 与 kgateway v2.1.1 兼容
#
# 解决方案：
# - 使用 Gateway API v1.2.0（包含 v1alpha3 的 BackendTLSPolicy）
# - 升级 kgateway-crds 到 v2.1.1
# - 升级 kgateway 到 v2.1.1

set -e
set -o pipefail

# 颜色输出
COLOR_RESET=$'\e[0m'
COLOR_GREEN=$'\e[32m'
COLOR_RED=$'\e[31m'
COLOR_YELLOW=$'\e[33m'
COLOR_BLUE=$'\e[34m'

log_info() {
  echo "${COLOR_BLUE}ℹ️  $*${COLOR_RESET}"
}

log_success() {
  echo "${COLOR_GREEN}✅ $*${COLOR_RESET}"
}

log_warning() {
  echo "${COLOR_YELLOW}⚠️  $*${COLOR_RESET}"
}

log_error() {
  echo "${COLOR_RED}❌ $*${COLOR_RESET}" >&2
}

# 版本配置 - 这些版本经过测试是兼容的
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.2.0}"
GATEWAY_API_INFERENCE_EXTENSION_VERSION="${GATEWAY_API_INFERENCE_EXTENSION_VERSION:-v1.2.0}"
KGATEWAY_VERSION="${KGATEWAY_VERSION:-v2.1.1}"

MODE=${1:-install}

echo "=================================================="
echo "  kgateway 版本修复脚本"
echo "=================================================="
echo ""
echo "版本配置："
echo "  - Gateway API CRDs: ${GATEWAY_API_VERSION}"
echo "  - Inference Extension CRDs: ${GATEWAY_API_INFERENCE_EXTENSION_VERSION}"
echo "  - kgateway: ${KGATEWAY_VERSION}"
echo ""

if [[ "$MODE" == "clean" || "$MODE" == "delete" ]]; then
  echo "🧹 清理模式"
  echo ""
  
  log_info "1. 删除 kgateway..."
  helm uninstall kgateway -n kgateway-system 2>/dev/null || log_warning "kgateway 未安装"
  
  log_info "2. 删除 kgateway-crds..."
  helm uninstall kgateway-crds -n kgateway-system 2>/dev/null || log_warning "kgateway-crds 未安装"
  
  log_info "3. 删除 kgateway-system namespace..."
  kubectl delete namespace kgateway-system --ignore-not-found=true 2>/dev/null || true
  
  log_info "4. 删除 Gateway API CRDs..."
  kubectl delete -k "https://github.com/kubernetes-sigs/gateway-api/config/crd?ref=${GATEWAY_API_VERSION}" 2>/dev/null || true
  
  log_info "5. 删除 Inference Extension CRDs..."
  kubectl delete -k "https://github.com/kubernetes-sigs/gateway-api-inference-extension/config/crd?ref=${GATEWAY_API_INFERENCE_EXTENSION_VERSION}" 2>/dev/null || true
  
  log_info "6. 清理残留的 kgateway CRDs..."
  kubectl delete crd backends.gateway.kgateway.dev 2>/dev/null || true
  kubectl delete crd directresponses.gateway.kgateway.dev 2>/dev/null || true
  kubectl delete crd gatewayextensions.gateway.kgateway.dev 2>/dev/null || true
  kubectl delete crd gatewayparameters.gateway.kgateway.dev 2>/dev/null || true
  kubectl delete crd httplistenerpolicies.gateway.kgateway.dev 2>/dev/null || true
  kubectl delete crd trafficpolicies.gateway.kgateway.dev 2>/dev/null || true
  kubectl delete crd backendconfigpolicies.gateway.kgateway.dev 2>/dev/null || true
  
  log_success "清理完成！"
  echo ""
  echo "现在可以运行: $0 install"
  exit 0
fi

if [[ "$MODE" == "install" ]]; then
  echo "📦 安装模式"
  echo ""
  
  # Step 1: 安装 Gateway API CRDs (使用 v1.2.0 以获得 v1alpha3 的 BackendTLSPolicy)
  log_info "1. 安装 Gateway API CRDs (${GATEWAY_API_VERSION})..."
  kubectl apply -k "https://github.com/kubernetes-sigs/gateway-api/config/crd?ref=${GATEWAY_API_VERSION}" || {
    log_error "安装 Gateway API CRDs 失败"
    exit 1
  }
  log_success "Gateway API CRDs 安装完成"
  
  # Step 2: 安装 Inference Extension CRDs
  log_info "2. 安装 Gateway API Inference Extension CRDs (${GATEWAY_API_INFERENCE_EXTENSION_VERSION})..."
  kubectl apply -k "https://github.com/kubernetes-sigs/gateway-api-inference-extension/config/crd?ref=${GATEWAY_API_INFERENCE_EXTENSION_VERSION}" || {
    log_error "安装 Inference Extension CRDs 失败"
    exit 1
  }
  log_success "Inference Extension CRDs 安装完成"
  
  # Step 3: 创建 kgateway-system namespace
  log_info "3. 创建 kgateway-system namespace..."
  kubectl create namespace kgateway-system --dry-run=client -o yaml | kubectl apply -f -
  
  # Step 4: 安装/升级 kgateway-crds
  log_info "4. 安装 kgateway-crds (${KGATEWAY_VERSION})..."
  helm upgrade --install kgateway-crds \
    oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds \
    --version "${KGATEWAY_VERSION}" \
    -n kgateway-system \
    --wait || {
    log_error "安装 kgateway-crds 失败"
    exit 1
  }
  log_success "kgateway-crds 安装完成"
  
  # Step 5: 安装/升级 kgateway
  log_info "5. 安装 kgateway (${KGATEWAY_VERSION})..."
  helm upgrade --install kgateway \
    oci://cr.kgateway.dev/kgateway-dev/charts/kgateway \
    --version "${KGATEWAY_VERSION}" \
    -n kgateway-system \
    --set inferenceExtension.enabled=true \
    --wait --timeout=120s || {
    log_error "安装 kgateway 失败"
    exit 1
  }
  log_success "kgateway 安装完成"
  
  # Step 6: 验证安装
  echo ""
  log_info "6. 验证安装..."
  
  echo ""
  echo "📋 CRD 检查："
  echo "  BackendTLSPolicy 版本:"
  kubectl get crd backendtlspolicies.gateway.networking.k8s.io -o jsonpath='{.spec.versions[*].name}' 2>/dev/null || echo "  未安装"
  echo ""
  echo "  BackendConfigPolicy:"
  kubectl get crd backendconfigpolicies.gateway.kgateway.dev 2>/dev/null && echo "  ✅ 已安装" || echo "  ❌ 未安装"
  echo ""
  echo "  InferencePool:"
  kubectl get crd inferencepools.inference.networking.k8s.io 2>/dev/null && echo "  ✅ 已安装" || echo "  ❌ 未安装"
  echo ""
  
  echo "📋 kgateway Pod 状态："
  kubectl get pods -n kgateway-system
  echo ""
  
  log_success "安装完成！"
  echo ""
  echo "现在可以部署 llm-d PD："
  echo "  cd /home/ubuntu/yuanwu/llm-d/guides/pd-disaggregation"
  echo "  NAMESPACE=llm-d-pd helmfile -e hpu apply"
  echo "  kubectl apply -f httproute.yaml -n llm-d-pd"
  
  exit 0
fi

echo "用法: $0 [install|clean]"
echo "  install - 安装/升级所有组件（默认）"
echo "  clean   - 清理所有组件"
exit 1
