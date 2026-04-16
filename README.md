# FlowDog Order API

Rekrutacyjne zadanie backendowe w `Symfony 7.4` z toolchainem spiętym na `PHP 8.4.20`.

Projekt pokazuje pragmatyczny refaktor dostarczonego kodu zamiast "przepisywania wszystkiego od zera". Zakres został świadomie utrzymany blisko treści zadania: walidacja danych, liczenie ceny, kupony, utworzenie zamówienia, odpowiedź API, lepszy podział odpowiedzialności i sensowniejsza obsługa błędów.

## Krótka notatka do zadania

### 1. Co było największym problemem w tym kodzie?

Największym problemem było skupienie całego flow w jednym kontrolerze: walidacji requestu, logiki biznesowej, pobierania danych produktowych, liczenia rabatów, generowania ID i czasu, persystencji oraz budowy odpowiedzi HTTP. To mieszało odpowiedzialności, utrudniało testowanie i zacierało granicę między błędami klienta, domeny i infrastruktury.

### 2. Co poprawiłem i dlaczego?

- wydzieliłem use case `CreateOrder`, model domenowy i adaptery infrastrukturalne, żeby kontroler został cienką warstwą HTTP
- oparłem wejście o `MapRequestPayload` i `Validator`, żeby walidacja requestu była deklaratywna i spójna z kontraktem API
- uporządkowałem mapowanie błędów na `400`, `404`, `409`, `415`, `422` i `500`, żeby klient dostawał sensowną odpowiedź zamiast jednego worka wyjątków
- wyniosłem zapis do `FileOrderRepository`, katalog do `ProductCatalog`, a czas i ID do portów, żeby logika była testowalna i deterministyczna
- dodałem testy oraz OpenAPI/Swagger, żeby kontrakt był weryfikowalny i łatwy do demonstracji

Szczegóły decyzji są opisane krótko w ADR-ach: [`001-use-symfony-and-light-hexagon.md`](docs/adr/001-use-symfony-and-light-hexagon.md), [`005-tooling-quality-gates.md`](docs/adr/005-tooling-quality-gates.md), [`006-selective-characterization-tests.md`](docs/adr/006-selective-characterization-tests.md), [`007-openapi-swagger-for-demo-testing.md`](docs/adr/007-openapi-swagger-for-demo-testing.md), [`008-no-duplicate-products-in-order-request.md`](docs/adr/008-no-duplicate-products-in-order-request.md).

### 3. Co nadal uprościłem?

- persystencja nadal jest plikowa zamiast bazodanowej
- katalog produktów nadal jest in-memory i istnieje tylko na potrzeby tego use case'u
- `OrderCreated` jest publikowany synchronicznie jako prosty punkt rozszerzeń; obecnie nie ma jeszcze żadnych subscriberów i event pełni rolę przygotowanego hooka pod dalszy rozwój
- ceny są prostymi liczbami całkowitymi
- nie dodawałem autoryzacji, idempotency key, outboxa, rezerwacji stocku ani rozbudowanej obserwowalności

Powiązane trade-offy są opisane w [`003-file-based-persistence.md`](docs/adr/003-file-based-persistence.md), [`004-sync-domain-events.md`](docs/adr/004-sync-domain-events.md) i [`008-no-duplicate-products-in-order-request.md`](docs/adr/008-no-duplicate-products-in-order-request.md).

### 4. Co zrobiłbym inaczej w wersji produkcyjnej?

W wersji produkcyjnej zamieniłbym repozytorium plikowe na `PostgreSQL`, wprowadził `Money` value object z walutą, rozdzieliłbym katalog produktów i stock od modułu zamówień, dodał `idempotency key`, `outbox pattern`, asynchroniczną publikację eventów, sensowne observability, auth oraz rate limiting. Nie robiłem tego tutaj, bo w skali zadania ważniejsza była proporcjonalność rozwiązania niż dokładanie infrastruktury tylko po to, żeby wyglądała "bardziej enterprise".

## Szybki start

### Docker

```bash
docker compose up --build --pull always
```

API będzie dostępne pod `http://localhost:8080/orders`, a Swagger UI pod `http://localhost:8080/api/doc`.
Domyślny lokalny `DEFAULT_URI` jest ustawiony na `http://localhost:8080`, żeby OpenAPI i Swagger `Try it out` wskazywały ten sam adres, pod którym kontener i lokalny serwer są faktycznie wystawione.

Domyślny final image z `Dockerfile` jest runtime'em produkcyjnym: ustawia `APP_ENV=prod`, nie instaluje dev dependencies i nie pakuje katalogu `tests` do artefaktu release. `compose.yaml` nadal uruchamia ten obraz lokalnie z `APP_ENV=dev`, a target `qa` jest używany tylko do kontenerowych testów.

Runtime dodatkowo przycina artefakt tylko do tego, co jest potrzebne w tej aplikacji: nie kopiuje `.env` ani lokalnych plików `templates` (zostawia tylko pusty katalog dla Twiga), zostawia wyłącznie cache produkcyjny oraz usuwa niewykorzystywane UI-e dokumentacji (`Scalar`, `Stoplight`, `Redocly`) i source mapy Swagger UI.

`compose.yaml` wstrzykuje dev-only `APP_SECRET` w runtime. Sam obraz nie bake'uje sekretów i nie kopiuje plików `.env.dev` / `.env.test` do kontekstu buildu.

Jeżeli chcesz uruchomić obraz bez Compose:

```bash
docker build --pull -t flowdog-order-api:local .
docker run --rm \
  -p 8080:8080 \
  -e APP_ENV=prod \
  -e APP_SECRET=prod-secret-for-local-demo \
  -e DEFAULT_URI=http://localhost:8080 \
  flowdog-order-api:local
```

### Produkcyjnie za reverse proxy

Repo zawiera też `compose.prod.yaml` pod prosty deployment gotowego obrazu za reverse proxy. Ten wariant bindowany jest tylko do `127.0.0.1`, wymaga jawnego `DEFAULT_URI` i zapisuje zamówienia do trwałego volume/bind mounta.

Przykładowe `.env`:

```dotenv
APP_SECRET=replace-me
DEFAULT_URI=https://example.com
APP_PORT=8082
IMAGE_REF=flowdog-order-api:prod
ORDERS_DATA_DIR=./data/orders
```

Uruchomienie:

```bash
docker compose --env-file .env -f compose.prod.yaml up -d
```

W tym trybie `DEFAULT_URI` powinno wskazywać publiczny adres za TLS, bo trafia też do `servers[]` w OpenAPI.
Publiczny smoke test odpalaj przez `https://`, nie `http://`. Domena po HTTP może robić redirect do HTTPS, a zwykły klient HTTP może wtedy zgubić semantykę `POST`.

Szybki test wdrożonej instancji:

```bash
make public-smoke BASE_URL=https://example.com
# or:
bash scripts/public_smoke_test.sh --base-url https://example.com
```

### Lokalnie

Zalecany lokalny interpreter: `PHP 8.4.20`, żeby odpowiadać `config.platform` w Composerze, CI i obrazowi Docker. Sam `composer.json` deklaruje zgodność aplikacji z zakresem `>=8.4 <8.5`.

```bash
composer install
php bin/phpunit
php -S 0.0.0.0:8080 -t public
```

Lokalny serwer też korzysta z domyślnego `DEFAULT_URI=http://localhost:8080`, więc `/api/doc` i `/api/doc.json` są spójne z adresem z README.

Opcjonalnie możesz włączyć lokalne hooki git:

```bash
make install-hooks
# or:
bash scripts/install_git_hooks.sh
```

Pre-commit działa tylko na staged plikach, automatycznie formatuje `*.php`, `*.md`, `*.json`, `*.yml`, `*.yaml`, robi szybki lint PHP i celowo nie odpala ciężkiego `qa` przy każdym commicie.

Pre-push odpala pełniejsze checki dla PHP: `PHPUnit` i `Deptrac`. `PHPStan` zostaje w CI i jako ręczny check, żeby hook nie blokował każdego pusha na istniejących problemach statycznej analizy spoza bieżącej zmiany.

## Przykładowe wywołanie

```bash
curl --request POST \
  --url http://localhost:8080/orders \
  --header 'Content-Type: application/json' \
  --data '{
    "customerId": 123,
    "items": [
      {
        "productId": 10,
        "quantity": 2
      }
    ],
    "couponCode": "PROMO10"
  }'
```

Każdy `productId` może pojawić się w `items` najwyżej raz. Duplikaty są odrzucane jako `422 invalid_items`.

Przykładowa odpowiedź:

```json
{
    "id": "0196254c-8ef5-7f62-9c7e-9a45c7392a18",
    "customerId": 123,
    "items": [
        {
            "productId": 10,
            "name": "Keyboard",
            "quantity": 2,
            "price": 120,
            "lineTotal": 240
        }
    ],
    "total": 216,
    "createdAt": "2026-04-11T15:00:00+00:00",
    "couponCode": "PROMO10"
}
```

## Kontrakt HTTP

### Endpointy i format

- `POST /orders`
- request musi mieć `Content-Type: application/json`; inny typ kończy się `415 unsupported_media_type`
- Swagger UI jest dostępny pod `GET /api/doc`
- surowy, pretty-printed OpenAPI JSON jest dostępny pod `GET /api/doc.json`

### Zasady requestu

- `customerId` jest wymaganym dodatnim integerem
- `items` jest wymaganym, niepustym arrayem
- każdy element `items[]` musi zawierać dodatnie integerowe `productId` i `quantity`
- dodatkowe pola na root payloadu są odrzucane jako `400 invalid_request_payload`
- dodatkowe pola wewnątrz `items[]` są odrzucane jako `422 invalid_items`
- ten sam `productId` może wystąpić w requestcie najwyżej raz; duplikaty kończą się `422 invalid_items` już na wejściu do use case'u, przed lookupiem katalogu
- `couponCode` jest opcjonalnym stringiem; rabat naliczają tylko `PROMO10` i `MINUS50`, pusty string jest traktowany jak brak kuponu, a każdy inny niepusty string kończy się `422 invalid_coupon`

### Zasady odpowiedzi

- udane utworzenie zamówienia zwraca `201 Created`
- `id` jest generowany jako UUID v7 w formacie RFC 4122
- `createdAt` jest serializowane w formacie `DATE_ATOM`
- `couponCode` jest pomijane w odpowiedzi tylko wtedy, gdy nie zostało wysłane albo ma wartość `null`
- `PROMO10` obniża subtotal o 10% i zaokrągla wynik do integera przez `round()`
- `MINUS50` odejmuje `50` tylko wtedy, gdy subtotal wynosi co najmniej `300`; poniżej tego progu total pozostaje bez zmian

### Kody błędów

| HTTP  | `code`                    | Kiedy                                                                                                |
| ----- | ------------------------- | ---------------------------------------------------------------------------------------------------- |
| `400` | `malformed_json`          | body nie zawiera poprawnego JSON-a                                                                   |
| `400` | `invalid_request_payload` | payload ma nieoczekiwane pole na root poziomie albo nie daje się zmapować do request DTO             |
| `404` | `product_not_found`       | katalog nie zawiera wskazanego `productId`                                                           |
| `409` | `inactive_product`        | produkt istnieje, ale jest nieaktywny                                                                |
| `409` | `insufficient_stock`      | zamawiana ilość przekracza stock                                                                     |
| `415` | `unsupported_media_type`  | request nie jest wysłany jako JSON                                                                   |
| `422` | `missing_field`           | brakuje wymaganego pola, np. `customerId` albo `items`                                               |
| `422` | `invalid_customer_id`     | `customerId` nie jest dodatnim integerem                                                             |
| `422` | `invalid_product_id`      | `productId` nie jest dodatnim integerem                                                              |
| `422` | `invalid_quantity`        | `quantity` nie jest dodatnim integerem                                                               |
| `422` | `invalid_items`           | `items` nie jest niepustą listą poprawnych linii, zawiera niedozwolone pola albo duplikaty produktów |
| `422` | `invalid_coupon`          | `couponCode` ma zły typ albo nie jest obsługiwany                                                    |
| `500` | `internal_error`          | wystąpił nieoczekiwany błąd infrastruktury lub serwera                                               |

Szczegóły decyzji projektowych i trade-offów są opisane w ADR-ach w `docs/adr`, żeby README zostało krótkie i nie powielało ich treści.

## Struktura projektu

Najważniejsze katalogi i ich rola:

```text
src/
  Order/
    Application/
    Domain/
    Infrastructure/
    UI/Http/
  Shared/
    Domain/Exception/
    UI/Http/
legacy/
  OrderController.php
docs/adr/
tests/
```

## Quality gates

Najkrótszy zestaw lokalnych komend dla części PHP to:

```bash
composer qa
```

Aby ręcznie odpalić dokładnie ten sam zestaw szybkich checków co w pre-commit hooku dla całego repo:

```bash
make precommit
# or:
bash scripts/run_pre_commit_checks.sh --all
```

Pełne checki z hooka `pre-push` możesz odpalić ręcznie tak:

```bash
make prepush
# or:
bash scripts/run_pre_push_checks.sh
```

Najbliższy odpowiednik pełnego CI lokalnie to:

```bash
make qa-ci
```

Target `qa-ci` najpierw sprawdza lokalne narzędzia (`php`, `composer`, `npm`, `docker`, `curl`) i obecność zależności projektu. Jeśli czegoś brakuje, próbuje doinstalować brakujące pakiety przez dostępny package manager oraz uruchamia `composer install` / `npm ci` przed właściwymi krokami QA.

Jeżeli chcesz uruchomić testy PHP w kontenerze zamiast na hoście, użyj dedykowanego targetu QA:

```bash
make docker-test
```

Jeżeli chcesz sprawdzić już wdrożoną, publicznie dostępną instancję pod kątem `/api/doc.json` i przykładowego `POST /orders`, użyj:

```bash
make public-smoke BASE_URL=https://example.com
```

Jeżeli chcesz odpalić kroki ręcznie, podstawowy zestaw komend używanych w repo wygląda tak:

```bash
composer validate --strict
php bin/phpunit
php vendor/bin/phpstan analyse --memory-limit=1G
php vendor/bin/php-cs-fixer fix --dry-run --diff --verbose
php vendor/bin/deptrac analyse --no-progress
npm ci
composer audit
npm run format:check
docker build --pull --target runtime -t flowdog-order-api:ci .
```

W `CI` dochodzą jeszcze:

- jawny check patch version dla `PHP 8.4.20`,
- smoke test produkcyjnego runtime image pod `GET /api/doc.json` oraz przykładowy `POST /orders` z asercją zapisu zamówienia w kontenerze,
- asercja, że runtime image domyślnie startuje z `APP_ENV=prod` i nie zawiera dev-only artefaktów, takich jak `vendor/bin/phpunit` czy katalog `tests`,
- skan `Trivy` typu filesystem dla repo,
- skan `Trivy` zbudowanego obrazu Docker.

Osobny workflow `Release` uruchamia się dla tagów `v*`, buduje produkcyjny target `runtime`, skanuje go i publikuje tagi do `GHCR`.

## ADR

ADR-y znajdują się w `docs/adr`.

Najważniejsze świadome decyzje architektoniczne i projektowe zostały opisane jawnie, zgodnie z założeniem projektu:

- [`001-use-symfony-and-light-hexagon.md`](docs/adr/001-use-symfony-and-light-hexagon.md)
- [`002-no-cqrs.md`](docs/adr/002-no-cqrs.md)
- [`003-file-based-persistence.md`](docs/adr/003-file-based-persistence.md)
- [`004-sync-domain-events.md`](docs/adr/004-sync-domain-events.md)
- [`005-tooling-quality-gates.md`](docs/adr/005-tooling-quality-gates.md)
- [`006-selective-characterization-tests.md`](docs/adr/006-selective-characterization-tests.md)
- [`007-openapi-swagger-for-demo-testing.md`](docs/adr/007-openapi-swagger-for-demo-testing.md)
- [`008-no-duplicate-products-in-order-request.md`](docs/adr/008-no-duplicate-products-in-order-request.md)
