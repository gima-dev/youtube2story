#!/usr/bin/env bash
# Помощник для подготовки/внесения правок в конфиг V2Ray/V2RayTun.
# По умолчанию работает в режиме dry-run и печатает предлагаемые изменения.
# Для применения используйте: sudo ./update_v2raytun_config.sh --apply /path/to/config.json

set -euo pipefail

TEMPLATE_JSON_PATH="$(dirname "$0")/v2ray_cf_routing_template.json"

usage() {
  cat <<EOF
Usage:
  $0 [--apply /path/to/config.json]

Описание:
  - Без опций — печатает шаблон routing и инструкции (dry-run).
  - С --apply <config> — создаёт резервную копию <config>.bak и вставляет блок routing
    из шаблона (перезаписывает ключ "routing" в JSON). Требуется jq либо python3.

EOF
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "${1:-}" = "--apply" ]; then
  CONFIG_PATH="$2"
  if [ ! -f "$CONFIG_PATH" ]; then
    echo "Конфиг $CONFIG_PATH не найден" >&2
    exit 2
  fi
  echo "Создаю резервную копию: ${CONFIG_PATH}.bak"
  sudo cp -a "$CONFIG_PATH" "${CONFIG_PATH}.bak"

  echo "Вставляю шаблон routing из $TEMPLATE_JSON_PATH в $CONFIG_PATH"
  if command -v jq >/dev/null 2>&1; then
    sudo jq -s '.[1] as $t | .[0] | .routing = $t.routing' "$CONFIG_PATH" "$TEMPLATE_JSON_PATH" | sudo tee "$CONFIG_PATH" >/dev/null
    echo "Применено с помощью jq. Резервная копия: ${CONFIG_PATH}.bak"
  else
    echo "jq не найден, попробую python3"
    sudo python3 - <<PY
import json,sys
cfg_path = sys.argv[1]
tmpl_path = sys.argv[2]
with open(cfg_path,'r',encoding='utf-8') as f: cfg=json.load(f)
with open(tmpl_path,'r',encoding='utf-8') as f: tmpl=json.load(f)
cfg['routing']=tmpl.get('routing',{})
with open(cfg_path,'w',encoding='utf-8') as f: json.dump(cfg,f,indent=2,ensure_ascii=False)
print('Applied template routing (python).')
PY
  fi

  echo "Готово. Рестартуйте V2RayTun/службы чтобы изменения вступили в силу."
  exit 0
fi

echo "=== Dry-run: показываю шаблон routing ==="
cat "$TEMPLATE_JSON_PATH"
echo
echo "Чтобы применить шаблон: sudo $0 --apply /path/to/config.json"

exit 0
