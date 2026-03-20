#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.artifacts"
FUNCTIONS=(custom-resource pre-signup pre-token-generation post-confirmation custom-email-sender)
BUILD_MODE="${BUILD_MODE:-minified}"
NODE_VERSION_REQUIRED="22"

print_status() { echo -e "${GREEN}✅ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; exit 1; }

check_node_version() {
  command -v node >/dev/null 2>&1 || print_error "Node.js is not installed"
  local current
  current=$(node --version | sed 's/^v//' | cut -d. -f1)
  [ "$current" -ge "$NODE_VERSION_REQUIRED" ] || print_error "Node.js $NODE_VERSION_REQUIRED+ required"
  print_status "Using Node.js $(node --version)"
}

check_tools() {
  local tools=(npm zip npx)
  for tool in "${tools[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || print_error "$tool is not installed"
  done
  print_status "Required tools are available"
}

clean_build() {
  rm -rf "$BUILD_DIR" "$ROOT_DIR/layers/cognito-common"
  mkdir -p "$BUILD_DIR/functions" "$BUILD_DIR/layers"
  print_status "Clean build directory prepared"
}

build_function() {
  local fn="$1"
  local src="$ROOT_DIR/src/$fn/handler.ts"
  local out_dir="$BUILD_DIR/functions/$fn"
  [ -f "$src" ] || print_error "Missing handler: $src"
  mkdir -p "$out_dir"

  print_info "Building $fn..."
  
  # Determine output format based on build mode
  # IMPORTANT: custom-resource must always use CommonJS for AWS SDK compatibility
  local output_format="cjs"
  local output_extension="js"
  
  if [ "$BUILD_MODE" = "readable" ] && [ "$fn" != "custom-resource" ]; then
    output_format="esm"
    output_extension="mjs"
    print_info "Using ES modules format for readable build"
  elif [ "$fn" = "custom-resource" ]; then
    print_info "Using CommonJS format for $fn (required for AWS SDK compatibility)"
  fi
  
  local args=(
    "$src"
    --bundle
    --platform=node
    --target=node24
    --format="${output_format}"
    --outfile="$out_dir/index.${output_extension}"
    --external:@aws-sdk/client-cognito-identity-provider
    --external:@aws-sdk/client-route-53
    --external:@aws-sdk/client-s3
    --external:@aws-sdk/client-sesv2
    --external:@aws-sdk/client-ssm
    --define:process.env.NODE_ENV=\"production\"
  )

  if [ "$BUILD_MODE" = "minified" ]; then
    args+=(
      --minify
      --drop:debugger
    )
    print_info "Building minified CommonJS version (production)"
  else
    args+=(
      --sourcemap
      --keep-names
      --legal-comments=inline
    )
    print_info "Building readable version with sourcemaps (development)"
  fi

  (cd "$ROOT_DIR" && npx esbuild "${args[@]}")
  
  # For ES modules, create a package.json in dist to mark it as ESM
  # Skip for custom-resource which must always use CommonJS
  if [ "$BUILD_MODE" = "readable" ] && [ "$fn" != "custom-resource" ]; then
    cat > "$out_dir/package.json" << 'EOF'
{
  "type": "module"
}
EOF
    print_info "Created package.json for ES module support"
  fi
  
  # Verify build output
  if [ ! -f "$out_dir/index.${output_extension}" ]; then
    print_error "Build output not found for $fn (expected: $out_dir/index.${output_extension})"
  fi
  
  (cd "$out_dir" && zip -q -r "$BUILD_DIR/${fn}.zip" .)
  
  # Show package size
  local package_size=$(stat -f%z "$BUILD_DIR/${fn}.zip" 2>/dev/null || stat -c%s "$BUILD_DIR/${fn}.zip" 2>/dev/null)
  print_status "$fn built -> $BUILD_DIR/${fn}.zip (${package_size} bytes)"
}

main() {
  local start_time=$(date +%s)
  
  print_info "Building WP Suite Cognito SAR project"
  print_info "Build mode: $BUILD_MODE"
  check_node_version
  check_tools
  clean_build

  for fn in "${FUNCTIONS[@]}"; do
    build_function "$fn"
  done

  bash "$ROOT_DIR/scripts/build-layer.sh"
  
  # Build summary
  local end_time=$(date +%s)
  local duration=$((end_time - start_time))
  
  echo
  print_status "Build completed successfully in ${duration}s!"
  echo
  print_info "Build artifacts:"
  ls -lh "$BUILD_DIR"/*.zip 2>/dev/null || true
  ls -lh "$BUILD_DIR"/layers/*.zip 2>/dev/null || true
  
  echo
  print_info "Package sizes:"
  for fn in "${FUNCTIONS[@]}"; do
    if [ -f "$BUILD_DIR/${fn}.zip" ]; then
      local size=$(stat -f%z "$BUILD_DIR/${fn}.zip" 2>/dev/null || stat -c%s "$BUILD_DIR/${fn}.zip" 2>/dev/null)
      printf "  %-25s %s bytes\n" "${fn}:" "$size"
    fi
  done
}

main "$@"
