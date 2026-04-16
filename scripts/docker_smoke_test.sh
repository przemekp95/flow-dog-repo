#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
image_ref="flowdog-order-api:local"
host_port="18080"
app_env="prod"
app_secret="local-smoke-secret-not-for-production"
openapi_output="/tmp/flowdog-openapi.json"

log() {
    printf '[docker-smoke] %s\n' "$*"
}

fail() {
    log "$*" >&2
    exit 1
}

resolve_docker_bin() {
    if command -v docker >/dev/null 2>&1; then
        command -v docker
        return 0
    fi

    local snap_docker
    snap_docker="$(find /snap/docker-core24 -path '*/bin/docker' -type f 2>/dev/null | sort | tail -n 1 || true)"
    if [[ -n "$snap_docker" && -x "$snap_docker" ]]; then
        printf '%s\n' "$snap_docker"
        return 0
    fi

    return 1
}

resolve_php_bin() {
    if command -v php >/dev/null 2>&1; then
        command -v php
        return 0
    fi

    if [[ -x "$ROOT_DIR/.tools/php84-common/php" ]]; then
        printf '%s\n' "$ROOT_DIR/.tools/php84-common/php"
        return 0
    fi

    return 1
}

fetch_openapi_json() {
    local url="$1"
    local output_file="$2"

    if command -v curl >/dev/null 2>&1; then
        curl --fail --silent "$url" > "$output_file"
        return 0
    fi

    local php_bin
    php_bin="$(resolve_php_bin)" || fail 'Neither curl nor PHP was found. Install curl, put php in PATH, or provide .tools/php84-common/php.'

    "$php_bin" -r '
        $url = $argv[1];
        $outputFile = $argv[2];
        $body = @file_get_contents($url);
        if ($body === false) {
            fwrite(STDERR, "HTTP fetch failed for {$url}\n");
            exit(1);
        }

        if (file_put_contents($outputFile, $body) === false) {
            fwrite(STDERR, "Failed to write {$outputFile}\n");
            exit(1);
        }
    ' "$url" "$output_file"
}

post_sample_order() {
    local url="$1"
    local output_file="$2"
    local payload='{"customerId":123,"items":[{"productId":10,"quantity":2}],"couponCode":"PROMO10"}'

    if command -v curl >/dev/null 2>&1; then
        local status_code
        status_code="$(
            curl \
                --silent \
                --show-error \
                --output "$output_file" \
                --write-out '%{http_code}' \
                --request POST \
                --header 'Content-Type: application/json' \
                --data "$payload" \
                "$url"
        )"

        if [[ "$status_code" != "201" ]]; then
            cat "$output_file" >&2 || true
            fail "Expected POST ${url} to return HTTP 201, got ${status_code}."
        fi

        return 0
    fi

    local php_bin
    php_bin="$(resolve_php_bin)" || fail 'Neither curl nor PHP was found. Install curl, put php in PATH, or provide .tools/php84-common/php.'

    "$php_bin" -r '
        $url = $argv[1];
        $outputFile = $argv[2];
        $payload = $argv[3];

        $context = stream_context_create([
            "http" => [
                "method" => "POST",
                "header" => "Content-Type: application/json\r\n",
                "content" => $payload,
                "ignore_errors" => true,
                "timeout" => 20,
            ],
        ]);

        $body = @file_get_contents($url, false, $context);
        $headers = $http_response_header ?? [];
        $statusLine = $headers[0] ?? "";

        if (!preg_match("/\\s(\\d{3})\\s/", $statusLine, $matches) || (int) $matches[1] !== 201) {
            fwrite(STDERR, "Expected HTTP 201, got: {$statusLine}\n");
            if (is_string($body)) {
                fwrite(STDERR, $body . "\n");
            }
            exit(1);
        }

        if (!is_string($body) || file_put_contents($outputFile, $body) === false) {
            fwrite(STDERR, "Failed to write smoke test response\n");
            exit(1);
        }
    ' "$url" "$output_file" "$payload"
}

extract_order_id() {
    local input_file="$1"
    local php_bin
    php_bin="$(resolve_php_bin)" || fail 'PHP not found. Install php or provide .tools/php84-common/php.'

    "$php_bin" -r '
        $inputFile = $argv[1];
        $payload = json_decode((string) file_get_contents($inputFile), true);

        if (!is_array($payload) || ($payload["total"] ?? null) !== 216 || ($payload["couponCode"] ?? null) !== "PROMO10") {
            fwrite(STDERR, "Unexpected sample order response payload\n");
            exit(1);
        }

        $orderId = $payload["id"] ?? null;
        if (!is_string($orderId) || $orderId === "") {
            fwrite(STDERR, "Sample order response does not contain a valid id\n");
            exit(1);
        }

        echo $orderId;
    ' "$input_file"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            image_ref="$2"
            shift 2
            ;;
        --host-port)
            host_port="$2"
            shift 2
            ;;
        --app-env)
            app_env="$2"
            shift 2
            ;;
        --app-secret)
            app_secret="$2"
            shift 2
            ;;
        --openapi-output)
            openapi_output="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

DOCKER_BIN="$(resolve_docker_bin)" || fail 'Docker not found. Install docker or expose the snap docker binary in PATH.'

container_id="$("$DOCKER_BIN" run -d \
  -p "${host_port}:8080" \
  --health-interval=2s \
  --health-timeout=3s \
  --health-start-period=1s \
  --health-retries=15 \
  -e APP_ENV="${app_env}" \
  -e APP_SECRET="${app_secret}" \
  "${image_ref}")"

cleanup() {
    status=$?
    if [[ $status -ne 0 ]]; then
        "$DOCKER_BIN" logs "$container_id"
    fi
    "$DOCKER_BIN" rm -f "$container_id" >/dev/null 2>&1 || true
    exit "$status"
}

trap cleanup EXIT

for attempt in $(seq 1 30); do
    health_status="$("$DOCKER_BIN" inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id")"
    if [[ "$health_status" == "healthy" ]]; then
        break
    fi
    if [[ "$health_status" == "unhealthy" ]]; then
        echo "Container became unhealthy before smoke test completed." >&2
        exit 1
    fi
    sleep 2
done

fetch_openapi_json "http://127.0.0.1:${host_port}/api/doc.json" "${openapi_output}"
grep -q '"openapi"' "${openapi_output}"

sample_order_response="$(mktemp)"
trap 'rm -f "$sample_order_response"; cleanup' EXIT

post_sample_order "http://127.0.0.1:${host_port}/orders" "${sample_order_response}"
order_id="$(extract_order_id "${sample_order_response}")"

"$DOCKER_BIN" exec "$container_id" sh -lc "[ -f /app/var/orders/${app_env}/${order_id}.json ]"
