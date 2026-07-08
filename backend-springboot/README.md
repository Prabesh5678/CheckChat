# Chess backend — Spring Boot port

Third implementation of the same backend (Node → Django → Spring Boot), same
frontend, no code changes needed on the Flutter side if you configure things
the same way as the other two.

## Setup

You'll need **Java 17+** and **Maven** installed (unlike Node/Python, Java
projects don't bundle their tool — check with `java -version` and
`mvn -version`; if Maven isn't installed, get it from
https://maven.apache.org/download.cgi or via an IDE like IntelliJ, which
bundles its own).

```powershell
cd backend-springboot
copy .env.example .env
# then open .env and fill in KHALTI_SECRET_KEY (ESEWA_SECRET_KEY is already
# set to the public eSewa sandbox test key)

mvn clean install
mvn spring-boot:run
```

That last command starts the server on port 8080 (same as before) — both the
REST payment endpoints and the WebSocket are served from that one process,
same as the Node and Django versions.

`.env` is loaded automatically via the `spring-dotenv` dependency — no extra
setup needed, same convenience the Node/Django versions had.

## Endpoint mapping (unchanged across all three backends)

| Endpoint | Notes |
|---|---|
| `GET /health` | |
| `GET /api/payments/balance/{deviceId}` | |
| `POST /api/payments/initiate` | |
| `GET /api/payments/esewa/form/{orderId}` | |
| `GET /api/payments/esewa/return` | |
| `GET /api/payments/khalti/return` | |
| `ws://host:8080` (bare root, no path) | matches `WS_URL` as-is |

Every REST route is registered both with and without a trailing slash — a
Node/Express-vs-Django lesson learned earlier in this project — so whatever
the frontend sends works without needing frontend changes.

## File mapping (Node → Django → Spring Boot)

| Node | Django | Spring Boot |
|---|---|---|
| `index.js` | `manage.py` + `config/asgi.py` | `BackendApplication.java` + `config/WebSocketConfig.java` |
| `.env` | `.env` | `.env` (via spring-dotenv) |
| `store/orderStore.js` + `store/coinStore.js` | `payments/store.py` | `payments/PaymentStore.java` + `Order.java` + `CoinPackages.java` |
| `routes/payment.route.js` | `payments/views.py` + `urls.py` | `payments/PaymentsController.java` |
| `game.js` | `chess_game/game.py` | `chess/Game.java` |
| `gameManager.js` | `chess_game/game_manager.py` | `chess/GameManager.java` |
| raw `ws` connection handling | `chess_game/consumers.py` | `chess/ChessWebSocketHandler.java` |
| n/a | `chess_game/routing.py` | `config/WebSocketConfig.java` |
| `package.json` | `requirements.txt` | `pom.xml` |

## What changed under the hood

- **No database, same as the Django version's final state.** `PaymentStore`
  is a plain in-memory `ConcurrentHashMap`-based store — balances and orders
  reset on every restart, matching the original Node behavior. A
  `synchronized` method handles idempotent crediting, replacing the `Set` of
  processed order IDs from `coinStore.js`.
- **`chess.js` → `chesslib`** (`com.github.bhlangonijr:chesslib`). Move
  validation and game-over detection (`isMated`, `isStaleMate`,
  `isInsufficientMaterial`, `isRepetition`, half-move counter for the 50-move
  rule) are all done through this library's `Board` API.
- **CORS and the WebSocket root-path mapping** are explicit `@Configuration`
  classes (`CorsConfig`, `WebSocketConfig`) — Spring doesn't have permissive
  defaults the way Express's bare `cors()` or Django's `CORS_ALLOW_ALL_ORIGINS`
  do, so this had to be spelled out.
- **Logging:** deliberately left as Spring Boot's untouched default. The
  Django port hit a real bug where an extra custom logging handler caused
  every line to print twice — don't add a second handler/appender here for
  the same reason.

## Known caveat — move format

`Game.java`'s `tryMove()` accepts moves as either a `{from, to, promotion}`
JSON object, or a short UCI string like `"e2e4"`/`"e7e8q"`. It does **not**
parse full SAN strings like `"Nf3"`. If your frontend's chess.js integration
sends moves as SAN, you have two options:
1. Change the frontend to send `{from, to, promotion}` — this is the more
   robust format anyway, and what the Django/Python version primarily relied
   on too.
2. Add SAN parsing here using chesslib's move-generation utilities (generate
   all legal moves, convert each to SAN, and match against the incoming
   string) — left out of this initial port since chesslib's exact SAN-utility
   API should be double-checked against whatever version Maven resolves,
   rather than guessed at without a live build to verify against.

## Honesty note on this port

Unlike the Node and Django versions, I could not actually compile or run this
Spring Boot project in this environment (no Java/Maven available here) — the
code is written carefully against chesslib's documented API surface, but you
should run `mvn clean compile` first and treat any compiler errors as the
next debugging step, the same way we worked through the Django port's runtime
issues together. Likely first candidates for a mismatch: the exact `chesslib`
version pin in `pom.xml`, and the `Piece`/`Square` enum value names.
