#!/bin/bash

export LC_NUMERIC=C

# Конфигурация
bot_token="${BOT_TOKEN:-PASTE_YOUR_BOT_TOKEN_HERE}"
chat_id="${CHAT_ID:-PASTE_YOUR_CHAT_ID_HERE}"
server_name="$(hostname -I | awk '{print $1}')"

disks=("/" "/home")
services=("docker" "ssh" "nexus-node")

# Пороги
load_threshold_fraction=0.9
disk_warn=80
disk_crit=90
mem_warn=90
mem_crit=95
swap_warn=50
swap_crit=70

# Лог
log_file="/var/log/server-monitor.log"
max_log_size=500000 # 500 KB
max_telegram_lines=10

# ===== Функции =====

escape_markdown() {
    # Экранирует спецсимволы для Markdown
    sed -e 's/\`/\\`/g' -e 's/_/\\_/g' -e 's/\*/\\*/g' -e 's/\[/\\[/g' -e 's/\]/\\]/g'
}

format_logs_for_telegram() {
    local input="$1"
    local trimmed=$(echo "$input" | tail -n "$max_telegram_lines")
    echo -e "\`\`\`\n$trimmed\n\`\`\`"
}

send_telegram_message() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot$bot_token/sendMessage" \
         -d "chat_id=$chat_id" \
         -d "text=*[$server_name]* $(echo "$message" | escape_markdown)" \
         -d "parse_mode=Markdown"
}

log() {
    echo "[$(date '+%F %T')] $1" | tee -a "$log_file"
    if [[ -f "$log_file" && $(stat -c%s "$log_file") -gt $max_log_size ]]; then
        mv "$log_file" "${log_file}.bak"
        echo "[$(date '+%F %T')] 🔄 Log rotated" > "$log_file"
    fi
}

check_disks() {
    for disk in "${disks[@]}"; do
        usage=$(df "$disk" | tail -1 | awk '{print $5}' | sed 's/%//')
        if (( usage >= disk_crit )); then
            send_telegram_message "🚨 *CRITICAL:* Disk usage on $disk is ${usage}%"
            log "Critical disk usage on $disk: $usage%"
        elif (( usage >= disk_warn )); then
            send_telegram_message "⚠️ *WARNING:* Disk usage on $disk is ${usage}%"
            log "Warning disk usage on $disk: $usage%"
        fi
    done
}

check_load() {
    load=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
    num_cores=$(nproc)
    threshold=$(echo "$num_cores * $load_threshold_fraction" | bc -l)

    log "DEBUG: load=$load threshold=$threshold num_cores=$num_cores"

    if [[ -z "$load" || -z "$threshold" ]]; then
        log "Error: load or threshold is empty"
        return
    fi

    comp_result=$(echo "$load >= $threshold" | bc -l | tr -d '[:space:]')

    if [[ "$comp_result" == "1" ]]; then
        send_telegram_message "🚨 *CRITICAL LOAD:* Load is $load on $num_cores cores"
        log "Critical load: $load"
    fi
}

check_memory() {
    total_mem=$(free -m | awk '/^Mem:/ {print $2}')
    used_mem=$(free -m | awk '/^Mem:/ {print $3}')
    usage_percent=$(( used_mem * 100 / total_mem ))
    if (( usage_percent >= mem_crit )); then
        send_telegram_message "🚨 *CRITICAL:* Memory usage is ${usage_percent}%"
        log "Critical memory usage: ${usage_percent}%"
    elif (( usage_percent >= mem_warn )); then
        send_telegram_message "⚠️ *WARNING:* Memory usage is ${usage_percent}%"
        log "Warning memory usage: ${usage_percent}%"
    fi
}

check_swap() {
    swap_info=$(free -m | awk '/^Swap:/ {print $2, $3}')
    total_swap=$(echo "$swap_info" | awk '{print $1}')
    used_swap=$(echo "$swap_info" | awk '{print $2}')

    if (( total_swap == 0 )); then
        log "Swap not configured, skipping check."
        return
    fi

    usage_percent=$(( used_swap * 100 / total_swap ))

    if (( usage_percent >= swap_crit )); then
        send_telegram_message "🚨 *CRITICAL:* Swap usage is ${usage_percent}% (${used_swap}MB of ${total_swap}MB)"
        log "Critical swap usage: ${usage_percent}%"
    elif (( usage_percent >= swap_warn )); then
        send_telegram_message "⚠️ *WARNING:* Swap usage is ${usage_percent}% (${used_swap}MB of ${total_swap}MB)"
        log "Warning swap usage: ${usage_percent}%"
    fi
}

check_services() {
    for svc in "${services[@]}"; do
        if ! systemctl is-active --quiet "$svc"; then
            send_telegram_message "❌ *SERVICE DOWN:* $svc is not running!"
            log "Service $svc is down!"
        fi
    done
}

check_ssh_logins() {
    logins=$(journalctl -u sshd --since "5 minutes ago" | grep "Accepted password\|Accepted publickey")
    if [[ -n "$logins" ]]; then
        msg="🔐 *New SSH login(s):*\n$(format_logs_for_telegram "$logins")"
        send_telegram_message "$msg"
        log "SSH logins detected."
    fi
}

check_syslog_errors() {
    errors=$(journalctl --since "5 minutes ago" | grep -Ei "error|fail|critical" | grep -v "Failed password")
    if [[ -n "$errors" ]]; then
        last_errors=$(echo "$errors" | sed 's/\x1b\[[0-9;]*m//g' | tail -n 5)
        formatted_errors=$(format_logs_for_telegram "$last_errors")
        send_telegram_message "❗ *System errors detected:*\n$formatted_errors"
        log "System errors found in logs"
    fi
}

check_docker_logs() {
    if ! command -v docker &> /dev/null; then
        log "Docker not installed, skipping docker log check."
        return
    fi

    containers=$(docker ps -q)
    for container in $containers; do
        name=$(docker inspect --format='{{.Name}}' "$container" | sed 's/\///')
        logs=$(docker logs --since 5m "$container" 2>&1 |
            grep -iE "error|fail|panic|segfault" |
            sed 's/\x1b\[[0-9;]*m//g' |
            tail -n "$max_telegram_lines")

        if [[ -n "$logs" ]]; then
            formatted_logs=$(format_logs_for_telegram "$logs")
            send_telegram_message "🐳 *Docker error in container \`$name\`:*\n$formatted_logs"
            log "Docker error in container $name"
        fi
    done
}

# Обработка завершения
trap "echo '🛑 Script stopped' >> $log_file; exit" SIGINT SIGTERM

# ======= Основной цикл =======
while true; do
    check_disks
    check_load
    check_memory
    check_swap
    check_services
    check_ssh_logins
    check_syslog_errors
    check_docker_logs
    sleep 300
done
