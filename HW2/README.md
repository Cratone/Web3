# HW2: сбор на поездку команды

## Версии

| Компонент | Версия |
| --- | --- |
| Solidity | 0.8.30 |
| Foundry: forge, cast, anvil | 1.4.4 |
| forge-std | 1.9.7 |
| OpenZeppelin Contracts | 5.4.0 |
| OpenZeppelin Upgrades Core | 1.44.2 |
| Node.js при проверке | 24.19.0 |
| pnpm | 11.25.0 |
| EVM | Cancun |

Версии npm-зависимостей закреплены в `package.json` и `pnpm-lock.yaml`. `forge-std` загружен из архива релиза, инструменты установлены локально в `.tools`.

## Установка и запуск

Перед установкой нужны Node.js 24, pnpm 11.25.0, Bash, curl и tar, доступные в `PATH`. Скрипт поддерживает macOS (Apple Silicon и Intel) и Linux x86_64. Для первой установки нужен доступ к интернету.

Из корня репозитория:

```bash
cd HW2
node --version
pnpm --version
bash scripts/setup.sh
source scripts/env.sh
```

`setup.sh` загружает Foundry 1.4.4 и Solidity 0.8.30 в `.tools`, проверяет SHA-256 загруженных архивов и компилятора, при отсутствии устанавливает `forge-std` 1.9.7 и выполняет `pnpm install --frozen-lockfile`. Локальные инструменты и npm-зависимости устанавливаются на каждом компьютере отдельно.

Сборка и тесты из папки `HW2`:

```bash
forge build
forge test
```

Дополнительные проверки форматирования и совместимости хранилища V1 → V2:

```bash
forge fmt --check
pnpm run validate:upgrade
```

В каждом новом терминале сначала перейдите в `HW2` и выполните `source scripts/env.sh`: команда добавляет локальные инструменты в `PATH` и выбирает локальный `solc`. После установки сборка и тесты работают без загрузки компилятора из сети (`offline = true` в `foundry.toml`).

## Структура

```text
src/
  TripFundCore.sol       общая логика и учёт
  TripFund.sol           базовый контракт с конструктором
  TripFundV1.sol         реализация для Transparent Proxy
  TripFundV2.sol         обновление с contributeFor
  MockTripToken.sol      ERC-20 для локальных тестов
test/
  TripFund.t.sol         одинаковые проверки базового контракта и прокси V1/V2
  TripFundUpgrade.t.sol  инициализация, обновление, взносы за друга, права администратора
script/
  DeployTripFund.s.sol
  DeployTripFundProxy.s.sol
  UpgradeTripFund.s.sol
scripts/
  env.sh
  setup.sh
  validate-upgrade.sh
```

## Поведение контрактов

TripFund(token, organizer, goal, deadline) задаёт параметры один раз. Нулевые адреса, нулевая цель, текущий или прошедший дедлайн отклоняются. Внешних функций изменения параметров нет. goal и суммы взносов указываются в минимальных единицах токена; deadline — Unix-время в секундах.

contribute(amount) принимает положительный взнос строго до дедлайна. Сначала пользователь вызывает token.approve(address(fund), amount). Фонд обновляет contributions и totalRaised, затем вызывает safeTransferFrom. Ошибка перевода откатывает учёт, балансы и allowance.

Начиная с deadline доступны два взаимоисключающих исхода:

- totalRaised >= goal: организатор один раз вызывает withdraw() и получает ровно totalRaised.
- totalRaised < goal: каждый вкладчик вызывает refund() и получает весь свой вклад. Перед переводом вклад обнуляется.

До дедлайна выплаты запрещены, даже если цель уже достигнута. Флаг withdrawn устанавливается до перевода; неудачная выплата откатывает его. totalRaised остаётся исторической суммой всех принятых взносов и не уменьшается после выплат. При успешном сборе contributions сохраняются для чтения истории; права на возврат при этом нет.

Прямые переводы не меняют учёт и не помогают достичь цели. После вывода или всех возвратов такие токены остаются в контракте. Функции их распределения нет.

События: Contributed(contributor, amount), Refunded(contributor, amount), Withdrawn(organizer, amount).

## Бонус: Transparent Proxy и V2

Для бонусного сценария V1 сразу разворачивается через TransparentUpgradeableProxy OpenZeppelin 5.4.0. Конструктор прокси атомарно вызывает initialize(token, organizer, goal, deadline). Параметры и учёт находятся в storage прокси. Конструкторы обеих реализаций вызывают _disableInitializers(); повторная инициализация прокси и прямая инициализация реализаций отклоняются.

OpenZeppelin 5.x создаёт отдельный ProxyAdmin; его владелец задаётся вторым аргументом конструктора прокси. Обновление выполняет владелец через ProxyAdmin.upgradeAndCall. Адрес организатора сам по себе не даёт права обновления. Скрипт обновления требует, чтобы дедлайн ещё не наступил.

V2 наследует V1 и не добавляет переменных storage. contributeFor(beneficiary, amount) списывает токены у msg.sender, а вклад и право возврата записывает ненулевому beneficiary. Событие ContributedFor(payer, beneficiary, amount) содержит обоих участников и сумму. Обычный contribute продолжает работать.

Все обращения к фонду выполняются по адресу прокси; approve вызывается у токена с адресом прокси как spender.

Проверка хранилища:

```bash
pnpm run validate:upgrade
```

Скрипт сначала запускает forge build --force, чтобы получить полные build-info, затем выполняет:

```bash
node_modules/.bin/openzeppelin-upgrades-core validate out/build-info \
  --contract TripFundV2 --reference TripFundV1 --requireReference
```

Валидация OpenZeppelin проверяет безопасность обновляемой реализации и сравнивает layout V2 с V1. Пропуск проверки storage не используется. Аннотация @custom:oz-upgrades-unsafe-allow constructor разрешает только конструктор, блокирующий инициализацию реализации.

## Проверки

forge test выполняет 105 тестов: 33 для базового контракта, по 29 для прокси V1 и V2 и 14 для бонусного сценария. Девять fuzz-тестов запускаются по 256 раз.

Покрыты все пункты задания:

- проверка начальных параметров; два участника и повторные взносы;
- нулевая сумма, отсутствие/недостаток allowance и недостаточный баланс без изменения учёта и балансов;
- взнос за секунду до дедлайна и запрет ровно в дедлайн;
- запрет ранних выплат, в том числе при достигнутой цели;
- сумма ровно goal, выше и ниже; независимые полные возвраты;
- запрет чужого вывода, повторных выплат и выплат по неверному исходу;
- события и откат при false от токена, включая возможность повторить неудавшуюся выплату;
- прямые переводы остаются после всех положенных выплат;
- взнос в V1, обновление до дедлайна с сохранением адреса, всех параметров, вкладов, totalRaised и баланса токена;
- обычный взнос и взнос за друга после обновления; возврат получает друг;
- запрет чужого обновления и повторной/прямой инициализации.

## Пример approve + взноса

В Solidity для токена с 18 знаками после запятой:

```solidity
token.approve(address(fund), 10 ether); // 10 * 10**18 минимальных единиц ERC-20
fund.contribute(10 ether);
```

ether здесь используется как числовой множитель 10**18; ETH в фонд не отправляется. Для другого числа decimals нужно пересчитать сумму.

Через cast в локальной сети Anvil:

```bash
# Первый терминал, из корня HW2:
source scripts/env.sh
anvil
```

```bash
# Второй терминал, из корня HW2:
source scripts/env.sh
export RPC_URL=http://127.0.0.1:8545
export PARTICIPANT=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
export ORGANIZER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

forge create src/MockTripToken.sol:MockTripToken \
  --rpc-url "$RPC_URL" --unlocked --from "$PARTICIPANT" --broadcast
# Вставьте выведенный адрес Deployed to:
export TOKEN="0x..." # замените на адрес токена
export GOAL=100000000000000000000
export DEADLINE=$(( $(date +%s) + 3600 ))

forge script script/DeployTripFund.s.sol:DeployTripFund \
  --rpc-url "$RPC_URL" --unlocked --sender "$PARTICIPANT" --broadcast
# Вставьте адрес созданного TripFund:
export FUND="0x..." # замените на адрес фонда

cast send "$TOKEN" 'mint(address,uint256)' "$PARTICIPANT" 10000000000000000000 \
  --rpc-url "$RPC_URL" --unlocked --from "$PARTICIPANT"
cast send "$TOKEN" 'approve(address,uint256)' "$FUND" 10000000000000000000 \
  --rpc-url "$RPC_URL" --unlocked --from "$PARTICIPANT"
cast send "$FUND" 'contribute(uint256)' 10000000000000000000 \
  --rpc-url "$RPC_URL" --unlocked --from "$PARTICIPANT"
cast call "$FUND" 'contributions(address)(uint256)' "$PARTICIPANT" --rpc-url "$RPC_URL"
cast call "$FUND" 'totalRaised()(uint256)' --rpc-url "$RPC_URL"
```

Anvil предоставляет эти аккаунты разблокированными. MockTripToken.mint не ограничен: это только тестовый токен.

Для бонусного развёртывания в той же локальной сети:

```bash
export PROXY_ADMIN_OWNER="$PARTICIPANT"
forge script script/DeployTripFundProxy.s.sol:DeployTripFundProxy \
  --rpc-url "$RPC_URL" --unlocked --sender "$PROXY_ADMIN_OWNER" --broadcast
export PROXY="0x..." # адрес прокси из результата скрипта
export PROXY_ADMIN="$(cast admin "$PROXY" --rpc-url "$RPC_URL")"

# Проверить хранилище и обновить тот же прокси до дедлайна:
pnpm run validate:upgrade
forge script script/UpgradeTripFund.s.sol:UpgradeTripFund \
  --rpc-url "$RPC_URL" --unlocked --sender "$PROXY_ADMIN_OWNER" --broadcast
```

PROXY_ADMIN — адрес созданного контракта ProxyAdmin, а PROXY_ADMIN_OWNER — адрес его владельца. Адрес прокси сохраняется после обновления. Для последующих взносов используйте этот адрес как FUND и spender в approve.
