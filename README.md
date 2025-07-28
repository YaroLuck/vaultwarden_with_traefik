## Как сделать бекап данных vaultwarden

Основное, что нужно сохранить - база данных sqlite.

Дополнительно можно почитать [здесь](https://github.com/dani-garcia/vaultwarden/wiki/Backing-up-your-vault)

### Ручной режим

1. Подключитесь к серверу и запустите команду:

```
docker exec -it vaultwarden /vaultwarden backup
```

Ожидаемый результат:

```
Backup to 'data/db_20250609_085940.sqlite3' was successful
```

2. Перейдите в директорию

```
cd /docker/traefik/vaultwarden
```

3. Скопируйте файлы в хранилище бекапов:

```
attachments\
sends\
config.json
db_<дата_время>.sqlite3
rsa_key.pem
```
