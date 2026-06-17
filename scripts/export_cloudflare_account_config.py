"""Export local account YAML files as Cloudflare account override JSON."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
ACCOUNTS_DIR = ROOT / "config" / "accounts"
DEFAULT_CONFIG_PATH = ROOT / "config" / "default.yaml"


NOT_FOUND = object()


def diff_config(account_value, default_value=NOT_FOUND):
    if default_value is not NOT_FOUND and account_value == default_value:
        return NOT_FOUND

    if isinstance(account_value, dict) and isinstance(default_value, dict):
        result = {}
        for key, value in account_value.items():
            child_default = default_value.get(key, NOT_FOUND)
            child_diff = diff_config(value, child_default)
            if child_diff is not NOT_FOUND:
                result[key] = child_diff
        return result if result else NOT_FOUND

    return account_value


def load_accounts() -> dict[str, dict]:
    accounts: dict[str, dict] = {}
    if not ACCOUNTS_DIR.exists():
        return accounts

    default_config = yaml.safe_load(DEFAULT_CONFIG_PATH.read_text(encoding="utf-8")) or {}
    if not isinstance(default_config, dict):
        raise SystemExit(f"{DEFAULT_CONFIG_PATH} 必须是 YAML 对象")

    for path in sorted(ACCOUNTS_DIR.glob("*.yaml")):
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        if not isinstance(data, dict):
            raise SystemExit(f"{path} 必须是 YAML 对象")
        account_diff = diff_config(data, default_config)
        accounts[path.stem] = {} if account_diff is NOT_FOUND else account_diff

    return accounts


def main() -> None:
    output_path = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else None
    text = json.dumps(load_accounts(), ensure_ascii=False, indent=2)
    if output_path is None:
        print(text)
        return

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(text + "\n", encoding="utf-8")
    print(f"exported account config: {output_path}")


if __name__ == "__main__":
    main()
