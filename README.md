# 🚀 Yandex Cloud Handy Scripts

Сборник утилит для автоматизации частых задач в **Yandex Cloud**.
`clone_transfer_with_flags.sh`: скрипт, который **клонирует существующий Data Transfer** в новый, аккуратно конвертирует JSON под REST-формат, позволяет **заменить target endpoint**, **поменять тип трансфера**, **настроить параллелизм**, **подставить соль для маскирующего хеша** и **(опционально) повесить расписание через cron**.

> Требуется установленный и настроенный **Yandex Cloud CLI (`yc`)**, см. раздел «Prerequisites». Установка `yc` — одной командой; начальная настройка — через мастер `yc init`. ([Yandex Cloud][1])

---

## 📦 Содержание

* [Что делает `clone_transfer_with_flags.sh`](#что-делает-clone_transfer_with_flagssh)
* [Prerequisites](#prerequisites)
* [Установка и первичная настройка YC CLI](#установка-и-первичная-настройка-yc-cli)
* [Быстрый старт](#быстрый-старт)
* [Флаги и примеры](#флаги-и-примеры)
* [Замечания и «тонкие места»](#замечания-и-тонкие-места)
* [Траблшутинг](#траблшутинг)
* [Лицензия](#лицензия)

---

## Что делает `clone_transfer_with_flags.sh`

Скрипт берёт **существующий transfer** в Data Transfer и создаёт **новый** на его основе:

* вытягивает исходный `transfer` в JSON (`yc datatransfer transfer get`),
* **преобразует поля** snake\_case → camelCase под REST API (например, `folder_id → folderId`, `source.id → sourceId`, `target.id → targetId`, `runtime.yc_runtime → runtime.ycRuntime`, `data_objects → dataObjects`),
* **заменяет target endpoint** (обязательный флаг `--target-id`),
* по желанию меняет **тип** (`SNAPSHOT_ONLY | INCREMENT_ONLY | SNAPSHOT_AND_INCREMENT`) и **параллелизм** (`jobCount`, `uploadShardParams.jobCount|processCount`),
* если в трансформациях найдено маскирование `maskFunctionHash`, подставляет **соль** (`--salt`) или **генерирует автоматически** (HMAC-SHA256 требует `userDefinedSalt`/`user_defined_salt` в REST/gRPC),
* создаёт новый transfer через `yc datatransfer transfer create --file`,
* **(опционально)** ставит **cron-расписание** для регулярного запуска (полезно для `SNAPSHOT_ONLY` сценариев), создавая маленький раннер-скрипт, который вызывает `yc datatransfer transfer activate <ID>`. ([Yandex Cloud][2])

> ✳️ Встроенного «планировщика» у Data Transfer нет. Для расписаний можно использовать **cron** на вашей машине или **Timer-триггеры Cloud Functions** (cron в UTC). ([Yandex Cloud][3])

---

## Prerequisites

* **bash** (Linux/macOS/WSL),
* **jq** (обработка JSON),
* **openssl** (нужно, если соль для `maskFunctionHash` не передаёте явно),
* **cron** (если хотите ставить расписание локально),
* **Yandex Cloud CLI (`yc`)** установлен и инициализирован:

  * установка: `curl -sSL https://storage.yandexcloud.net/yandexcloud-yc/install.sh | bash` ([Yandex Cloud][1])
  * инициализация: `yc init` (мастер попросит имя профиля, OAuth, облако, каталог, зону) ([Yandex Cloud][4])
  * при необходимости обновите версии компонентов: `yc components update`. ([Yandex Cloud][5])

---

## Установка и первичная настройка YC CLI

1. **Установка**:

```bash
curl -sSL https://storage.yandexcloud.net/yandexcloud-yc/install.sh | bash
```

Перезапустите терминал после установки. ([Yandex Cloud][1])

2. **Инициализация**:

```bash
yc init
```

Мастер поможет создать профиль: токен, облако, папка по умолчанию, зона. ([Yandex Cloud][4])

3. **Выбор облака и каталога (при необходимости)**:

```bash
yc resource-manager cloud list
yc config set cloud-id <CLOUD_ID>

yc resource-manager folder list
yc config set folder-id <FOLDER_ID>
```

Команды `list` показывают доступные облака/каталоги; `yc config set` фиксирует их в активном профиле. ([Yandex Cloud][6])

---

## Быстрый старт

Сделайте файл исполняемым:

```bash
chmod +x clone_transfer_with_flags.sh
```

Простейший кейс — **клонировать** transfer, указав новый target endpoint, имя и описание (тип/параллелизм останутся как в исходном):

```bash
./clone_transfer_with_flags.sh \
  --src-transfer-id dttAAAA... \
  --target-id dteBBBB... \
  --name "my-transfer-copy" \
  --description "Copy with new target"
```

---

## Флаги и примеры

Обязательные:

* `--src-transfer-id <ID>` — исходный transfer
* `--target-id <ID>` — новый endpoint-приёмник
* `--name "<STRING>"` — имя нового transfer
* `--description "<STRING>"` — описание

Необязательные:

* `--type <TYPE>` — `SNAPSHOT_ONLY | INCREMENT_ONLY | SNAPSHOT_AND_INCREMENT` (можно в kebab-case; скрипт нормализует) ([Yandex Cloud][7])
* `--jobs <N>` — `runtime.ycRuntime.jobCount`
* `--upload-jobs <N>` — `runtime.ycRuntime.uploadShardParams.jobCount`
* `--upload-proc <N>` (алиас `--proc`) — `runtime.ycRuntime.uploadShardParams.processCount`
* `--salt "<STRING>"` — соль для `maskFunctionHash.userDefinedSalt` (если трансформер хеширования присутствует) ([Yandex Cloud][8])
* `--schedule "<CRON>"` — установить cron-расписание (например, `0 0 * * *`)
* `--daily "HH:MM"` — шорткат для ежедневного запуска по локальному времени (`--schedule "M H * * *"`)

### Примеры

1. **Сменить тип** на `SNAPSHOT_AND_INCREMENT` и уменьшить `processCount` до 2:

```bash
./clone_transfer_with_flags.sh \
  --src-transfer-id dttOLD \
  --target-id dteNEW \
  --name "rewards-api-v3-data-transfer-2" \
  --description "From MySQL rewards-api-v3 to PG analytics" \
  --type SNAPSHOT_AND_INCREMENT \
  --upload-proc 2
```

2. **SNAPSHOT\_ONLY** по **расписанию** каждый день в 00:00 (локальная TZ хоста с cron):

```bash
./clone_transfer_with_flags.sh \
  --src-transfer-id dttOLD \
  --target-id dteNEW \
  --name "nightly-snapshot" \
  --description "Nightly full copy" \
  --type SNAPSHOT_ONLY \
  --daily "00:00"
```

> Для serverless-расписаний используйте **Timer-триггер Cloud Functions** (cron **в UTC**). ([Yandex Cloud][3])

3. Трансфер c **маскирующим хешем** (HMAC-SHA256): задать соль явно

```bash
./clone_transfer_with_flags.sh \
  --src-transfer-id dttOLD \
  --target-id dteNEW \
  --name "hashed-copy" \
  --description "Copy with masking" \
  --salt "QlFUqjyw18wGhPZ"
```

Если соль не указать, а трансформер `maskFunctionHash` найден — скрипт сгенерирует случайную соль (через `openssl`). Поле обязательно на `create`/`update`, в `get` соль не возвращается по соображениям безопасности. ([Yandex Cloud][8])

---

## Замечания и «тонкие места»

* **Data Transfer CLI**: базовые команды — `transfer get/create/activate`, `endpoint get`. Полный справочник — в официальной документации. ([Yandex Cloud][7])
* **Права и контекст**: `yc` работает в активном профиле/каталоге; переключение делайте командами `yc config set cloud-id`, `yc config set folder-id`. ([Yandex Cloud][9])
* **Cron vs Cloud Functions**: cron использует **локальную** TZ машины, **Timer-триггер** — cron в **UTC**. Для триггеров потребуется сервисный аккаунт и роль для вызова функции. ([Yandex Cloud][3])
* **MaskFunctionHash**: это **HMAC-SHA256** с полем `userDefinedSalt` (REST) / `user_defined_salt` (gRPC). Чтобы хеши совпадали между трансферами, используйте **одну и ту же соль**. ([Yandex Cloud][8])
* **Обновление `yc`**: поддерживайте свежую версию — `yc components update`. ([Yandex Cloud][5])

---

## Траблшутинг

* `ERROR: unknown field "source" in CreateTransferRequest` — вы пытались создать transfer телом из `get` без конвертации. Скрипт как раз выполняет нужный **camelCase-мэппинг** и замену `source/target` на `sourceId/targetId`.
* `Missing required field "user_defined_salt"` — в трансформациях есть `maskFunctionHash`, а соль не указана. Передайте `--salt` или дайте скрипту сгенерировать её (нужен `openssl`). ([Yandex Cloud][8])
* `yc: not found` — установите CLI и инициализируйте профиль (`yc init`). ([Yandex Cloud][1])
* «Не тот каталог/облако» — проверьте активный контекст и при необходимости выполните:

  ```bash
  yc resource-manager cloud list
  yc config set cloud-id <CLOUD_ID>
  yc resource-manager folder list
  yc config set folder-id <FOLDER_ID>
  ```

  ([Yandex Cloud][6])

---

## Лицензия

Укажите вашу лицензию (например, MIT) и файл `LICENSE` в корне репозитория.

---

### Полезные ссылки

* Установка **YC CLI** и быстрый старт: `yc install`, `yc init` ([Yandex Cloud][1])
* Справочник `yc datatransfer` / `transfer create|activate|get` ([Yandex Cloud][7])
* Профили и конфигурация CLI (`yc config set/get`) ([Yandex Cloud][10])
* Список облаков/каталогов (`yc resource-manager cloud|folder list`) ([Yandex Cloud][6])
* Трансформации данных в Data Transfer и `maskFunctionHash.userDefinedSalt` (REST/gRPC) ([Yandex Cloud][11])
* Timer-триггер Cloud Functions (cron в UTC) ([Yandex Cloud][3])

---

Если захочешь — добавлю в репозиторий готовый пример **Cloud Function** + **Timer-триггер** для активации `SNAPSHOT_ONLY` по расписанию и минимальный скрипт проверки статуса (`RUNNING` → пропуск).

[1]: https://yandex.cloud/en/docs/cli/operations/install-cli?utm_source=chatgpt.com "CLI installation | Yandex Cloud - Documentation"
[2]: https://yandex.cloud/en/docs/cli/cli-ref/datatransfer/cli-ref/transfer/get?utm_source=chatgpt.com "yc datatransfer transfer get"
[3]: https://yandex.cloud/en/docs/functions/concepts/trigger/timer?utm_source=chatgpt.com "Timer that invokes a Cloud Functions function"
[4]: https://yandex.cloud/en/docs/cli/quickstart?utm_source=chatgpt.com "Getting started with the command line interface"
[5]: https://yandex.cloud/en/docs/cli/cli-ref/components/cli-ref/?utm_source=chatgpt.com "yc components | Yandex Cloud - Documentation"
[6]: https://yandex.cloud/en/docs/resource-manager/cli-ref/cloud/list?utm_source=chatgpt.com "yc resource-manager cloud list"
[7]: https://yandex.cloud/en/docs/data-transfer/cli-ref/?utm_source=chatgpt.com "yc datatransfer | Yandex Cloud - Documentation"
[8]: https://yandex.cloud/en/docs/data-transfer/api-ref/Transfer/update?utm_source=chatgpt.com "Data Transfer API, REST: Transfer.Update"
[9]: https://yandex.cloud/en/docs/cli/cli-ref/config/cli-ref/set?utm_source=chatgpt.com "yc config set | Yandex Cloud - Documentation"
[10]: https://yandex.cloud/en/docs/cli/cli-ref/config/cli-ref/?utm_source=chatgpt.com "yc config | Yandex Cloud - Documentation"
[11]: https://yandex.cloud/en/docs/data-transfer/concepts/data-transformation?utm_source=chatgpt.com "Data transformation | Yandex Cloud - Documentation"

