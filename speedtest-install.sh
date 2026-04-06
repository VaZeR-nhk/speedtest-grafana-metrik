#!/bin/bash
# Автоматический установщик Speedtest мониторинга для Node Exporter (FIXED VERSION)

if [ "$EUID" -ne 0 ]; then 
  echo "Пожалуйста, запустите от root"
  exit
fi

echo "--- Начинаю установку Speedtest Exporter ---"

# 1. Установка зависимостей
curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
apt-get install speedtest jq -y

# 2. Исправление ошибки logic_error (чистим битые конфиги)
rm -rf /root/.ookla
rm -rf ~/.ookla

# 3. Настройка папки для метрик
mkdir -p /var/lib/node_exporter/textfile_collector

# 4. Патч существующего сервиса Node Exporter
SERVICE_FILE="/etc/systemd/system/nodeexporter.service"
if [ -f "$SERVICE_FILE" ]; then
    if ! grep -q "collector.textfile.directory" "$SERVICE_FILE"; then
        echo "Добавляю поддержку textfile в nodeexporter.service..."
        sed -i 's|node_exporter|node_exporter --collector.textfile.directory=/var/lib/node_exporter/textfile_collector|' "$SERVICE_FILE"
        systemctl daemon-reload
        systemctl restart nodeexporter
    fi
else
    echo "ВНИМАНИЕ: Файл $SERVICE_FILE не найден."
fi

# 5. Создание скрипта-замерщика (С ИСПРАВЛЕНИЕМ HOME)
cat << 'EOF' > /usr/local/bin/speedtest_exporter.sh
#!/bin/bash
METRIC_FILE="/var/lib/node_exporter/textfile_collector/speedtest.prom"

# Обязательно для работы Speedtest внутри systemd
export HOME=/root

# Запуск теста
DATA=$(speedtest --format=json --accept-license --accept-gdpr 2>/dev/null)

# Проверяем, что получили корректный JSON с данными загрузки
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
    echo "Speedtest success: $(date)"
else
    echo "Speedtest failed. Check manual run of 'speedtest' command."
fi
EOF
chmod +x /usr/local/bin/speedtest_exporter.sh

# 6. Создание юнитов системы
cat << EOF > /etc/systemd/system/speedtest-run.service
[Unit]
Description=Run Speedtest Script
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/speedtest_exporter.sh
User=root
# Также прописываем HOME здесь для надежности
Environment="HOME=/root"
EOF

cat << EOF > /etc/systemd/system/speedtest-run.timer
[Unit]
Description=Run Speedtest every 30 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=30min

[Install]
WantedBy=timers.target
EOF

# 7. Запуск и первый замер
systemctl daemon-reload
systemctl enable --now speedtest-run.timer
echo "Запускаю первый тест (подождите 40-60 сек)..."
systemctl start speedtest-run.service

echo "--- Установка завершена! ---"
# Проверка результата
if [ -f "/var/lib/node_exporter/textfile_collector/speedtest.prom" ]; then
    echo "Метрики успешно созданы:"
    cat /var/lib/node_exporter/textfile_collector/speedtest.prom
else
    echo "Ошибка: Метрики не были созданы. Попробуйте запустить 'speedtest' вручную."
fi
