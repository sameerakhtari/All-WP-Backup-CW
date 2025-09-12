#!/usr/bin/env bash
# WP / Generic App Backup with Domain Filtering (Cloudways)
# - Prompts for Cloudways email, API key, and domains (any format)
# - Filters apps by the *last domain from the first `server_name` line*
# - WP apps exported via WP-CLI; others via mysqldump using discovered creds
# - Resets permissions via Cloudways API, zips app (incl. db_backup.sql), prints URL list
set -euo pipefail

APPS_DIR="/home/master/applications"

# ----------------- Prompt for creds + domains -----------------
read -rp "Cloudways email: " CW_EMAIL
read -rsp "Cloudways API key: " CW_API_KEY; echo
echo
echo "Paste target domain(s) (any format: commas, spaces, newlines, with/without http[s]:// or www.):"
echo "(Press Ctrl-D when done)"
RAW_DOMAINS="$(cat || true)"

# Normalize -> unique list, lowercase, strip scheme/slashes/www
mapfile -t DOMAINS < <(
  echo "$RAW_DOMAINS" \
  | sed -E 's#https?://##gi; s#/# #g' \
  | tr ',;|\t\r' ' ' \
  | tr ' ' '\n' \
  | tr 'A-Z' 'a-z' \
  | grep -Eo '([a-z0-9-]+\.)+[a-z]{2,}' \
  | sed -E 's/^www\.//' \
  | sort -u
)

if [[ ${#DOMAINS[@]} -eq 0 ]]; then
  echo "❌ No valid domains provided. Exiting."
  exit 1
fi

echo "Target domains (${#DOMAINS[@]}):"
for d in "${DOMAINS[@]}"; do echo " • $d"; done
echo

# ----------------- Helpers -----------------
hr() { # human-readable bytes
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B "$1"
  else
    awk -v b="$1" 'function h(x){s="BKMGTPE";i=0;while(x>=1024&&i<7){x/=1024;i++}printf "%.1f%sB\n",x,substr(s,i+1,1)} BEGIN{h(b)}'
  fi
}

du_bytes() { # dir size in bytes
  du -sb "$1" 2>/dev/null | awk '{print $1}' || echo $(( $(du -sk "$1" | awk '{print $1}') * 1024 ))
}

db_bytes_via_wp() { # DB size using WP CLI; returns bytes
  wp db query "SELECT IFNULL(SUM(data_length+index_length),0) FROM information_schema.TABLES WHERE table_schema=DATABASE();" --skip-column-names 2>/dev/null || echo 0
}

db_bytes_via_mysql() { # args: host port user pass db
  local host="$1" port="$2" user="$3" pass="$4" db="$5"
  local q="SELECT IFNULL(SUM(data_length+index_length),0) FROM information_schema.TABLES WHERE table_schema='${db}';"
  if [[ -n "$port" ]]; then
    MYSQL_PWD="$pass" mysql -h "$host" -P "$port" -u "$user" -N -B -e "$q" 2>/dev/null || echo 0
  else
    MYSQL_PWD="$pass" mysql -h "$host" -u "$user" -N -B -e "$q" 2>/dev/null || echo 0
  fi
}

json_get_access_token() { sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'; }

split_host_port() { # echoes "host|port"
  local hp="$1"
  if [[ "$hp" =~ ^\[.*\]:[0-9]+$ ]]; then echo "${hp%:*}|${hp##*:}"
  elif [[ "$hp" == *:* ]]; then echo "${hp%:*}|${hp##*:}"
  else echo "$hp|"; fi
}

# Get only the LAST domain from the FIRST server_name line (original behavior)
last_domain_first_servername_line() {
  local conf="$1" line
  line=$(grep -m1 -n 'server_name' "$conf" 2>/dev/null | cut -d: -f2- || true)
  [[ -n "${line:-}" ]] || return 1
  echo "$line" \
    | sed 's/#.*$//' \
    | sed -e 's/server_name//' -e 's/[;,]/ /g' \
    | xargs \
    | awk '{print $NF}'
}

# Extract server_id & app_id from latest access log filename
extract_ids_from_logs() {
  local logs_dir="$1" f parsed
  f=$(ls -1t "$logs_dir"/*-*.cloudwaysapps.com.access.log 2>/dev/null | head -n1 || true)
  [[ -n "$f" ]] || return 1
  parsed=$(basename "$f" | sed -E 's/^.*-([0-9]+)-([0-9]+)\.cloudwaysapps\.com\.access\.log$/\1 \2/')
  [[ "$parsed" =~ ^[0-9]+\ [0-9]+$ ]] && echo "$parsed" || return 1
}

# Extract DB creds from php defines (even if commented) or .env for non-WP.
# Echoes: "name|user|pass|host|source"
find_db_creds() {
  local pub="$1" name="" user="" pass="" host="" source=""
  if [[ -f "$pub/wp-config.php" ]]; then
    name=$(sed -nE "s/.*define\(['\"]DB_NAME['\"],[[:space:]]*['\"]([^'\"]+)['\"]\).*/\1/p" "$pub/wp-config.php" | head -n1 || true)
    user=$(sed -nE "s/.*define\(['\"]DB_USER['\"],[[:space:]]*['\"]([^'\"]+)['\"]\).*/\1/p" "$pub/wp-config.php" | head -n1 || true)
    pass=$(sed -nE "s/.*define\(['\"]DB_PASSWORD['\"],[[:space:]]*['\"]([^'\"]+)['\"]\).*/\1/p" "$pub/wp-config.php" | head -n1 || true)
    host=$(sed -nE "s/.*define\(['\"]DB_HOST['\"],[[:space:]]*['\"]([^'\"]+)['\"]\).*/\1/p" "$pub/wp-config.php" | head -n1 || true)
    if [[ -n "$name" || -n "$user" || -n "$pass" ]]; then source="wp-config.php"; fi
  fi
  if [[ -z "$name" || -z "$user" || -z "$pass" ]]; then
    name="${name:-$(grep -R --include="*.php" -E "define\(['\"]DB_NAME['\"]" "$pub" 2>/dev/null | head -n1 | sed -nE "s/.*['\"]DB_NAME['\"].*['\"]([^'\"]+)['\"].*/\1/p")}"
    user="${user:-$(grep -R --include="*.php" -E "define\(['\"]DB_USER['\"]" "$pub" 2>/dev/null | head -n1 | sed -nE "s/.*['\"]DB_USER['\"].*['\"]([^'\"]+)['\"].*/\1/p")}"
    pass="${pass:-$(grep -R --include="*.php" -E "define\(['\"]DB_PASSWORD['\"]" "$pub" 2>/dev/null | head -n1 | sed -nE "s/.*['\"]DB_PASSWORD['\"].*['\"]([^'\"]+)['\"].*/\1/p")}"
    host="${host:-$(grep -R --include="*.php" -E "define\(['\"]DB_HOST['\"]" "$pub" 2>/dev/null | head -n1 | sed -nE "s/.*['\"]DB_HOST['\"].*['\"]([^'\"]+)['\"].*/\1/p")}"
    if [[ -z "$source" && ( -n "$name" || -n "$user" || -n "$pass" ) ]]; then source="php-scan"; fi
  fi
  if [[ -z "$name" || -z "$user" || -z "$pass" ]]; then
    if [[ -f "$pub/.env" ]]; then
      name="${name:-$(grep -m1 -E '^DB_DATABASE=' "$pub/.env" | sed -E 's/^DB_DATABASE=//')}"
      user="${user:-$(grep -m1 -E '^DB_USERNAME=' "$pub/.env" | sed -E 's/^DB_USERNAME=//')}"
      pass="${pass:-$(grep -m1 -E '^DB_PASSWORD=' "$pub/.env" | sed -E 's/^DB_PASSWORD=//')}"
      host="${host:-$(grep -m1 -E '^DB_HOST=' "$pub/.env" | sed -E 's/^DB_HOST=//')}"
      [[ -z "$source" && -n "$name" ]] && source=".env"
    fi
  fi
  host="${host:-localhost}"
  echo "${name}|${user}|${pass}|${host}|${source}"
}

strip_www() { echo "$1" | sed -E 's/^www\.//'; }

# ----------------- Disk selection -----------------
DISK_PATH="/"
if command -v mountpoint >/dev/null 2>&1; then
  mountpoint -q /mnt/BLOCKSTORAGE && DISK_PATH="/mnt/BLOCKSTORAGE"
else
  df -P | awk '{print $6}' | grep -qx "/mnt/BLOCKSTORAGE" && DISK_PATH="/mnt/BLOCKSTORAGE"
fi
DISK_INFO=$(df -B1 --output=size,used,avail,target "$DISK_PATH" | tail -1)
TOTAL_BYTES=$(echo "$DISK_INFO" | awk '{print $1}')
USED_BYTES=$(echo "$DISK_INFO" | awk '{print $2}')
AVAIL_DISK_BYTES=$(echo "$DISK_INFO" | awk '{print $3}')
MOUNT_POINT=$(echo "$DISK_INFO" | awk '{print $4}')
echo "Disk stats for $MOUNT_POINT:"
echo " Total: $(hr "$TOTAL_BYTES")"
echo " Used : $(hr "$USED_BYTES")"
echo " Avail: $(hr "$AVAIL_DISK_BYTES")"
echo

# ----------------- Cloudways OAuth -----------------
echo " Getting Cloudways OAuth token..."
CW_TOKEN_RESP=$(curl -sS -X POST "https://api.cloudways.com/api/v1/oauth/access_token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "email=${CW_EMAIL}&api_key=${CW_API_KEY}" )
if command -v jq >/dev/null 2>&1; then
  ACCESS_TOKEN=$(echo "$CW_TOKEN_RESP" | jq -r '.access_token // empty')
else
  ACCESS_TOKEN=$(echo "$CW_TOKEN_RESP" | json_get_access_token)
fi
if [[ -z "${ACCESS_TOKEN:-}" ]]; then
  echo "❌ Failed to obtain access token. Response was:"; echo "$CW_TOKEN_RESP"; exit 1
fi
echo "✅ Token acquired."
echo

# ----------------- Discover & Filter Apps (by last-domain) -----------------
declare -a APP_PATHS WEB_BYTES DB_BYTES TOTAL_BYTES_ARR APP_NAMES APP_TYPES SERVER_IDS APP_IDS URLS
idx=0

echo "Discovering applications that match supplied domains (last domain from first server_name line)..."
for app in "$APPS_DIR"/*; do
  PUB="$app/public_html"
  [[ -d "$PUB" ]] || continue

  CONF="$app/conf/server.nginx"
  [[ -f "$CONF" ]] || continue

  LDOMAIN="$(last_domain_first_servername_line "$CONF" | tr 'A-Z' 'a-z' || true)"
  [[ -n "$LDOMAIN" ]] || continue
  LDOMAIN_NOWWW="$(strip_www "$LDOMAIN")"

  SHOULD=false
  for d in "${DOMAINS[@]}"; do
    if [[ "$LDOMAIN_NOWWW" == "$d" ]]; then
      SHOULD=true
      break
    fi
  done
  $SHOULD || continue

  pushd "$PUB" >/dev/null || continue

  is_wp=false
  if command -v wp >/dev/null 2>&1; then
    wp core is-installed --quiet >/dev/null 2>&1 && is_wp=true || true
  fi

  if $is_wp; then
    DBNAME="$(wp config get DB_NAME 2>/dev/null || echo "")"
    WEB_B=$(du_bytes "$PUB")
    DB_B=$(db_bytes_via_wp)
    TOT_B=$((WEB_B + DB_B))
    APP_TYPES[$idx]="WP"
    APP_NAMES[$idx]="${DBNAME:-unknown_db}"
    echo " • $(basename "$app") → $LDOMAIN (WP, DB=${DBNAME:-unknown})"
  else
    IFS='|' read -r name user pass host source <<<"$(find_db_creds "$PUB")"
    app_dir="$(basename "$app")"

    # Accept rule: php defines OK if db name == app dir; .env always OK
    accept=false
    [[ -n "$name" && "$name" == "$app_dir" ]] && accept=true
    [[ "$source" == ".env" ]] && accept=true

    WEB_B=$(du_bytes "$PUB")
    DB_B=0
    if $accept && command -v mysql >/dev/null 2>&1; then
      IFS='|' read -r h p <<<"$(split_host_port "$host")"
      DB_B=$(db_bytes_via_mysql "$h" "$p" "$user" "$pass" "$name")
    fi
    TOT_B=$((WEB_B + DB_B))
    APP_TYPES[$idx]="GEN"
    APP_NAMES[$idx]="${name:-unknown_db}"
    echo " • $(basename "$app") → $LDOMAIN (GEN, DB=${name:-unknown}${source:+, src=$source})"
  fi

  IDS="$(extract_ids_from_logs "$app/logs" || true)"
  if [[ -n "$IDS" ]]; then
    SERVER_IDS[$idx]="${IDS%% *}"
    APP_IDS[$idx]="${IDS##* }"
  else
    SERVER_IDS[$idx]=""; APP_IDS[$idx]=""
  fi

  APP_PATHS[$idx]="$app"
  WEB_BYTES[$idx]="$WEB_B"
  DB_BYTES[$idx]="$DB_B"
  TOTAL_BYTES_ARR[$idx]="$TOT_B"
  idx=$((idx+1))
  popd >/dev/null
done

if [[ ${#APP_PATHS[@]} -eq 0 ]]; then
  echo "❌ No applications matched the supplied domains."
  exit 1
fi
echo

# ----------------- Size Table & Disk Check -----------------
printf "%-8s %-40s %-14s %-14s %-14s %-11s %-11s\n" "Type" "App (DB)" "Web size" "DB size" "Total" "server_id" "app_id"
printf "%-8s %-40s %-14s %-14s %-14s %-11s %-11s\n" "--------" "----------------------------------------" "--------------" "--------------" "--------------" "-----------" "-----------"
GRAND=0
for i in "${!APP_PATHS[@]}"; do
  w="${WEB_BYTES[$i]}"; d="${DB_BYTES[$i]}"; t="${TOTAL_BYTES_ARR[$i]}"
  GRAND=$((GRAND + t))
  printf "%-8s %-40s %-14s %-14s %-14s %-11s %-11s\n" \
    "${APP_TYPES[$i]}" \
    "$(basename "${APP_PATHS[$i]}") (${APP_NAMES[$i]})" \
    "$(hr "$w")" "$(hr "$d")" "$(hr "$t")" \
    "${SERVER_IDS[$i]:--}" "${APP_IDS[$i]:--}"
done
echo "--------------------------------------------------------------------------------------------------------------------"
echo "Grand total (web + DB for selected apps): $(hr "$GRAND")"
echo

if [[ "$GRAND" -gt "$AVAIL_DISK_BYTES" ]]; then
  echo "❌ Not enough space for backup on $MOUNT_POINT."
  echo "   Required: $(hr "$GRAND"), Available: $(hr "$AVAIL_DISK_BYTES")"
  exit 1
else
  echo "✅ Backup can fit on $MOUNT_POINT (Required: $(hr "$GRAND"), Available: $(hr "$AVAIL_DISK_BYTES"))"
  echo
fi

# ----------------- Reset permissions via Cloudways API -----------------
echo " Resetting file permissions for matched apps..."
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
    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "202" ]]; then
      echo " ✅ ${sid}/${aid} -> reset requested (HTTP ${HTTP_CODE})"
    else
      echo " ❌ ${sid}/${aid} -> reset failed (HTTP ${HTTP_CODE})"
    fi
  else
    echo " ⚠️ Skipping $(basename "${APP_PATHS[$i]}"): missing server/app id"
  fi
done
echo

# ----------------- Backup Loop -----------------
for i in "${!APP_PATHS[@]}"; do
  app="${APP_PATHS[$i]}"
  PUB="$app/public_html"
  echo "----------------------------"
  echo "Backing up: $PUB"
  pushd "$PUB" >/dev/null || continue

  if [[ "${APP_TYPES[$i]}" == "WP" ]]; then
    if wp db export db_backup.sql >/dev/null 2>&1; then
      echo " ✅ WP database exported: db_backup.sql"
    else
      echo " ❌ WP database export failed in $PUB"
    fi
  else
    IFS='|' read -r name user pass host source <<<"$(find_db_creds "$PUB")"
    app_dir="$(basename "$app")"
    accept=false
    [[ -n "${name:-}" && "$name" == "$app_dir" ]] && accept=true
    [[ "$source" == ".env" ]] && accept=true

    if $accept && command -v mysqldump >/dev/null 2>&1; then
      IFS='|' read -r h p <<<"$(split_host_port "$host")"
      echo " • Using ${source:-php} creds (DB=$name, HOST=$host)"
      if [[ -n "$p" ]]; then
        MYSQL_PWD="$pass" mysqldump --default-character-set=utf8mb4 --single-transaction --quick --skip-lock-tables \
          -h "$h" -P "$p" -u "$user" "$name" > db_backup.sql 2>/dev/null || true
      else
        MYSQL_PWD="$pass" mysqldump --default-character-set=utf8mb4 --single-transaction --quick --skip-lock-tables \
          -h "$h" -u "$user" "$name" > db_backup.sql 2>/dev/null || true
      fi
      if [[ -s db_backup.sql ]]; then
        echo " ✅ Generic database exported: db_backup.sql"
      else
        echo " ❌ mysqldump produced no data (check creds/permissions)"
        rm -f db_backup.sql || true
      fi
    else
      echo " ⚠️ Skipping DB export (no acceptable creds or mysqldump not found)"
    fi
  fi

  # Zip everything (excluding the zip itself)
  if zip -r backup.zip . -x "./backup.zip" >/dev/null 2>&1; then
    echo " ✅ backup.zip created"
  else
    echo " ❌ Failed to zip $PUB"
    popd >/dev/null
    continue
  fi

  # Present URL based on last-domain from first server_name line
  CONF="$app/conf/server.nginx"
  DOMAIN="$(last_domain_first_servername_line "$CONF" || echo "")"
  if [[ -n "$DOMAIN" ]]; then
    URLS+=("${DOMAIN}/backup.zip")
    echo " ${DOMAIN}/backup.zip"
  else
    echo " ⚠️ Could not parse server_name in $CONF"
  fi

  popd >/dev/null
done

echo
echo " Backup process completed."
echo
# Plain URL list for easy copy
for u in "${URLS[@]}"; do echo "$u"; done
