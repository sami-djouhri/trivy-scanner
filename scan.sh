#!/usr/bin/env bash
# Trivy CVE-Scanner — ephemerer One-Shot ueber alle laufenden Images.
# Schreibt eine Prometheus-Textfile-Metrik (auth-frei); optional ntfy.
# Sequentiell + mem_limit, damit der Scan einen RAM-engen Host nicht kippt.
set -euo pipefail

TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:0.58.1}"   # TODO: vor Prod per @sha256-Digest pinnen
CACHE_VOL="${TRIVY_CACHE_VOL:-trivy-cache}"
MEM_LIMIT="${TRIVY_MEM_LIMIT:-1g}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
OUT="${TEXTFILE_DIR}/trivy.prom"
SEVERITY="${TRIVY_SEVERITY:-HIGH,CRITICAL}"
NTFY_URL="${NTFY_URL:-}"               # z.B. http://ntfy (leer = ntfy aus)
NTFY_TOPIC="${NTFY_TOPIC:-homelab-cve}"

command -v docker >/dev/null || { echo "[trivy-scan] docker fehlt" >&2; exit 1; }
command -v jq >/dev/null || { echo "[trivy-scan] jq fehlt" >&2; exit 1; }
[ -d "$TEXTFILE_DIR" ] || { echo "[trivy-scan] Textfile-Dir fehlt: $TEXTFILE_DIR" >&2; exit 1; }

docker volume create "$CACHE_VOL" >/dev/null 2>&1 || true

run_trivy() {
  docker run --rm --memory="${MEM_LIMIT}" \
    -v "${CACHE_VOL}:/root/.cache/trivy" \
    "${TRIVY_IMAGE}" "$@"
}

echo "[trivy-scan] DB-Update ..."
run_trivy image --download-db-only >/dev/null 2>&1 || echo "[trivy-scan] WARN DB-Update fehlgeschlagen, nutze Cache"

mapfile -t IMAGES < <(docker ps --format '{{.Image}}' | sort -u)
echo "[trivy-scan] ${#IMAGES[@]} laufende Images"

TMP="$(mktemp)"
{
  echo "# HELP trivy_image_vulnerabilities Vulnerabilities je laufendem Image nach Severity"
  echo "# TYPE trivy_image_vulnerabilities gauge"
} >> "$TMP"

crit_total=0; high_total=0; scanned=0; failed=0
for img in "${IMAGES[@]}"; do
  json="$(run_trivy image --quiet --skip-db-update --severity "${SEVERITY}" --format json "$img" 2>/dev/null || true)"
  if [ -z "$json" ]; then failed=$((failed+1)); continue; fi
  crit="$(echo "$json" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' 2>/dev/null || echo 0)"
  high="$(echo "$json" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")]     | length' 2>/dev/null || echo 0)"
  safe_img="${img//\"/}"
  echo "trivy_image_vulnerabilities{image=\"${safe_img}\",severity=\"CRITICAL\"} ${crit}" >> "$TMP"
  echo "trivy_image_vulnerabilities{image=\"${safe_img}\",severity=\"HIGH\"} ${high}" >> "$TMP"
  crit_total=$((crit_total+crit)); high_total=$((high_total+high)); scanned=$((scanned+1))
done

{
  echo "# HELP trivy_scan_images_scanned Anzahl gescannter Images"
  echo "# TYPE trivy_scan_images_scanned gauge"
  echo "trivy_scan_images_scanned ${scanned}"
  echo "# HELP trivy_scan_images_failed Anzahl fehlgeschlagener Scans"
  echo "# TYPE trivy_scan_images_failed gauge"
  echo "trivy_scan_images_failed ${failed}"
  echo "# HELP trivy_scan_last_run_timestamp_seconds Unix-Zeit des letzten Laufs"
  echo "# TYPE trivy_scan_last_run_timestamp_seconds gauge"
  echo "trivy_scan_last_run_timestamp_seconds $(date +%s)"
} >> "$TMP"

install -m 0644 "$TMP" "$OUT"
rm -f "$TMP"
echo "[trivy-scan] fertig: ${scanned} gescannt, ${failed} Fehler, CRIT=${crit_total} HIGH=${high_total} -> ${OUT}"

if [ -n "$NTFY_URL" ] && { [ "$crit_total" -gt 0 ] || [ "$high_total" -gt 0 ]; }; then
  curl -fsS -H "Title: Trivy CVE-Scan" \
    -d "CRITICAL=${crit_total} HIGH=${high_total} ueber ${scanned} Images" \
    "${NTFY_URL%/}/${NTFY_TOPIC}" >/dev/null 2>&1 || echo "[trivy-scan] WARN ntfy fehlgeschlagen"
fi
