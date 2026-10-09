#!/bin/sh
# Production deploy entry point, run as root. Reached only through the forced
# command of the CI deploy key in ~ubuntu/.ssh/authorized_keys:
#   restrict,command="sudo -n /opt/ppanel/deploy.sh \"$SSH_ORIGINAL_COMMAND\"" ssh-ed25519 ...
#   $1    = full 40-char commit sha to deploy (the client's SSH command)
#   stdin = short-lived GHCR token of the workflow run
set -eu

APP_DIR=/opt/ppanel
cd "$APP_DIR"

SHA="${1:-}"
# Exactly 40 lowercase hex characters, nothing else (no newlines either).
case "$SHA" in
'' | *[!0-9a-f]*) SHA_OK=0 ;;
*) [ "${#SHA}" -eq 40 ] && SHA_OK=1 || SHA_OK=0 ;;
esac
if [ "$SHA_OK" != 1 ]; then
	echo "deploy: expected a 40-char commit sha" >&2
	exit 2
fi

exec 9>"$APP_DIR/.deploy.lock"
flock -w 600 9 || { echo "deploy: another deploy is running" >&2; exit 1; }

IFS= read -r GHCR_TOKEN || true

env_get() { sed -n "s/^$1=//p" .env | tail -n 1; }
set_tag() { sed -i "s/^PPANEL_TAG=.*/PPANEL_TAG=$1/" .env; }

PREV_TAG="$(env_get PPANEL_TAG)"
REQUIRE_HEALTHY="$(env_get DEPLOY_REQUIRE_HEALTHY)"
HEALTH_TIMEOUT="$(env_get DEPLOY_HEALTH_TIMEOUT)"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"

# Credentials live only for this run: the token expires with the job anyway.
DOCKER_CONFIG="$(mktemp -d)"
export DOCKER_CONFIG
trap 'rm -rf "$DOCKER_CONFIG"' EXIT
if [ -n "${GHCR_TOKEN:-}" ]; then
	printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u ci --password-stdin >/dev/null
fi

echo "deploy: $PREV_TAG -> $SHA"
set_tag "$SHA"
if ! docker compose pull ppanel; then
	set_tag "$PREV_TAG"
	echo "deploy: pull failed, kept $PREV_TAG" >&2
	exit 1
fi
docker compose up -d --remove-orphans

health() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' ppanel-server 2>/dev/null || echo missing; }

waited=0
status="$(health)"
while [ "$status" = starting ] && [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
	sleep 5; waited=$((waited + 5)); status="$(health)"
done
echo "deploy: container status after ${waited}s: $status"

if [ "$status" != healthy ] && [ "$REQUIRE_HEALTHY" = 1 ]; then
	echo "deploy: $SHA is not healthy, rolling back to $PREV_TAG" >&2
	docker compose logs --tail 80 ppanel >&2 || true
	set_tag "$PREV_TAG"
	docker compose up -d
	exit 1
fi
if [ "$status" != healthy ]; then
	echo "deploy: WARNING not healthy (DEPLOY_REQUIRE_HEALTHY=0, kept anyway)"
	docker compose logs --tail 30 ppanel || true
fi

# Keep the running and the previous image (the rollback target), drop the
# older ppanel images only; other stacks on this host are left alone.
IMAGE="$(env_get PPANEL_IMAGE)"
docker images "$IMAGE" --format '{{.Tag}}' | grep -Ev "^($SHA|$PREV_TAG)\$" |
	while read -r old; do docker rmi "$IMAGE:$old" >/dev/null 2>&1 || true; done
echo "deploy: done ($SHA)"
