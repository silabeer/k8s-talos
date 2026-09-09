# Waypoint: управление трафиком и трассировка

ztunnel работает на L4: даёт mTLS, идентичность, политики по идентичности и
сетевые метрики, но в HTTP не заглядывает. Всё, что требует разбора запроса —
маршрутизация по заголовкам, таймауты, ретраи, размыкатели, трассировка —
живёт на waypoint. Это отдельный Envoy, который встаёт в путь только для
выбранного трафика и только на стороне назначения.

Документ описывает, что уже развёрнуто на стенде, и как добавлять остальное.

## Что развёрнуто

В `kubernetes/apps/mesh-demo/`:

| Файл | Что делает |
| --- | --- |
| `templates/waypoint.yaml` | `Gateway` класса `istio-waypoint`, имя `waypoint` |
| `templates/namespace.yaml` | метки `istio.io/dataplane-mode` и `istio.io/use-waypoint` |
| `templates/httproute.yaml` | маршрутизация по заголовку `x-cluster` в конкретный кластер |
| `templates/authorizationpolicy.yaml` | waypoint обязателен: поды принимают только его идентичность |
| `templates/telemetry.yaml` | трассировка на waypoint, провайдер `otel` |

Провайдер трассировки объявлен в `kubernetes/infrastructure/istio/values.yaml`
(`meshConfig.extensionProviders`), приёмник — `kubernetes/infrastructure/jaeger/`.

Имя waypoint обязано совпадать во всех кластерах меша: ambient-мультикластер
сопоставляет их по имени, и синхронизация лежит на вас, то есть на GitOps.

## Как включается

Два шага, оба через Gateway API.

1. Развернуть прокси: `Gateway` с `gatewayClassName: istio-waypoint`.
   Метка `istio.io/waypoint-for` задаёт, какой трафик он обслуживает:
   `service` (по умолчанию), `workload`, `all`, `none`.
2. Направить трафик: метка `istio.io/use-waypoint: <имя>` на неймспейсе,
   сервисе или поде. Метка на сервисе перекрывает метку на неймспейсе,
   на поде — обе.

Путь запроса: ztunnel клиента, waypoint назначения, ztunnel назначения, под.
Клиент ничего не знает, вся конфигурация на стороне назначения.

## Три ловушки

**Метка не гарантирует прохождение.** Если waypoint не существует, у него нет
адреса или тип трафика не совпадает с тем, что он обслуживает, ztunnel
отправит запрос напрямую, а не вернёт ошибку. Политики L7 при этом молча не
применятся. Лечится политикой, которая разрешает подам принимать соединения
только от идентичности waypoint — она в `authorizationpolicy.yaml`.

**Выбор waypoint идёт по исходному адресу назначения.** Запрос на сервис без
waypoint туда не попадёт, даже если у пода, куда он придёт, waypoint есть.

**Трафик от ingress-шлюза waypoint по умолчанию не проходит.** Нужна метка
`istio.io/ingress-use-waypoint: "true"` на сервисе или неймспейсе.

## Маршрутизация

`HTTPRoute` привязывается к сервису назначения, а не к шлюзу:

```yaml
spec:
  parentRefs:
    - group: ""
      kind: Service
      name: mesh-demo
      port: 80
```

Правило можно привязать и ко всему waypoint, указав в `parentRefs` объект
`Gateway`: тогда оно действует на весь трафик, который через него идёт.

Статус в Istio 1.30: `HTTPRoute` — beta, `TLSRoute` и `TCPRoute` — alpha.

Приём, которым сделана маршрутизация в конкретный кластер: сервис разложен на
три. `mesh-demo` выбирает поды любого кластера, `mesh-demo-east` и
`mesh-demo-west` существуют в обоих кластерах, но endpoint есть только у
своего. Обращение к `mesh-demo-west` из `east` гарантированно уходит через
east-west gateway.

## Таймауты

Поле `timeouts` прямо в правиле `HTTPRoute`:

```yaml
  rules:
    - backendRefs:
        - group: ""
          kind: Service
          name: mesh-demo
          port: 80
      timeouts:
        request: 3s          # весь запрос, включая ретраи
        backendRequest: 1s   # одна попытка к бэкенду
```

## Ретраи

Здесь есть развилка, и её нужно проверить под свою версию Istio.

В Gateway API ретраи описываются полем `rules[].retry` (`codes`, `attempts`,
`backoff`). Поддержку этого поля в конкретной версии Istio нужно проверить
перед тем, как на неё опираться: раньше ретраи настраивались только через
`VirtualService`.

Классический способ, работающий наверняка:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: mesh-demo
spec:
  hosts:
    - mesh-demo.mesh-demo.svc.cluster.local
  http:
    - retries:
        attempts: 3
        perTryTimeout: 1s
        retryOn: 5xx,connect-failure,refused-stream
      route:
        - destination:
            host: mesh-demo.mesh-demo.svc.cluster.local
```

Важное ограничение: `VirtualService` в ambient имеет статус alpha, и
**смешивать его с конфигурацией Gateway API для одного и того же сервиса
нельзя** — поведение не определено. То есть либо весь сервис описан через
`HTTPRoute`, либо через `VirtualService`.

## Размыкатели и пулы соединений

У Gateway API аналога нет, это `DestinationRule`:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: mesh-demo
spec:
  host: mesh-demo.mesh-demo.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100
        connectTimeout: 1s
      http:
        http2MaxRequests: 200
        maxRequestsPerConnection: 10
        # Ограничивает очередь: сверх лимита запросы отбрасываются сразу,
        # а не копятся, создавая лавину.
        http1MaxPendingRequests: 32
    outlierDetection:
      # Пять ошибок подряд — endpoint выводится из балансировки на минуту.
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 1m
      maxEjectionPercent: 50
```

`outlierDetection` — это и есть размыкатель в терминах Istio: он временно
исключает нездоровые endpoint'ы, а `connectionPool` ограничивает нагрузку на
здоровые. В мультикластере это же средство обеспечивает переход на соседний
кластер: когда локальные endpoint'ы исключены, остаются удалённые.

## Трассировка

Провайдер объявляется один раз в meshConfig istiod:

```yaml
meshConfig:
  extensionProviders:
    - name: otel
      opentelemetry:
        service: jaeger-collector.jaeger.svc.cluster.local
        port: 4317
```

Включается точечно ресурсом `Telemetry` рядом с приложением. Две вещи, на
которых мы потеряли время:

**`Telemetry` без `targetRefs` применяется к ztunnel**, а тот работает на L4 и
спанов не создаёт: трассировка молча не появляется. Привязка к waypoint
обязательна, ровно как у политик авторизации уровня L7.

**Имя порта коллектора должно начинаться с `grpc-`.** Istio определяет
протокол по префиксу имени порта. С именем `otlp-grpc` Envoy отправлял OTLP по
HTTP/1.1, и Jaeger писал `received bogus greeting from client`: спаны уходили,
но не принимались.

Приложения обязаны пробрасывать заголовки контекста трассировки между входящим
и исходящим запросом. Меш этого за них не делает, и без этого спаны не
склеятся в одну цепочку.

Что видно на стенде после включения:

```
mesh-demo-west.mesh-demo.svc.cluster.local:80/*   18912 мкс  200  GET
mesh-demo.mesh-demo.svc.cluster.local:80/*         1904 мкс  200  GET
```

Локальный вызов около двух миллисекунд, вызов в соседний кластер через шлюз
почти девятнадцать. UI: `kubectl -n jaeger port-forward svc/jaeger-ui 16686:80`.

## Метрики

Waypoint отдаёт полный набор метрик трафика Istio. Отдельной настройки не
требуется, но Prometheus на стенде не развёрнут: сейчас метрики можно смотреть
только с самого пода waypoint.

## Что ещё умеет waypoint

Из того, что не понадобилось, но доступно: `RequestAuthentication` для
проверки JWT, расширение через Lua (`TrafficExtension`) и WebAssembly
(`WasmPlugin`) — оба в статусе alpha, привязка через `targetRefs`.

## Цена

Waypoint — это ещё один Envoy на каждый неймспейс или сервис, где он включён.
На узлах стенда 2 ядра и 4 ГБ, поэтому включать его стоит там, где нужны
именно возможности L7. Для связности и шифрования достаточно ztunnel.
