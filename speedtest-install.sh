#!/bin/bash
# Автоматический установщик Speedtest мониторинга для Node Exporter

# 1. Проверка на root
if [ "$EUID" -ne 0 ]; then 
  echo "Пожалуйста, запустите от root"
  exit
fi

echo "--- Начинаю установку Speedtest Exporter ---"

# 2. Установка зависимостей
curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
apt-get install speedtest jq -y

# 3. Настройка папки для метрик
mkdir -p /var/lib/node_exporter/textfile_collector

# 4. Патч существующего сервиса Node Exporter
# Ищем файл сервиса (по твоему названию)
SERVICE_FILE="/etc/systemd/system/nodeexporter.service"

if [ -f "$SERVICE_FILE" ]; then
    if ! grep -q "collector.textfile.directory" "$SERVICE_FILE"; then
        echo "Добавляю поддержку textfile в nodeexporter.service..."
        # Вставляем флаг после адреса прослушивания
        sed -i 's|--web.listen-address=127.0.0.1:9100|--web.listen-address=127.0.0.1:9100 --collector.textfile.directory=/var/lib/node_exporter/textfile_collector|' "$SERVICE_FILE"
        systemctl daemon-reload
        systemctl restart nodeexporter
    fi
else
    echo "ВНИМАНИЕ: Файл $SERVICE_FILE не найден. Проверьте путь вручную."
fi

# 5. Создание скрипта-замерщика
cat << 'EOF' > /usr/local/bin/speedtest_exporter.sh
#!/bin/bash
METRIC_FILE="/var/lib/node_exporter/textfile_collector/speedtest.prom"
DATA=$(speedtest --format=json --accept-license --accept-gdpr)
if [ $? -eq 0 ]; then
    DOWNLOAD=$(echo $DATA | jq '.download.bandwidth * 8')
    UPLOAD=$(echo $DATA | jq '.upload.bandwidth * 8')
    PING=$(echo $DATA | jq '.ping.latency')
    JITTER=$(echo $DATA | jq '.ping.jitter')
    cat <<EOM > "${METRIC_FILE}.tmp"
speedtest_download_bits $DOWNLOAD
speedtest_upload_bits $UPLOAD
speedtest_ping_latency_ms $PING
speedtest_ping_jitter_ms $JITTER
EOM
    mv "${METRIC_FILE}.tmp" "${METRIC_FILE}"
fi
EOF
chmod +x /usr/local/bin/speedtest_exporter.sh

# 6. Создание юнитов системы (Service + Timer)
cat << EOF > /etc/systemd/system/speedtest-run.service
[Unit]
Description=Run Speedtest Script
[Service]
Type=oneshot
ExecStart=/usr/local/bin/speedtest_exporter.sh
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

# 7. Запуск
systemctl daemon-reload
systemctl enable --now speedtest-run.timer
systemctl start speedtest-run.service

echo "--- Установка завершена! ---"
curl -s localhost:9100/metrics | grep speedtest
