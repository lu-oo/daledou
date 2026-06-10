"""校验 Cloudflare Worker 使用的 DALEDOU_COOKIES Secret。"""

import json
import os
from http.cookies import SimpleCookie


def parse_cookie_items(raw: str) -> list[str]:
    stripped = raw.strip()
    if not stripped:
        raise ValueError("DALEDOU_COOKIES 不能为空")

    if stripped.startswith("["):
        try:
            data = json.loads(stripped)
        except json.JSONDecodeError as exc:
            raise ValueError(f"DALEDOU_COOKIES JSON 数组格式错误：{exc}") from exc
        if not isinstance(data, list):
            raise ValueError("DALEDOU_COOKIES JSON 格式必须是字符串数组")
        return data

    return [
        line.strip()
        for line in stripped.splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]


def validate_cookies(raw: str) -> list[str]:
    cookie_items = parse_cookie_items(raw)
    accounts: list[str] = []

    for index, cookie in enumerate(cookie_items, start=1):
        if not isinstance(cookie, str) or not cookie.strip():
            raise ValueError(f"第 {index} 个 Cookie 不是有效字符串")

        jar = SimpleCookie()
        jar.load(cookie)
        newuin = jar.get("newuin")
        if newuin is None or not newuin.value:
            raise ValueError(f"第 {index} 个 Cookie 缺少 newuin，无法识别账号")
        accounts.append(newuin.value)

    if not accounts:
        raise ValueError("未识别到任何包含 newuin 的 Cookie")

    duplicates = sorted({qq for qq in accounts if accounts.count(qq) > 1})
    if duplicates:
        raise ValueError(f"DALEDOU_COOKIES 存在重复账号：{', '.join(duplicates)}")

    return accounts


def main() -> None:
    try:
        accounts = validate_cookies(os.environ.get("DALEDOU_COOKIES_VALUE", ""))
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc

    print(f"==> Cookie 校验通过，识别账号数：{len(accounts)}")


if __name__ == "__main__":
    main()
