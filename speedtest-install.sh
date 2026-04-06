#!/bin/bash
# Автоматический установщик Speedtest мониторинга (Полная автоматизация)

if [ "$EUID" -ne 0 ]; then 
  echo "Пожалуйста, запустите от root"
  exit
fi

echo "--- Начинаю установку Speedtest Exporter ---"

# 1. Установка зависимостей
curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
apt-get install speedtest jq -y

# 2. Полная очистка старых конфигов и подготовка окружения
rm -rf /root/.ookla
mkdir -p /root/.ookla
export HOME=/root

# 3. Настройка папки для метрик
mkdir -p /var/lib/node_exporter/textfile_collector

# 4. Патч существующего сервиса Node Exporter
SERVICE_FILE="/etc/systemd/system/nodeexporter.service"
if [ -f "$SERVICE_FILE" ]; then
    if ! grep -q "collector.textfile.directory" "$SERVICE_FILE"; then
        echo "Добавляю поддержку textfile в nodeexporter.service..."
        # Заменяем только если путь еще не добавлен
        sed -i 's|node_exporter|node_exporter --collector.textfile.directory=/var/lib/node_exporter/textfile_collector|' "$SERVICE_FILE"
        systemctl daemon-reload
        systemctl restart nodeexporter
    fi
fi

# 5. Создание скрипта-замерщика
cat << 'EOF' > /usr/local/bin/speedtest_exporter.sh
#!/bin/bash
# Путь к файлу метрик
METRIC_FILE="/var/lib/node_exporter/textfile_collector/speedtest.prom"

# Принудительно задаем HOME, чтобы speedtest видел лицензию
export HOME=/root

# Запуск теста с авто-принятием лицензии
DATA=$(speedtest --format=json --accept-license --accept-gdpr 2>/dev/null)

# Парсинг данных
if [[ -n "$DATA" && "$DATA" == *"download"* ]]; then
    DOWNLOAD=$(echo $DATA | jq '.download.bandwidth * 8')
    UPLOAD=$(echo $DATA | jq '.upload.bandwidth * 8')
    PING=$(echo $DATA | jq '.ping.latency')
    JITTER=$(echo $DATA | jq '.ping.jitter')

    cat <<EOM > "${METRIC_FILE}.tmp"
# HELP speedtest_download_bits Download speed in bits per second
# TYPE speedtest_download_bits gauge
speedtest_download_bits $DOWNLOAD
# HELP speedtest_upload_bits Upload speed in bits per second
# TYPE speedtest_upload_bits gauge
speedtest_upload_bits $UPLOAD
# HELP speedtest_ping_latency_ms Ping latency in milliseconds
# TYPE speedtest_ping_latency_ms gauge
speedtest_ping_latency_ms $PING
# HELP speedtest_ping_jitter_ms Ping jitter in milliseconds
# TYPE speedtest_ping_jitter_ms gauge
speedtest_ping_jitter_ms $JITTER
EOM
    mv "${METRIC_FILE}.tmp" "${METRIC_FILE}"
fi
EOF

chmod +x /usr/local/bin/speedtest_exporter.sh

# 6. Создание Service с пробросом HOME
cat << EOF > /etc/systemd/system/speedtest-run.service
[Unit]
Description=Run Speedtest Script
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/speedtest_exporter.sh
User=root
# Передаем HOME сервису, чтобы speedtest не падал
Environment="HOME=/root"
EOF

# 7. Создание Timer на 30 минут
cat << EOF > /etc/systemd/system/speedtest-run.timer
[Unit]
Description=Run Speedtest every 30 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF

# 8. Запуск системы
systemctl daemon-reload
systemctl enable --now speedtest-run.timer

echo "Запускаю первый замер (это займет около 1 минуты)..."
systemctl start speedtest-run.service

# 9. Финальная проверка результата
echo "--- Результат установки ---"
if [ -f "/var/lib/node_exporter/textfile_collector/speedtest.prom" ]; then
    echo "УСПЕХ! Метрики созданы:"
    cat /var/lib/node_exporter/textfile_collector/speedtest.prom
else
    echo "ОШИБКА: Файл метрик не найден. Попробуйте выполнить 'speedtest' вручную."
fi
