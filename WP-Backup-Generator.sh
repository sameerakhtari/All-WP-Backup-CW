#!/usr/bin/env bash
set -euo pipefail

APPS_DIR="/home/master/applications"
WP_APPS=()
URLS=()
SERVER_IDS=()
APP_IDS=()

# ---------- prompt for Cloudways API creds ----------
read -rp "Cloudways email: " CW_EMAIL
read -rsp "Cloudways API key: " CW_API_KEY; echo

# ---------- helpers ----------
hr() { # human-readable bytes
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B "$1"
  else
    awk -v b="$1" 'function h(x){s="BKMGTPE";i=0;while(x>=1024&&i<length(s)-1){x/=1024;i++}printf("%.1f %sB\n",x,substr(s,i+1,1))}BEGIN{h(b)}'
  fi
}

du_bytes() { # directory size in bytes
  local p="$1"
  if du -sb "$p" >/dev/null 2>&1; then
    du -sb "$p" | awk '{print $1}'
  else
    echo $(( $(du -sk "$p" | awk '{print $1}') * 1024 ))
  fi
}

db_bytes_via_sql() { # DB size using WP creds; returns bytes
  wp db query "SELECT IFNULL(SUM(data_length+index_length),0) FROM information_schema.TABLES WHERE table_schema=DATABASE();" --skip-column-names 2>/dev/null || echo 0
}

# Extract **last domain from the first server_name line**
last_domain_first_servername_line() {
  local conf="$1" line
  line=$(grep -m1 -n '\<server_name\>' "$conf" 2>/dev/null | cut -d: -f2-)
  [ -n "${line:-}" ] || return 1
  echo "$line" \
    | sed 's/#.*$//' \
    | sed -e 's/\<server_name\>//' -e 's/[;,]/ /g' \
    | xargs \
    | awk '{print $NF}'
}

# Extract server_id and app_id from any filename that ends with:
# *-<SERVERID>-<APPID>.cloudwaysapps.com.access.log
extract_ids_from_logs() {
  local logs_dir="$1"
  local f parsed
  f=$(ls -1t "$logs_dir"/*-*.cloudwaysapps.com.access.log 2>/dev/null | head -n1 || true)
  [ -n "$f" ] || return 1
  parsed=$(basename "$f" | sed -E 's/^.*-([0-9]+)-([0-9]+)\.cloudwaysapps\.com\.access\.log$/\1 \2/')
  if [[ "$parsed" =~ ^[0-9]+\ [0-9]+$ ]]; then
    echo "$parsed"  # "<SERVERID> <APPID>"
  else
    return 1
  fi
}

# Parse JSON "access_token" without jq (fallback)
json_get_access_token() { sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'; }

# ---------- disk space ----------
DISK_PATH="/"
if mount | grep -q "/mnt/BLOCKSTORAGE"; then DISK_PATH="/mnt/BLOCKSTORAGE"; fi
AVAIL_DISK_BYTES=$(df -B1 --output=avail "$DISK_PATH" | tail -1 | tr -dc '0-9')
echo "Available space: $(hr "$AVAIL_DISK_BYTES") (on $DISK_PATH)"
echo

# ---------- OAuth token ----------
echo "🔐 Getting Cloudways OAuth token..."
CW_TOKEN_RESP=$(curl -sS -X POST "https://api.cloudways.com/api/v1/oauth/access_token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "email=${CW_EMAIL}&api_key=${CW_API_KEY}" )
if command -v jq >/dev/null 2>&1; then
  ACCESS_TOKEN=$(echo "$CW_TOKEN_RESP" | jq -r '.access_token // empty')
else
  ACCESS_TOKEN=$(echo "$CW_TOKEN_RESP" | json_get_access_token)
fi
if [ -z "${ACCESS_TOKEN:-}" ]; then
  echo "❌ Failed to obtain access token. Response was:"
  echo "$CW_TOKEN_RESP"
  exit 1
fi
echo "✅ Token acquired."
echo

# ---------- scan apps ----------
printf "🔎 Checking applications...\n"
declare -a APP_PATHS WEB_BYTES DB_BYTES TOTAL_BYTES APP_NAMES
idx=0

for app in "$APPS_DIR"/*; do
  PUB="$app/public_html"
  if [ ! -d "$PUB" ]; then
    echo "⚠️  No public_html found in: $app"
    continue
  fi

  pushd "$PUB" >/dev/null || continue
  if wp core is-installed --quiet >/dev/null 2>&1; then
    DBNAME="$(wp config get DB_NAME 2>/dev/null || echo "")"
    WEB_B=$(du_bytes "$PUB")
    DB_B=$(db_bytes_via_sql)
    TOT_B=$((WEB_B + DB_B))

    APP_PATHS[$idx]="$app"
    WEB_BYTES[$idx]="$WEB_B"
    DB_BYTES[$idx]="$DB_B"
    TOTAL_BYTES[$idx]="$TOT_B"
    APP_NAMES[$idx]="${DBNAME:-unknown_db}"

    IDS="$(extract_ids_from_logs "$app/logs" || true)"
    if [ -n "$IDS" ]; then
      SERVER_IDS[$idx]="${IDS%% *}"
      APP_IDS[$idx]="${IDS##* }"
      echo "✅ WP: $app (DB: ${DBNAME:-unknown})  [srv:${SERVER_IDS[$idx]} app:${APP_IDS[$idx]}]"
    else
      SERVER_IDS[$idx]=""
      APP_IDS[$idx]=""
      echo "✅ WP: $app (DB: ${DBNAME:-unknown})  [ids not found]"
    fi

    WP_APPS+=("$app")
    idx=$((idx+1))
  else
    echo "❌ Not WordPress (or wp-config missing): $app"
  fi
  popd >/dev/null
done

echo
echo "WordPress apps detected: ${#WP_APPS[@]}"
echo

# ---------- size table ----------
if [ "${#WP_APPS[@]}" -gt 0 ]; then
  printf "%-40s %-14s %-14s %-14s %-11s %-11s\n" "App (DB)" "Web size" "DB size" "Total" "server_id" "app_id"
  printf "%-40s %-14s %-14s %-14s %-11s %-11s\n" "----------------------------------------" "--------------" "--------------" "--------------" "-----------" "-----------"
  GRAND=0
  for i in "${!APP_PATHS[@]}"; do
    w="${WEB_BYTES[$i]}"; d="${DB_BYTES[$i]}"; t="${TOTAL_BYTES[$i]}"; GRAND=$((GRAND + t))
    printf "%-40s %-14s %-14s %-14s %-11s %-11s\n" \
      "$(basename "${APP_PATHS[$i]}") (${APP_NAMES[$i]})" \
      "$(hr "$w")" "$(hr "$d")" "$(hr "$t")" \
      "${SERVER_IDS[$i]:--}" "${APP_IDS[$i]:--}"
  done
  echo "------------------------------------------------------------------------------------------------------------"
  echo "Grand total (web + DB for all apps): $(hr "$GRAND")"
  echo

  if [ "$GRAND" -gt "$AVAIL_DISK_BYTES" ]; then
    echo "❌ Not enough space for backup. Required: $(hr "$GRAND"), Available: $(hr "$AVAIL_DISK_BYTES")"
    exit 1
  else
    echo "✅ Backup can fit (Required: $(hr "$GRAND"), Available: $(hr "$AVAIL_DISK_BYTES"))"
    echo
  fi
fi

# ---------- reset permissions via Cloudways API ----------
echo "🛠  Resetting file permissions for detected apps..."
for i in "${!APP_PATHS[@]}"; do
  sid="${SERVER_IDS[$i]:-}"; aid="${APP_IDS[$i]:-}"
  if [[ -n "$sid" && -n "$aid" ]]; then
    HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" \
      -X POST \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      -H 'Accept: application/json' \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -d "server_id=${sid}&app_id=${aid}" \
      'https://api.cloudways.com/api/v1/app/manage/reset_permissions?ownership=master_user')
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "202" ]; then
      echo "   ✅ ${sid}/${aid} -> reset requested (HTTP ${HTTP_CODE})"
    else
      echo "   ❌ ${sid}/${aid} -> reset failed (HTTP ${HTTP_CODE})"
    fi
  else
    echo "   ⚠️  Skipping $(basename "${APP_PATHS[$i]}"): missing server/app id"
  fi
done
echo

# ---------- backup each app ----------
for i in "${!APP_PATHS[@]}"; do
  app="${APP_PATHS[$i]}"
  PUB="$app/public_html"
  echo "----------------------------"
  echo "Backing up: $PUB"
  pushd "$PUB" >/dev/null || continue

  if wp db export db_backup.sql >/dev/null 2>&1; then
    echo "   ✅ Database exported: db_backup.sql"
  else
    echo "   ❌ Database export failed in $PUB"
    popd >/dev/null
    continue
  fi

  if zip -r backup.zip . -x "./backup.zip" >/dev/null 2>&1; then
    echo "   ✅ backup.zip created"
  else
    echo "   ❌ Failed to zip $PUB"
    popd >/dev/null
    continue
  fi

  CONF="$app/conf/server.nginx"
  if [ -f "$CONF" ]; then
    DOMAIN="$(last_domain_first_servername_line "$CONF" || echo "")"
    if [ -n "$DOMAIN" ]; then
      URL="${DOMAIN}/backup.zip"   # no scheme, to match your format
      URLS+=("$URL")
      echo "   🔗 $URL"
    else
      echo "   ⚠️  Could not parse server_name in $CONF"
    fi
  else
    echo "   ⚠️  No server.nginx found in $app/conf/"
  fi

  popd >/dev/null
done

echo
echo "🎉 Backup process completed."
echo

# ---------- FINAL URL LIST (plain, no extra text) ----------
if [ "${#URLS[@]}" -gt 0 ]; then
  for u in "${URLS[@]}"; do
    echo "$u"
  done
fi
