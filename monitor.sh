#!/bin/bash

export LC_NUMERIC=C


# Конфигурация
bot_token=""
chat_id=""
server_name="$(hostname -I | awk '{print $1}')"

disks=("/" "/home")
services=("docker" "ssh")

# Пороги
load_threshold_fraction=0.9
disk_warn=80
disk_crit=90
mem_warn=80
mem_crit=90

# Лог
log_file="/var/log/server-monitor.log"
max_log_size=500000 # 500 КБ

send_telegram_message() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot$bot_token/sendMessage" \
         -d "chat_id=$chat_id" \
         -d "text=*[$server_name]* $message" \
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
        msg="🔐 *New SSH login(s):*\n$(echo "$logins" | tail -n 3)"
        send_telegram_message "$msg"
        log "SSH logins detected."
    fi
}

# Основной цикл
while true; do
    check_disks
    check_load
    check_memory
    check_services
    check_ssh_logins
    sleep 300
done
