#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LAYER_ROOT="$ROOT_DIR/layers/cognito-common"
LAYER_DIR="$LAYER_ROOT/nodejs"
ARTIFACT_DIR="$ROOT_DIR/.artifacts/layers"

rm -rf "$LAYER_ROOT"
mkdir -p "$LAYER_DIR" "$ARTIFACT_DIR"

echo -e "${BLUE}🏗️  Building Cognito common Lambda layer...${NC}"

cat > "$LAYER_DIR/package.json" <<'JSON'
{
  "name": "wpsuite-cognito-common-layer",
  "version": "1.0.0",
  "private": true,
  "description": "Shared dependencies for WP Suite Cognito SAR handlers",
  "dependencies": {
    "@aws-sdk/client-cognito-identity-provider": "^3.987.0",
    "@aws-sdk/client-cognito-identity": "^3.987.0",
    "@aws-sdk/client-route-53": "^3.987.0",
    "@aws-sdk/client-s3": "^3.987.0",
    "@aws-sdk/client-sesv2": "^3.987.0",
    "@aws-sdk/client-ssm": "^3.987.0",
    "@aws-sdk/client-lambda": "^3.987.0",
    "@aws-sdk/client-kms": "^3.987.0",
    "@aws-sdk/client-cloudformation": "^3.987.0",
    "@aws-sdk/client-sts": "^3.987.0"
  }
}
JSON

(
  cd "$LAYER_DIR"
  npm install --production --no-optional --silent
)

(
  cd "$LAYER_ROOT"
  zip -q -r "$ARTIFACT_DIR/cognito-common-layer.zip" nodejs
)

echo -e "${GREEN}✅ Layer built: $ARTIFACT_DIR/cognito-common-layer.zip${NC}"
rm -rf "$LAYER_ROOT"
echo -e "${GREEN}✅ Cleaned up temporary layer sources${NC}"
