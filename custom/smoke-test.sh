#!/usr/bin/env bash
#
# Smoke gate for the multi-monitor image. Exits non-zero on ANY failure so CI
# refuses to publish a broken build (e.g. an upstream merge or SHA bump that
# silently dropped the multi-monitor PRs or failed to link against FreeRDP 3).
#
# Usage: smoke-test.sh <image-ref>
#
# Checks:
#   1. Container boots and stays up (no s6 crash loop).
#   2. Tomcat serves the Guacamole webapp (HTTP 200 on :8080/).
#   3. guacd is running.
#   4. The compiled RDP plugin advertises the "secondary-monitors" parameter
#      (proves PR #560 actually made it into libguac-client-rdp.so).

set -euo pipefail

IMAGE="${1:?usage: smoke-test.sh <image-ref>}"
NAME="guac-smoke-$$"
TIMEOUT="${SMOKE_TIMEOUT:-240}"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> [1/4] starting container from ${IMAGE}"
docker run -d --name "$NAME" "$IMAGE" >/dev/null

echo "==> [2/4] waiting up to ${TIMEOUT}s for Tomcat to serve /"
deadline=$(( $(date +%s) + TIMEOUT ))
until docker exec "$NAME" wget -q -O /dev/null http://localhost:8080/ 2>/dev/null; do
    if ! docker ps --filter "name=${NAME}" --filter "status=running" -q | grep -q .; then
        echo "!! container exited early; logs:"; docker logs "$NAME" 2>&1 | tail -40
        exit 1
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "!! timed out waiting for Tomcat; logs:"; docker logs "$NAME" 2>&1 | tail -40
        exit 1
    fi
    sleep 3
done
echo "   Tomcat OK"

echo "==> [3/4] checking guacd is running"
docker exec "$NAME" pgrep -x guacd >/dev/null || {
    echo "!! guacd not running"; docker logs "$NAME" 2>&1 | tail -40; exit 1; }
echo "   guacd OK"

echo "==> [4/4] checking RDP plugin advertises 'secondary-monitors'"
docker exec "$NAME" sh -c '
    so=$(find /usr/local/lib /usr/lib -name "libguac-client-rdp.so*" 2>/dev/null | head -1)
    [ -n "$so" ] || { echo "RDP plugin not found"; exit 1; }
    echo "   plugin: $so"
    grep -a -q "secondary-monitors" "$so"
' || { echo "!! secondary-monitors NOT present in RDP plugin — multi-monitor PR missing"; exit 1; }
echo "   multi-monitor parameter present"

echo "==> SMOKE PASS"
