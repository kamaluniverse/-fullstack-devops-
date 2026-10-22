#!/usr/bin/env bash
#
# deploy.sh — validate, build/pull, roll out and verify the ProShop stack.
#
#   ./scripts/deploy.sh            # build images locally and deploy
#   IMAGE_SOURCE=ecr ./scripts/deploy.sh   # pull versioned images from ECR
#   ./scripts/deploy.sh rollback   # return to the previous known-good deploy
#   ./scripts/deploy.sh status     # show container state and health
#
# Safety:
#   * Never runs `docker compose down -v`; database volumes are preserved.
#   * Refuses to start with missing/placeholder secrets.
#   * On failure, prints container state and recent logs.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ACTION="${1:-deploy}"
# compose.yaml is the only compose file; the target is selected by profile in
# .env (COMPOSE_FILE is read from .env inside load_env(), so keep a safe default):
#   COMPOSE_PROFILES=dev -> all-in-one (local / learning single host)
#   COMPOSE_PROFILES=app -> production app host (no MongoDB; DB is remote)
#   COMPOSE_PROFILES=db  -> production MongoDB host
COMPOSE="docker compose"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1/api/health}"
AWS_REGION="${AWS_REGION:-us-east-1}"
LAST_GOOD_FILE=".last-good-image"
PREVIOUS_FILE=".previous-image"

log()  { printf '\n[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

load_env() {
  [[ -f .env ]] || fail ".env not found — copy .env.example to .env and fill it in"
  # An explicitly supplied TAG (e.g. from CI) must win over the value in .env.
  local preset_tag="${TAG:-}"
  set -a
  # shellcheck disable=SC1091
  source ./.env
  set +a

  IMAGE_SOURCE="${IMAGE_SOURCE:-build}"
  TAG="${preset_tag:-${TAG:-local}}"
  COMPOSE="docker compose -f ${COMPOSE_FILE:-compose.yaml}"
  : "${MONGO_USER:?MONGO_USER is required}"
  : "${MONGO_PASSWORD:?MONGO_PASSWORD is required}"
  : "${MONGO_DB:?MONGO_DB is required}"
  : "${JWT_SECRET:?JWT_SECRET is required}"

  [[ "$JWT_SECRET" == REPLACE_* ]] && fail "JWT_SECRET still contains the placeholder value"
  [[ "$MONGO_PASSWORD" == REPLACE_* ]] && fail "MONGO_PASSWORD still contains the placeholder value"
  [[ ${#JWT_SECRET} -ge 32 ]] || fail "JWT_SECRET must be at least 32 characters"

  if [[ "$IMAGE_SOURCE" == "ecr" ]]; then
    : "${ECR_REGISTRY:?ECR_REGISTRY is required when IMAGE_SOURCE=ecr}"
    : "${ECR_REPO_PREFIX:?ECR_REPO_PREFIX is required when IMAGE_SOURCE=ecr}"
    export BACKEND_IMAGE="${ECR_REGISTRY}/${ECR_REPO_PREFIX}/backend:${TAG}"
    export FRONTEND_IMAGE="${ECR_REGISTRY}/${ECR_REPO_PREFIX}/frontend:${TAG}"
  else
    export BACKEND_IMAGE="${BACKEND_IMAGE:-proshop-backend:${TAG}}"
    export FRONTEND_IMAGE="${FRONTEND_IMAGE:-proshop-frontend:${TAG}}"
  fi
}

validate_compose() {
  log "Validating Compose configuration"
  $COMPOSE config -q || fail "docker compose config rejected the configuration"
}

save_previous() {
  if [[ -f "$LAST_GOOD_FILE" ]]; then
    cp "$LAST_GOOD_FILE" "$PREVIOUS_FILE"
  fi
}

save_good() {
  {
    echo "TAG=$TAG"
    echo "BACKEND_IMAGE=$BACKEND_IMAGE"
    echo "FRONTEND_IMAGE=$FRONTEND_IMAGE"
  } > "$LAST_GOOD_FILE"
}

print_diagnostics() {
  log "Container state"
  $COMPOSE ps || true
  log "Recent logs (last 80 lines per service)"
  $COMPOSE logs --tail=80 || true
}

wait_for_health() {
  local attempts="${1:-40}"
  log "Waiting for $HEALTH_URL (up to $((attempts * 5))s)"
  for _ in $(seq 1 "$attempts"); do
    if curl -fsS --max-time 5 "$HEALTH_URL" -o /tmp/proshop-health.json 2>/dev/null; then
      if grep -q '"db":"connected"' /tmp/proshop-health.json; then
        log "Health check passed"
        cat /tmp/proshop-health.json
        echo
        return 0
      fi
    fi
    sleep 5
  done
  return 1
}

do_deploy() {
  load_env
  log "Deploying tag ${TAG} (IMAGE_SOURCE=${IMAGE_SOURCE}, COMPOSE=${COMPOSE})"
  validate_compose
  save_previous

  if [[ "$IMAGE_SOURCE" == "ecr" ]]; then
    log "Authenticating to ECR"
    if command -v aws >/dev/null 2>&1; then
      aws ecr get-login-password --region "$AWS_REGION" \
        | docker login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null \
        || fail "ECR docker login failed"
    else
      fail "aws CLI is required for IMAGE_SOURCE=ecr"
    fi
    log "Pulling images for tag $TAG from ECR"
    $COMPOSE pull backend frontend || fail "image pull failed"
    $COMPOSE up -d --no-build --remove-orphans || { print_diagnostics; fail "compose up failed"; }
  else
    log "Building images for tag $TAG"
    $COMPOSE build backend frontend || fail "image build failed"
    $COMPOSE up -d --no-build --remove-orphans || { print_diagnostics; fail "compose up failed"; }
  fi

  if ! wait_for_health; then
    print_diagnostics
    fail "deployment did not become healthy"
  fi

  save_good
  log "Deployment successful (tag: $TAG)"
}

do_rollback() {
  [[ -f "$PREVIOUS_FILE" ]] || fail "no previous deployment recorded in $PREVIOUS_FILE"
  log "Rolling back to the previous known-good deployment"
  set -a
  # shellcheck disable=SC1091
  source "./$PREVIOUS_FILE"
  set +a
  export BACKEND_IMAGE FRONTEND_IMAGE TAG
  $COMPOSE pull backend frontend || log "pull skipped/failed — using local images"
  $COMPOSE up -d --no-build --remove-orphans || { print_diagnostics; fail "rollback failed"; }
  wait_for_health || { print_diagnostics; fail "rollback did not become healthy"; }
  log "Rollback complete"
}

do_status() {
  load_env
  $COMPOSE ps
  echo
  curl -fsS --max-time 5 "$HEALTH_URL" && echo || echo "health endpoint unreachable"
}

case "$ACTION" in
  deploy)   do_deploy ;;
  rollback) do_rollback ;;
  status)   do_status ;;
  *) fail "unknown action '$ACTION' (use: deploy | rollback | status)" ;;
esac
