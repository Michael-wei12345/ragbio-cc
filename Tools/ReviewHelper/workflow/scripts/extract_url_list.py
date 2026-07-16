#!/usr/bin/env python3
import json
import re
import sys
from pathlib import Path

URL_RE = re.compile(r"https?://[^\s<>)\]\}]+", re.IGNORECASE)

def main() -> None:
    text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
    seen: set[str] = set()
    urls: list[str] = []
    for url in URL_RE.findall(text):
        if url not in seen:
            seen.add(url)
            urls.append(url)
    print(json.dumps(urls, indent=2, ensure_ascii=False))

if __name__ == "__main__":
    main()
