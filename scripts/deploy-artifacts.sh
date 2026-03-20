#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STACK_NAME="${STACK_NAME:-wpsuite-cognito-dev}"
ARTIFACTS_BUCKET="${ARTIFACTS_BUCKET:-wpsuite-artifacts}"
AWS_REGION="${AWS_REGION:-us-east-1}"
APP_NAME="${APP_NAME:-wpsuite-cognito}"
S3_PREFIX="${S3_PREFIX:-wpsuite-cognito}"
GIT_SHA="${GIT_SHA:-$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo 'latest')}"
VERSION="${VERSION:-}"
ARTIFACT_VERSION="${ARTIFACT_VERSION:-${VERSION:-$GIT_SHA}}"
AUTO_UPLOAD_ARTIFACTS="${AUTO_UPLOAD_ARTIFACTS:-true}"

print_info(){ echo -e "${BLUE}ℹ️  $1${NC}"; }
print_status(){ echo -e "${GREEN}✅ $1${NC}"; }
print_error(){ echo -e "${RED}❌ $1${NC}"; exit 1; }

[ -f "$ROOT_DIR/template.yaml" ] || print_error "template.yaml not found"
command -v aws >/dev/null 2>&1 || print_error "aws CLI is not installed"

if [ "$AUTO_UPLOAD_ARTIFACTS" = "true" ]; then
  print_info "Ensuring versioned artifacts are uploaded before deploy"
  ARTIFACTS_BUCKET="$ARTIFACTS_BUCKET" AWS_REGION="$AWS_REGION" APP_NAME="$APP_NAME" S3_PREFIX="$S3_PREFIX" VERSION="$VERSION" ARTIFACT_VERSION="$ARTIFACT_VERSION" bash "$ROOT_DIR/scripts/upload-artifacts.sh"
fi

print_info "Deploying stack $STACK_NAME from template.yaml"
print_info "Artifact version: $ARTIFACT_VERSION"
aws cloudformation deploy \
  --region "$AWS_REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$ROOT_DIR/template.yaml" \
  --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND \
  --parameter-overrides \
    DeploymentVersion="$ARTIFACT_VERSION" \
    ArtifactBucketName="$ARTIFACTS_BUCKET" \
    ArtifactKeyPrefix="$S3_PREFIX" \
    AppName="$APP_NAME"

print_status "Deployment submitted for $STACK_NAME"
