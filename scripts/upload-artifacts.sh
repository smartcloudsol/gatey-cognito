#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS_BUCKET="${ARTIFACTS_BUCKET:-wpsuite-artifacts}"
AWS_REGION="${AWS_REGION:-us-east-1}"
APP_NAME="${APP_NAME:-wpsuite-cognito}"
S3_PREFIX="${S3_PREFIX:-wpsuite-cognito}"
GIT_SHA="${GIT_SHA:-$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo 'latest')}"
VERSION="${VERSION:-}"
ARTIFACT_VERSION="${ARTIFACT_VERSION:-${VERSION:-$GIT_SHA}}"
UPDATE_LATEST=false
FORCE_BUILD="${FORCE_BUILD:-false}"
FUNCTIONS=(custom-resource pre-signup pre-token-generation post-confirmation custom-email-sender)

while [[ $# -gt 0 ]]; do
  case $1 in
    --update-latest) UPDATE_LATEST=true; shift ;;
    --force-build) FORCE_BUILD=true; shift ;;
    --help|-h) echo "Usage: $0 [--update-latest] [--force-build]"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

print_status() { echo -e "${GREEN}✅ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; exit 1; }

command -v aws >/dev/null 2>&1 || print_error "aws CLI is not installed"

require_local_artifacts() {
  local required=(
    "$ROOT_DIR/.artifacts/custom-resource.zip"
    "$ROOT_DIR/.artifacts/pre-signup.zip"
    "$ROOT_DIR/.artifacts/pre-token-generation.zip"
    "$ROOT_DIR/.artifacts/post-confirmation.zip"
    "$ROOT_DIR/.artifacts/custom-email-sender.zip"
    "$ROOT_DIR/.artifacts/layers/cognito-common-layer.zip"
    "$ROOT_DIR/template.yaml"
    "$ROOT_DIR/SAR-README.md"
    "$ROOT_DIR/LICENSE"
  )
  local missing=false
  for file in "${required[@]}"; do
    if [ ! -f "$file" ]; then
      missing=true
      break
    fi
  done
  if [ "$FORCE_BUILD" = true ] || [ "$missing" = true ]; then
    print_info "Building artifacts before upload"
    bash "$ROOT_DIR/scripts/build.sh"
  fi
}

FULL_PREFIX="$S3_PREFIX/$ARTIFACT_VERSION"
LATEST_PREFIX="$S3_PREFIX/latest"

upload_tree() {
  local prefix="$1"
  print_info "Uploading artifacts to s3://$ARTIFACTS_BUCKET/$prefix/"
  aws s3 cp "$ROOT_DIR/template.yaml" "s3://$ARTIFACTS_BUCKET/$prefix/template.yaml" --region "$AWS_REGION"
  [ -f "$ROOT_DIR/README.md" ] && aws s3 cp "$ROOT_DIR/README.md" "s3://$ARTIFACTS_BUCKET/$prefix/docs/README.md" --region "$AWS_REGION" || true
  aws s3 cp "$ROOT_DIR/SAR-README.md" "s3://$ARTIFACTS_BUCKET/$prefix/docs/SAR-README.md" --region "$AWS_REGION"
  aws s3 cp "$ROOT_DIR/LICENSE" "s3://$ARTIFACTS_BUCKET/$prefix/docs/LICENSE" --region "$AWS_REGION"
  for func in "${FUNCTIONS[@]}"; do
    local file="$ROOT_DIR/.artifacts/${func}.zip"
    [ -f "$file" ] || print_error "Missing artifact: $file"
    aws s3 cp "$file" "s3://$ARTIFACTS_BUCKET/$prefix/functions/${func}.zip" --region "$AWS_REGION"
  done
  local layer_file="$ROOT_DIR/.artifacts/layers/cognito-common-layer.zip"
  [ -f "$layer_file" ] || print_error "Missing layer artifact: $layer_file"
  aws s3 cp "$layer_file" "s3://$ARTIFACTS_BUCKET/$prefix/layers/cognito-common-layer.zip" --region "$AWS_REGION"
  if [ -d "$ROOT_DIR/templates" ]; then
    aws s3 cp "$ROOT_DIR/templates/" "s3://$ARTIFACTS_BUCKET/$prefix/templates/" --recursive --region "$AWS_REGION"
  else
    print_warning "templates/ directory not found, skipping template upload"
  fi
  print_status "Artifacts uploaded to s3://$ARTIFACTS_BUCKET/$prefix/"
}

require_local_artifacts
upload_tree "$FULL_PREFIX"
if [ "$UPDATE_LATEST" = true ]; then
  upload_tree "$LATEST_PREFIX"
fi

print_info "Using bucket: $ARTIFACTS_BUCKET"
print_info "Using app name: $APP_NAME"
print_info "Using prefix: $S3_PREFIX"
print_info "Using artifact version: $ARTIFACT_VERSION"
