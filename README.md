# YT-DPI

![Windows](https://img.shields.io/badge/Windows%20.ps1-3.0-green)
![Bash](https://img.shields.io/badge/Bash%20.sh-2.3.3-green)
![License](https://img.shields.io/badge/license-MIT-blue)
[![Telegram](https://img.shields.io/badge/Telegram-blue)](https://t.me/YT_DPI)
[![Поддержать](https://img.shields.io/badge/%D0%9F%D0%BE%D0%B4%D0%B4%D0%B5%D1%80%D0%B6%D0%B0%D1%82%D1%8C-blue)](https://spasibomir.ru/pay/31732)

**YT-DPI** — диагностический инструмент для анализа вмешательства **DPI / ТСПУ** в доступ к YouTube и связанным доменам Google. Это **не** средство обхода блокировок: он показывает *что именно ломается* (DNS, HTTP, TLS 1.2/1.3, QUIC, маршрут), чтобы правильно настроить обход или сменить сеть.

| Платформа | Файлы | Версия в релизе |
| :--- | :--- | :--- |
| **Windows 10/11** | `YT-DPI.bat` + `YT-DPI.ps1` | **3.0** |
| **Linux / macOS / Git Bash / Entware** | `YT-DPI.sh` | **2.3.3** |

Движок Windows в баннере: **Barebuh Pro v3.1 / TUI v1.2**. Bash: **Barebuh Pro v2.3.7** (логика через `curl`). Подробный diff Windows 2.3.3 → 3.0 — в [CHANGELOG.md](CHANGELOG.md).

![Preview](https://raw.githubusercontent.com/Shiperoid/YT-DPI/refs/heads/master/img/YT-DPI-v2.2.3.png)

---

## Содержание

1. [Быстрый старт](#быстрый-старт)
2. [Требования](#требования)
3. [Установка и запуск на любой системе](#установка-и-запуск-на-любой-системе)
4. [Что умеет каждая версия](#что-умеет-каждая-версия)
5. [Горячие клавиши](#горячие-клавиши)
6. [Таблица: колонки, коды ячеек, вердикты](#таблица-колонки-коды-ячеек-вердикты)
7. [EXTRA DIAG (только Windows 3.0)](#extra-diag-только-windows-30)
8. [Настройки, файлы, переменные окружения](#настройки-файлы-переменные-окружения)
9. [Batch / CLI (Windows)](#batch--cli-windows)
10. [Типичные проблемы и что делать](#типичные-проблемы-и-что-делать)
11. [Ссылки и лицензия](#ссылки-и-лицензия)

---

## Быстрый старт

### Windows

1. Скачайте **`YT-DPI.bat`** и **`YT-DPI.ps1`** из [Releases](https://github.com/Shiperoid/YT-DPI/releases) (тег **3.0**) в **одну** папку.
2. Запустите **`YT-DPI.bat`** (лаунчер сам выберет `pwsh`, иначе Windows PowerShell 5.1).
3. Нажмите **Enter** — полный скан. Смотрите колонку **RESULT** и строку **STATUS**.
4. При необходимости: **`[D]`** DNS, **`[G]`** PATH, **`[E]`** EXTRA, **`[R]`** отчёт, **`[H]`** справка.

Headless:

```bat
YT-DPI.bat --batch --json YT-DPI_Report.json --report YT-DPI_Report.txt
```

### Linux / macOS / Git Bash / Entware

```bash
chmod +x YT-DPI.sh
./YT-DPI.sh
```

Или одной строкой (нужен Bash):

```bash
bash <(curl -Ls "https://raw.githubusercontent.com/Shiperoid/YT-DPI/2.3.3/YT-DPI.sh")
```

---

## Требования

### Windows 3.0

* Windows 10/11.
* **PowerShell 7 (`pwsh`)** предпочтительно; работает и **Windows PowerShell 5.1**.
* Консоль ≥ ~**120×30**; для кириллицы — **Windows Terminal** / UTF-8.
* Права администратора **не** обязательны для скана; ICMP PATH обычно работает без raw sockets.
* Антивирус может ругаться на самосборку C# TLS-движка (Add-Type) — это ожидаемо для диагностики.

### Bash 2.3.3

* **bash** (желательно 4+), **curl**, **awk** (обязательно).
* **jq** — необязателен; без него нет чтения/записи `~/.config/yt-dpi/config.json` и geo-кэша, но скан и `targets.txt` работают.
* Терминал ≥ ~**120×30**.
* На busybox-curl (Entware): если нет `--tls-max` / `socks5h://`, TLS-колонки могут стать `N/A`, а не ложный `DRP`.

---

## Установка и запуск на любой системе

### Windows — `YT-DPI.bat` + `YT-DPI.ps1`

| Способ | Команда / действие |
| :--- | :--- |
| Обычный UI | Двойной клик / `YT-DPI.bat` |
| Из cmd/PowerShell | `YT-DPI.bat` |
| Batch-отчёт | `YT-DPI.bat --batch` |
| Справка CLI | `YT-DPI.bat --help` |
| Прямой запуск ps1 | `pwsh -NoProfile -File YT-DPI.ps1` (лучше через `.bat`: выставляет `SCRIPT_PATH`) |
| Автоподгрузка ps1 | Если `.ps1` нет рядом, `.bat` может скачать его с GitHub (bootstrap) |

Файлы рядом: `YT-DPI.bat`, `YT-DPI.ps1`, опционально `targets.txt`. Конфиг: `%LOCALAPPDATA%\YT-DPI\`. Отчёты/лог — обычно рядом со скриптом / в cwd.

### Linux

```bash
# зависимости (пример Debian/Ubuntu)
sudo apt-get install -y bash curl gawk jq
chmod +x YT-DPI.sh && ./YT-DPI.sh
```

### macOS

```bash
# curl обычно уже есть; jq: brew install jq
chmod +x YT-DPI.sh && ./YT-DPI.sh
```

Для стабильного TLS 1.3 нужен нормальный `curl` (штатный Apple/Homebrew обычно ок).

### Git Bash (Windows)

1. [Git for Windows](https://git-scm.com/download/win).
2. Откройте *Git Bash*, `cd` в папку со скриптом, `./YT-DPI.sh`.
3. Скрипт учитывает `MSYSTEM` и снижает частоту анимации.

Для полного Windows-функционала 3.0 используйте **`.bat` + `.ps1`**, не `.sh`.

### Entware / OpenWrt / роутеры

```sh
opkg update
opkg install bash curl coreutils jq   # имена пакетов зависят от репозитория
/opt/bin/bash /path/to/YT-DPI.sh
```

Имеет смысл запускать в `screen`/`tmux`. На «голом» busybox без полноценного bash возможны долгие паузы на старте.

### Запуск одной строкой (Unix)

```bash
bash <(curl -Ls "https://raw.githubusercontent.com/Shiperoid/YT-DPI/2.3.3/YT-DPI.sh")
```

---

## Что умеет каждая версия

| Возможность | Windows 3.0 | Bash 2.3.3 |
| :--- | :---: | :---: |
| Параллельный скан доменов (HTTP :80, TLS 1.2 / 1.3) | да (C# Barebuh) | да (`curl`) |
| Вердикты AVAILABLE / THROTTLED / DPI RESET / DPI BLOCK / IP BLOCK | да | да |
| Прокси HTTP/SOCKS + история | да (`[P]`) | да (`[P]`) |
| Тест прокси с главного экрана | нет (только в `[P]`) | да (`[T]`) |
| `targets.txt` + `[S] 6/7` | да | да |
| Debug-лог `YT-DPI_Debug.log` | да | да |
| Автообновление `[U]` | да | нет |
| DNS system vs DoH `[D]` | да | нет |
| PATH ICMP mtr-lite `[G]` | да | нет |
| EXTRA DIAG `[E]` + post-scan extras | да | нет |
| LAT bars / `RST*` | да | нет |
| Batch / JSON CLI | да | нет |
| Deep Trace | удалён | никогда не было |

---

## Горячие клавиши

### Windows 3.0

| Клавиша | Действие |
| :--- | :--- |
| **Enter** | Полный скан таблицы (+ extras после скана, если не `--no-extras`) |
| **S** | Настройки |
| **P** | Прокси |
| **D** | DNS: system vs DoH |
| **G** | PATH: ICMP TTL к домену # или CDN (Enter) |
| **E** | Полный EXTRA DIAG |
| **U** | Обновление с GitHub |
| **R** | Отчёт TXT (+ JSON) |
| **H** | Справка (несколько страниц) |
| **Q / Esc** | Выход (конфиг сохраняется) |
| Во время скана | **Q / Esc** — прервать (см. STATUS) |

Нижний UI: строка **NAV** (кнопки), под ней **STATUS** (прогресс / итог / разовый tip).

### Bash 2.3.3

| Клавиша | Действие |
| :--- | :--- |
| **Enter** | Скан |
| **S** | Настройки (1–7) |
| **P** | Прокси |
| **T** | Тест текущего прокси |
| **R** | Отчёт TXT |
| **H** | Краткая справка |
| **Q** | Выход |

Поддерживаются те же физические клавиши на русской раскладке (например **й** ≈ Q, **р** ≈ H).

---

## Таблица: колонки, коды ячеек, вердикты

### Колонки

| Колонка | Смысл |
| :--- | :--- |
| № / TARGET | Номер и домен |
| IP | Резолв IPv4/IPv6; при прокси часто `[ PROXIED ]`; `DNS_ERR` — ошибка DNS |
| HTTP | TCP/доступность **порта 80** (не «открылась страница») |
| T12 / T13 | TLS handshake 1.2 и «современный» 1.3+ (на Windows — raw ClientHello) |
| LAT | Задержка HTTP-проверки, мс (+ bar на Windows) |
| RESULT | Итоговый вердикт по строке |

### Коды в ячейках HTTP / TLS

| Код | Значение | Что обычно делать |
| :--- | :--- | :--- |
| **OK** | Проверка прошла | Норма |
| **ERR** | Порт 80 недоступен; TLS часто `---` | Сеть/IP/прокси/маршрут шире TLS |
| **RST** | TCP reset (часто DPI) | Смотреть RESULT; фазы в отчёте |
| **RST\*** | Windows: RST на **ClientHello** (`RST_CH`) | Классический SNI/DPI reset |
| **DRP** | Обрыв / таймаут / «чёрная дыра» | DPI BLOCK / плохой путь / дроп |
| **PRX_ERR** | Ошибка туннеля SOCKS к цели | Проверить прокси (`[P]` / `[T]` в bash) |
| **N/A** | TLS неприменим / curl без поддержки | На busybox — ожидаемо |
| **---** | Ещё не считано / пропущено | После ERR по HTTP и т.п. |
| **DNS_ERR** | Не резолвится (колонка IP) | DNS / DoH / hosts |

В JSON/TXT (Windows): **RST_CH** — сброс на ClientHello; **RST_POST** — после handshake.

### Вердикты RESULT

| Вердикт | Смысл | Практический вывод |
| :--- | :--- | :--- |
| **AVAILABLE** | Оба TLS OK (или рабочая картина) | Путь к узлу по HTTPS выглядит нормальным |
| **THROTTLED** | Один TLS OK, другой RST/DRP | Частичный DPI / деградация; попробуйте TLS 1.2 в клиентах, отключите HTTP/3 |
| **DPI RESET** | RST (особенно `RST_CH`) | Активный сброс по SNI; сравните скан через прокси `[P]` |
| **DPI BLOCK** | DRP без сценария RST выше | Обрыв/таймаут на TLS |
| **IP BLOCK** | HTTP мёртв или оба TLS «плохие» | Сначала интернет/DNS; возможен бан IP/CDN |
| **TIMEOUT** | Строка не успела (Windows) | Повторить скан / сеть перегружена |
| **UNKNOWN** / **IDLE** | Ошибка воркера / не сканировали | Перескан |
| **ROUTING ERROR** | Только bash: HTTP FAIL + TLS RST | Прокси/маршрутизация |

**Важно:** перед замером DPI провайдера **отключите** zapret / GoodbyeDPI / winws. Иначе Windows 3.0 покажет bypass-banner, а картина будет «обхода», а не провайдера.

### Почему лагает YouTube (кратко)

| Симптом у пользователя | Что часто видно в YT-DPI |
| :--- | :--- |
| «Режется по имени сайта» | **DPI RESET** / **DPI BLOCK**, `RST*`, EXTRA `SNI_BLOCK` |
| HTTP/3 / QUIC не работает | EXTRA **QUIC_BLOCK** → в браузере отключить HTTP/3 |
| Видео рвётся после старта | **TCP16_DROP**, THROTTLED |
| Вообще «нет ютуба» | Массовый **IP BLOCK**, DNS `MISMATCH` / `SPOOF_SUSPECT` |
| Только новый Chrome странно | Kyber/TLS 1.3 quirks → часто **THROTTLED**; флаг `chrome://flags/#enable-tls13-kyber` |

---

## EXTRA DIAG (только Windows 3.0)

После **Enter**-скана (если не `--no-extras`) дополнительно:

| Проба | Статусы / смысл |
| :--- | :--- |
| DNS | `OK`, `MISMATCH`, `SPOOF_SUSPECT`, `DOH_BLOCK`, `TIMEOUT` |
| QUIC | `QUIC_OK`, `QUIC_BLOCK`, `QUIC_TIMEOUT` |
| TCP16 | `TCP16_OK`, `TCP16_DROP`, `TCP16_FAIL` |
| IP vs SNI | `OK`, `SNI_BLOCK`, `IP_BLOCK`, `MIXED` |

**`[D]`** — тот же DNS-проход вручную. **`[G]`** — PATH (hop/loss/RTT). **`[E]`** — полный текст + recommendations. Tip после extras — **один раз** в STATUS.

---

## Настройки, файлы, переменные окружения

### Меню `[S]` Windows

| Пункт | Назначение |
| :--- | :--- |
| 1 | IPv6 приоритет / только IPv4 |
| 2 | Сброс DNS и GEO-кэша |
| 3 | TLS: Auto / только 1.2 / только 1.3 |
| 4 | Debug-лог в файл |
| 5 | Полные ПК/пользователь/пути в логе |
| 6 | Использовать `targets.txt` |
| 7 | Экспорт целей в `targets.txt` |
| 8 | Предупреждение bypass-tools |
| 9 | LAT bars |
| A | Graph charset Blocks / Ascii |
| B | PATH: GraphWidth / MaxHops / Samples |
| 0 | Назад |

Bash `[S]`: пункты **1–7** (без 8/9/A/B).

### Файлы

| Файл | Где | Назначение |
| :--- | :--- | :--- |
| `targets.txt` | Рядом со скриптом | Свой список доменов (UTF-8, `#` комментарии) |
| `YT-DPI_Report.txt` | cwd / рядом | Текстовый отчёт `[R]` / `--report` |
| `YT-DPI_Report.json` | cwd / рядом | JSON (Windows batch / `[R]`) |
| `YT-DPI_Debug.log` | рядом со скриптом | Отладка |
| `YT-DPI_config.json` | `%LOCALAPPDATA%\YT-DPI\` (Win) | Конфиг |
| `config.json` | `~/.config/yt-dpi/` (Bash, нужен jq) | Конфиг |
| `geo_cache.json` | рядом с конфигом | Кэш ISP/CDN |

### Переменные окружения

| Переменная | Эффект |
| :--- | :--- |
| `YT_DPI_DEBUG=1` | Включить debug-лог |
| `YT_DPI_DEBUG_IDENTIFIERS=1` | Полные идентификаторы в заголовке лога |
| `YT_DPI_FORCE_NET_REFRESH=1` | Windows: не использовать устаревший net-кэш |
| `SCRIPT_PATH` | Путь к `.ps1` (ставит `.bat`) |
| `YT_DPI_MAX_JOBS` | Bash: лимит параллелизма |
| `YT_DPI_LIB_ONLY=1` | Bash: только библиотека (тесты/smoke) |

---

## Batch / CLI (Windows)

```bat
YT-DPI.bat --batch [--no-extras] [--json path] [--report path]
YT-DPI.bat --help
```

| Exit | Значение |
| ---: | :--- |
| 0 | Критичных DPI-сигналов нет |
| 1 | Есть DPI RESET/BLOCK, THROTTLED, IP BLOCK и/или плохой EXTRA |
| 2 | Нет интернета / жёсткий сбой запуска |

Подходит для планировщика задач и CI (после ручной проверки политики безопасности хоста).

---

## Типичные проблемы и что делать

| Проблема | Решение |
| :--- | :--- |
| «TLS scanner failed to load» | Обновите до 3.0; проверьте PS 5.1/7; смотрите debug-лог; антивирус |
| Все строки IP BLOCK | Интернет, DNS, VPN/прокси, не пустой кэш; `[S]→2` сброс кэша |
| Картина «всё зелёное», а YouTube плохой | Выключены ли bypass-tools? Смотрите EXTRA QUIC/TCP16 |
| Кириллица кракозябрами | Windows Terminal, UTF-8, `chcp 65001` |
| Таблица «плывёт» | Увеличьте окно консоли; после меню UI должна восстановиться сама |
| Bash: нет сохранения настроек | Установите `jq` |
| Нужен Update | Только Windows `[U]` |
| Нужен DNS/PATH/EXTRA | Только Windows 3.0 |

Сохраняйте **`[R]`** перед тем как слать скриншоты/логи в поддержку.

---

## Ссылки и лицензия

Проект опирается на исследования сообщества DPI:

* [GoodbyeDPI](https://github.com/ValdikSS/GoodbyeDPI) - ValdikSS  
* [Zapret](https://github.com/bol-van/zapret) - bol-van  
* [B4](https://github.com/DanielLavrushin/b4) - DanielLavrushin  
* [dpi-detector](https://github.com/Runnin4ik/dpi-detector) - Runnin4ik

**Лицензия:** MIT. Инструмент только для **диагностики**. Не является средством обхода блокировок.

Канал: [t.me/YT_DPI](https://t.me/YT_DPI) · Поддержка автора: [spasibomir.ru](https://spasibomir.ru/pay/31732)

История версий: [CHANGELOG.md](CHANGELOG.md).
