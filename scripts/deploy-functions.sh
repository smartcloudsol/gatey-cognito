#!/usr/bin/env bash
# Deploy all Lambda functions from .artifacts folder
# Usage: ./scripts/deploy-functions.sh <function-prefix>

# Szigor: undef var, pipefail — de NEM használunk -e-t (errexit)
set -uo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if prefix is provided
if [ -z "${1:-}" ]; then
  echo -e "${RED}❌ Error: Function prefix is required${NC}"
  echo ""
  echo "Usage: $0 <function-prefix>"
  echo ""
  echo "Example: $0 wpscognito"
  echo ""
  exit 1
fi

# Configuration
FUNCTION_PREFIX="$1"
ARTIFACTS_DIR=".artifacts"
LAYER_NAME="${FUNCTION_PREFIX}-common"
LAYER_ZIP="${ARTIFACTS_DIR}/layers/cognito-common-layer.zip"

echo -e "${BLUE}🚀 Deploying Lambda Layer and Functions${NC}"
echo "=================================="
echo ""
echo "Function Prefix: ${FUNCTION_PREFIX}-"
echo "Layer Name: ${LAYER_NAME}"
echo "Artifacts Directory: ${ARTIFACTS_DIR}"
echo ""

# Check if artifacts directory exists
if [ ! -d "$ARTIFACTS_DIR" ]; then
  echo -e "${RED}❌ Error: Artifacts directory not found: $ARTIFACTS_DIR${NC}"
  echo "Please run 'BUILD_MODE=readable bash scripts/build.sh' first"
  exit 1
fi

# Function mapping: zip file name -> Lambda function name
declare -A FUNCTION_MAP=(
  ["custom-email-sender"]="custom-email-sender"
  ["custom-resource"]="custom-resource"
  ["post-confirmation"]="post-confirmation"
  ["pre-signup"]="pre-signup"
  ["pre-token-generation"]="pre-token-generation"
)

# Cross-platform file size helper (echo bytes or 0)
file_size_bytes() {
  local p="$1"
  # Linux (GNU coreutils)
  if size=$(stat -c%s "$p" 2>/dev/null); then
    echo "$size"; return 0
  fi
  # macOS / BSD
  if size=$(stat -f%z "$p" 2>/dev/null); then
    echo "$size"; return 0
  fi
  echo 0
}

DEPLOYED=0
FAILED=0
SKIPPED=0

# Deploy Lambda Layer first
echo -e "${BLUE}📦 Deploying Lambda Layer${NC}"
echo "=================================="
echo ""

if [ ! -f "$LAYER_ZIP" ]; then
  echo -e "${YELLOW}⚠️  Warning: Layer artifact not found: $LAYER_ZIP${NC}"
  echo "   Skipping layer deployment"
  LAYER_VERSION=""
else
  layer_size=$(file_size_bytes "$LAYER_ZIP")
  layer_size_mb=$(awk -v s="$layer_size" 'BEGIN{ if (s+0==0) {printf "0.00"} else {printf "%.2f", s/1024/1024} }')
  
  echo -e "${BLUE}📦 Publishing new layer version: $LAYER_NAME${NC}"
  echo "   Artifact: $LAYER_ZIP (${layer_size_mb}MB)"
  
  layer_result="$(
    aws lambda publish-layer-version \
      --layer-name "$LAYER_NAME" \
      --zip-file "fileb://$LAYER_ZIP" \
      --compatible-runtimes nodejs24.x \
      --compatible-architectures arm64 \
      --output json \
      --query '{LayerVersionArn: LayerVersionArn, Version: Version}' 2>&1
  )"
  layer_status=$?
  
  if [ $layer_status -eq 0 ]; then
    echo -e "${GREEN}   ✅ Layer published successfully${NC}"
    if command -v jq >/dev/null 2>&1; then
      LAYER_VERSION=$(echo "$layer_result" | jq -r '.Version' 2>/dev/null)
      LAYER_ARN=$(echo "$layer_result" | jq -r '.LayerVersionArn' 2>/dev/null)
      echo "   Version: $LAYER_VERSION"
      echo "   ARN: $LAYER_ARN"
    else
      echo "   $layer_result"
      LAYER_VERSION=""
    fi
  else
    echo -e "${RED}   ❌ Layer deployment failed${NC}"
    echo "   $layer_result"
    LAYER_VERSION=""
  fi
  echo ""
fi

echo "=================================="
echo -e "${BLUE}📦 Deploying Lambda Functions${NC}"
echo "=================================="
echo ""

# Deploy each function
for zip_file in custom-email-sender custom-resource post-confirmation pre-signup pre-token-generation; do
  func_name="${FUNCTION_MAP[$zip_file]}"
  full_func_name="${FUNCTION_PREFIX}-${func_name}"
  zip_path="${ARTIFACTS_DIR}/${zip_file}.zip"

  if [ ! -f "$zip_path" ]; then
    echo -e "${YELLOW}⚠️  Skipping $full_func_name: $zip_path not found${NC}"
    SKIPPED=$((SKIPPED+1))
    echo ""
    continue
  fi

  file_size=$(file_size_bytes "$zip_path")
  # .00 formátumú MB
  file_size_mb=$(awk -v s="$file_size" 'BEGIN{ if (s+0==0) {printf "0.00"} else {printf "%.2f", s/1024/1024} }')

  echo -e "${BLUE}📦 Deploying $full_func_name${NC}"
  echo "   Artifact: $zip_path (${file_size_mb}MB)"

  # Futtassuk az aws parancsot, FOGJUK MEG a kimenetet és a státuszt
  result="$(
    aws lambda update-function-code \
      --function-name "$full_func_name" \
      --zip-file "fileb://$zip_path" \
      --output json \
      --query '{FunctionName: FunctionName, LastModified: LastModified, CodeSize: CodeSize, Runtime: Runtime}' 2>&1
  )"
  status=$?

  if [ $status -eq 0 ]; then
    echo -e "${GREEN}   ✅ Deployed successfully${NC}"
    # jq lehet nincs telepítve / nem json => ne dőljünk el miatta
    if command -v jq >/dev/null 2>&1; then
      echo "$result" | jq -r '"   Last Modified: \(.LastModified)\n   Code Size: \(.CodeSize) bytes\n   Runtime: \(.Runtime)"' 2>/dev/null || echo "   $result"
    else
      echo "   $result"
    fi
    DEPLOYED=$((DEPLOYED+1))
    
    # Update layer if new version was published
    if [ -n "$LAYER_VERSION" ] && [ -n "$LAYER_ARN" ]; then
      echo -e "${BLUE}   🔄 Updating layer to version $LAYER_VERSION${NC}"
      
      # Wait for function to be ready and retry layer update
      max_retries=10
      retry_count=0
      update_success=false
      
      while [ $retry_count -lt $max_retries ]; do
        update_result="$(
          aws lambda update-function-configuration \
            --function-name "$full_func_name" \
            --layers "$LAYER_ARN" \
            --output json \
            --query '{FunctionName: FunctionName, LastModified: LastModified}' 2>&1
        )"
        update_status=$?
        
        if [ $update_status -eq 0 ]; then
          echo -e "${GREEN}   ✅ Layer updated${NC}"
          update_success=true
          break
        elif echo "$update_result" | grep -q "ResourceConflictException"; then
          retry_count=$((retry_count+1))
          if [ $retry_count -lt $max_retries ]; then
            echo -e "${YELLOW}   ⏳ Waiting for function to be ready (attempt $retry_count/$max_retries)...${NC}"
            sleep 2
          fi
        else
          # Other error, don't retry
          break
        fi
      done
      
      if [ "$update_success" = false ]; then
        echo -e "${YELLOW}   ⚠️  Layer update failed after $retry_count attempts (function code deployed successfully)${NC}"
        if [ $retry_count -lt $max_retries ]; then
          echo "   $update_result"
        fi
      fi
    fi
  else
    echo -e "${RED}   ❌ Deployment failed${NC}"
    echo "   $result"
    FAILED=$((FAILED+1))
  fi

  echo ""
done

# Summary
echo "=================================="
echo -e "${BLUE}📊 Deployment Summary${NC}"
echo "=================================="
echo -e "${GREEN}✅ Deployed: $DEPLOYED${NC}"
if [ $FAILED -gt 0 ]; then
  echo -e "${RED}❌ Failed: $FAILED${NC}"
fi
if [ $SKIPPED -gt 0 ]; then
  echo -e "${YELLOW}⚠️  Skipped: $SKIPPED${NC}"
fi
echo ""

# Exit code a gyűjtött státusz alapján
if [ $FAILED -gt 0 ]; then
  echo -e "${RED}❌ Some deployments failed!${NC}"
  exit 1
else
  echo -e "${GREEN}🎉 All deployments completed successfully!${NC}"
  exit 0
fi
