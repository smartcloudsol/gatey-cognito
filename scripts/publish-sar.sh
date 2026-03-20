#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.artifacts"
APP_NAME="${APP_NAME:-wpsuite-cognito}"
VERSION="${VERSION:-1.0.0}"
SAR_REGION="${SAR_REGION:-us-east-1}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ARTIFACTS_BUCKET="${ARTIFACTS_BUCKET:-wpsuite-artifacts}"
S3_PREFIX="${S3_PREFIX:-wpsuite-cognito}"
ARTIFACT_VERSION="${ARTIFACT_VERSION:-$VERSION}"
FULL_PREFIX="$S3_PREFIX/$ARTIFACT_VERSION"
CONFIGURE_BUCKET_POLICY="${CONFIGURE_BUCKET_POLICY:-false}"
BUILD_BEFORE_PUBLISH="${BUILD_BEFORE_PUBLISH:-true}"
UPLOAD_BEFORE_PUBLISH="${UPLOAD_BEFORE_PUBLISH:-true}"
SOURCE_CODE_URL="${SOURCE_CODE_URL:-https://github.com/smartcloudsol/gatey-cognito/}"
HOME_PAGE_URL="${HOME_PAGE_URL:-https://wpsuite.io/gatey/}"
DESCRIPTION="${DESCRIPTION:-Reusable Cognito-based authentication foundation for WP Suite plugins, including Gatey, AI-Kit, and Flow, with optional identity pool, triggers, SES email delivery, and custom domain support.}"
AUTHOR="${AUTHOR:-Smart Cloud Solutions}"
LABELS=(cognito authentication wordpress wpsuite serverless identity user-pool cognito-triggers custom-domain)

print_status(){ echo -e "${GREEN}✅ $1${NC}"; }
print_warning(){ echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error(){ echo -e "${RED}❌ $1${NC}"; exit 1; }
print_info(){ echo -e "${BLUE}ℹ️  $1${NC}"; }

show_config() {
  print_info "SAR publishing configuration:"
  echo "  App Name: $APP_NAME"
  echo "  Version: $VERSION"
  echo "  Artifact Version: $ARTIFACT_VERSION"
  echo "  SAR Region: $SAR_REGION"
  echo "  AWS Region: $AWS_REGION"
  echo "  S3 Bucket: $ARTIFACTS_BUCKET"
  echo "  S3 Prefix: $S3_PREFIX"
  echo "  Build Before Publish: $BUILD_BEFORE_PUBLISH"
  echo "  Upload Before Publish: $UPLOAD_BEFORE_PUBLISH"
  echo "  Configure Bucket Policy: $CONFIGURE_BUCKET_POLICY"
  echo
}

check_prerequisites() {
  command -v aws >/dev/null || print_error "AWS CLI is not installed"
  command -v python3 >/dev/null || print_error "python3 is required"
  aws sts get-caller-identity >/dev/null 2>&1 || print_error "AWS credentials not configured or invalid"
  [ -f "$ROOT_DIR/template.yaml" ] || print_error "template.yaml not found"
}

ensure_local_artifacts() {
  local required=(
    "$ROOT_DIR/.artifacts/custom-resource.zip"
    "$ROOT_DIR/.artifacts/pre-signup.zip"
    "$ROOT_DIR/.artifacts/pre-token-generation.zip"
    "$ROOT_DIR/.artifacts/post-confirmation.zip"
    "$ROOT_DIR/.artifacts/custom-email-sender.zip"
    "$ROOT_DIR/.artifacts/layers/cognito-common-layer.zip"
  )

  local missing=false
  for file in "${required[@]}"; do
    if [ ! -f "$file" ]; then
      missing=true
      break
    fi
  done

  if [ "$BUILD_BEFORE_PUBLISH" = "true" ] || [ "$missing" = true ]; then
    print_info "Building local artifacts"
    bash "$ROOT_DIR/scripts/build.sh"
  fi
}

configure_bucket_policy() {
  [ "$CONFIGURE_BUCKET_POLICY" = "true" ] || return 0
  print_info "Configuring S3 bucket policy for SAR access"
  local tmp_policy="$BUILD_DIR/sar-bucket-policy.json"
  mkdir -p "$BUILD_DIR"
  python3 - "$ARTIFACTS_BUCKET" <<'PY2' > "$tmp_policy"
import json, sys, subprocess
bucket = sys.argv[1]
try:
    current = subprocess.check_output([
        'aws','s3api','get-bucket-policy','--bucket',bucket,'--query','Policy','--output','text'
    ], stderr=subprocess.DEVNULL, text=True).strip()
    policy = json.loads(current) if current and current != 'None' else {"Version":"2012-10-17","Statement":[]}
except Exception:
    policy = {"Version":"2012-10-17","Statement":[]}
new_statements = [
  {"Sid":"AllowServerlessRepoReadDocsShared","Effect":"Allow","Principal":{"Service":"serverlessrepo.amazonaws.com"},"Action":"s3:GetObject","Resource":f"arn:aws:s3:::{bucket}/*/docs/*"},
  {"Sid":"AllowServerlessRepoReadArtifactsShared","Effect":"Allow","Principal":{"Service":"serverlessrepo.amazonaws.com"},"Action":"s3:GetObject","Resource":[f"arn:aws:s3:::{bucket}/*/templates/*",f"arn:aws:s3:::{bucket}/*/functions/*",f"arn:aws:s3:::{bucket}/*/layers/*",f"arn:aws:s3:::{bucket}/*/wrapper/*"]},
  {"Sid":"AllowCloudFormationReadArtifactsShared","Effect":"Allow","Principal":{"Service":"cloudformation.amazonaws.com"},"Action":"s3:GetObject","Resource":[f"arn:aws:s3:::{bucket}/*/templates/*",f"arn:aws:s3:::{bucket}/*/functions/*",f"arn:aws:s3:::{bucket}/*/layers/*",f"arn:aws:s3:::{bucket}/*/wrapper/*"]}
]
by_sid = {s.get('Sid'): s for s in policy.get('Statement', []) if isinstance(s, dict) and s.get('Sid')}
for stmt in new_statements:
    by_sid[stmt['Sid']] = stmt
other = [s for s in policy.get('Statement', []) if not (isinstance(s, dict) and s.get('Sid'))]
policy['Statement'] = other + list(by_sid.values())
print(json.dumps(policy))
PY2
  aws s3api put-bucket-policy --bucket "$ARTIFACTS_BUCKET" --policy file://"$tmp_policy" --region "$AWS_REGION" >/dev/null || print_warning "Failed to update bucket policy"
  rm -f "$tmp_policy"
}

upload_artifacts_if_needed() {
  [ "$UPLOAD_BEFORE_PUBLISH" = "true" ] || return 0
  print_info "Uploading versioned artifacts to S3"
  ARTIFACTS_BUCKET="$ARTIFACTS_BUCKET" AWS_REGION="$AWS_REGION" APP_NAME="$APP_NAME" S3_PREFIX="$S3_PREFIX" ARTIFACT_VERSION="$ARTIFACT_VERSION" VERSION="$VERSION" bash "$ROOT_DIR/scripts/upload-artifacts.sh"
}

upload_documentation_files() {
  aws s3 cp "$ROOT_DIR/LICENSE" "s3://$ARTIFACTS_BUCKET/$FULL_PREFIX/docs/LICENSE" --region "$AWS_REGION" >/dev/null
  aws s3 cp "$ROOT_DIR/SAR-README.md" "s3://$ARTIFACTS_BUCKET/$FULL_PREFIX/docs/SAR-README.md" --region "$AWS_REGION" >/dev/null
  export LICENSE_S3_URL="s3://$ARTIFACTS_BUCKET/$FULL_PREFIX/docs/LICENSE"
  export README_S3_URL="s3://$ARTIFACTS_BUCKET/$FULL_PREFIX/docs/SAR-README.md"
}

generate_sar_template() {
  local input_template="$ROOT_DIR/template.yaml"
  local output_template="$BUILD_DIR/template.sar.yaml"
  mkdir -p "$BUILD_DIR"
  print_info "Generating SAR template: $output_template"
  python3 - "$input_template" "$output_template" "$VERSION" "$ARTIFACTS_BUCKET" "$S3_PREFIX" "$ARTIFACT_VERSION" <<'PY2'
import re, sys
from pathlib import Path
input_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
version = sys.argv[3]
bucket = sys.argv[4]
prefix = sys.argv[5]
artifact_version = sys.argv[6]
text = input_path.read_text(encoding='utf-8')
keys_to_remove = {"DeploymentVersion", "ArtifactBucketName", "ArtifactKeyPrefix"}
lines = text.splitlines(True)
out = []
in_parameters = False
skip_key = None
skip_indent = None
for line in lines:
    stripped = line.lstrip(' ')
    indent = len(line) - len(stripped)
    if indent == 0 and stripped.startswith('Parameters:'):
        in_parameters = True
        out.append(line)
        continue
    if in_parameters and indent == 0 and stripped and not stripped.startswith('#') and not stripped.startswith(' '):
        in_parameters = False
        skip_key = None
        skip_indent = None
    if in_parameters:
        if skip_key is not None:
            if stripped.strip() == '':
                continue
            if indent > skip_indent:
                continue
            skip_key = None
            skip_indent = None
        m = re.match(r'^(\s{2})([A-Za-z0-9]+):\s*$', line)
        if m and m.group(2) in keys_to_remove:
            skip_key = m.group(2)
            skip_indent = len(m.group(1))
            continue
    out.append(line)
text = ''.join(out)
text = text.replace('${DeploymentVersion}', artifact_version)
text = text.replace('${ArtifactBucketName}', bucket)
text = text.replace('${ArtifactKeyPrefix}', prefix)
text = re.sub(r'^(\s*SemanticVersion:\s*)!Ref\s+DeploymentVersion\s*$', rf'\1"{version}"', text, flags=re.MULTILINE)
text = re.sub(r'^(\s*LicenseUrl:\s*)!Sub\s+s3://\$\{ArtifactBucketName\}/\$\{ArtifactKeyPrefix\}/[^\s]+/docs/LICENSE\s*$', rf'\1"s3://{bucket}/{prefix}/{artifact_version}/docs/LICENSE"', text, flags=re.MULTILINE)
text = re.sub(r'^(\s*ReadmeUrl:\s*)!Sub\s+s3://\$\{ArtifactBucketName\}/\$\{ArtifactKeyPrefix\}/[^\s]+/docs/SAR-README\.md\s*$', rf'\1"s3://{bucket}/{prefix}/{artifact_version}/docs/SAR-README.md"', text, flags=re.MULTILINE)
text = re.sub(r'^(\s*SourceBucketName:\s*)!Ref\s+ArtifactBucketName\s*$', rf'\1{bucket}', text, flags=re.MULTILINE)
pattern = re.compile(r'^(?P<indent>\s*)(?P<kind>CodeUri|ContentUri):\s*\n(?P=indent)\s{2}Bucket:\s*(?P<bucket_val>.+?)\s*\n(?P=indent)\s{2}Key:\s*(?P<key_val>.+?)\s*$', flags=re.MULTILINE)
def clean_key(v: str) -> str:
    v = v.strip()
    if v.startswith('!Sub '):
        v = v[len('!Sub '):].strip()
    v = v.strip('"\'')
    v = v.replace('${DeploymentVersion}', artifact_version)
    v = v.replace('${ArtifactKeyPrefix}', prefix)
    return v
text = pattern.sub(lambda m: f"{m.group('indent')}{m.group('kind')}: s3://{bucket}/{clean_key(m.group('key_val'))}", text)
output_path.write_text(text, encoding='utf-8')
PY2
  export SAR_TEMPLATE_FILE="$output_template"
  print_status "SAR template generated"
}

dump_resolved_references() {
  print_info "Resolved artifact references in generated SAR template"
  grep -nE 'SemanticVersion:|LicenseUrl:|ReadmeUrl:|CodeUri: s3://|ContentUri: s3://|SourceBucketName:' "$SAR_TEMPLATE_FILE" || true
}

get_application_id() {
  aws serverlessrepo list-applications --region "$SAR_REGION" --query "Applications[?Name=='$APP_NAME'].ApplicationId | [0]" --output text 2>/dev/null || true
}

publish_direct() {
  local template_file="$1"
  local app_id
  app_id="$(get_application_id)"
  if [ -n "$app_id" ] && [ "$app_id" != "None" ]; then
    print_info "Application exists, creating version $VERSION"
    aws serverlessrepo create-application-version --region "$SAR_REGION" --application-id "$app_id" --semantic-version "$VERSION" --source-code-url "$SOURCE_CODE_URL" --template-body "file://$template_file" >/dev/null || print_error "Failed to create SAR application version"
  else
    print_info "Creating new SAR application $APP_NAME"
    aws serverlessrepo create-application --region "$SAR_REGION" --name "$APP_NAME" --description "$DESCRIPTION" --author "$AUTHOR" --spdx-license-id "MIT" --license-url "$LICENSE_S3_URL" --readme-url "$README_S3_URL" --labels "${LABELS[@]}" --semantic-version "$VERSION" --source-code-url "$SOURCE_CODE_URL" --home-page-url "$HOME_PAGE_URL" --template-body "file://$template_file" >/dev/null || print_error "Failed to create SAR application"
  fi
  print_status "SAR publish completed"
}

publish_via_s3() {
  local template_file="$1"
  local target="s3://$ARTIFACTS_BUCKET/$FULL_PREFIX/templates/template.sar.yaml"
  aws s3 cp "$template_file" "$target" --region "$AWS_REGION" >/dev/null || print_error "Failed to upload SAR template"
  local template_url="https://$ARTIFACTS_BUCKET.s3.$AWS_REGION.amazonaws.com/$FULL_PREFIX/templates/template.sar.yaml"
  local app_id
  app_id="$(get_application_id)"
  if [ -n "$app_id" ] && [ "$app_id" != "None" ]; then
    print_info "Application exists, creating version $VERSION"
    aws serverlessrepo create-application-version --region "$SAR_REGION" --application-id "$app_id" --semantic-version "$VERSION" --source-code-url "$SOURCE_CODE_URL" --template-url "$template_url" >/dev/null || print_error "Failed to create SAR application version"
  else
    print_info "Creating new SAR application $APP_NAME"
    aws serverlessrepo create-application --region "$SAR_REGION" --name "$APP_NAME" --description "$DESCRIPTION" --author "$AUTHOR" --spdx-license-id "MIT" --license-url "$LICENSE_S3_URL" --readme-url "$README_S3_URL" --labels "${LABELS[@]}" --semantic-version "$VERSION" --source-code-url "$SOURCE_CODE_URL" --home-page-url "$HOME_PAGE_URL" --template-url "$template_url" >/dev/null || print_error "Failed to create SAR application"
  fi
  print_status "SAR publish completed"
}

main() {
  show_config
  check_prerequisites
  ensure_local_artifacts
  configure_bucket_policy
  upload_artifacts_if_needed
  upload_documentation_files
  generate_sar_template
  dump_resolved_references
  local template_file="$SAR_TEMPLATE_FILE"
  local template_size
  template_size=$(stat -f%z "$template_file" 2>/dev/null || stat -c%s "$template_file")
  if [ "$template_size" -le 51200 ]; then
    publish_direct "$template_file"
  else
    publish_via_s3 "$template_file"
  fi
}

main "$@"
