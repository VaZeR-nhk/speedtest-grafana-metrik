# Speedtest Monitoring for Node Exporter

Этот скрипт автоматически настраивает проверку скорости интернета на сервере Debian и передает данные в Node Exporter (Textfile Collector) для дальнейшего отображения в Grafana.

## Установка одной командой

Запустите следующую команду под пользователем **root**:

```bash
curl -sSL https://raw.githubusercontent.com/VaZeR-nhk/speedtest-grafana-metrik/main/speedtest-install.sh | bash
