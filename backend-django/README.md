# Chess backend — Django port

## Swapping in this folder

This `backend/` folder is a drop-in replacement for the old Node one — same
name, same position in the repo. To move to a new branch:

```bash
git checkout -b django-backend
rm -rf backend                 # delete the old Node backend
# copy this new backend/ folder into its place
git add backend
git commit -m "Replace Node backend with Django port"
```

`.gitignore` already excludes `venv/`, `db.sqlite3`, `__pycache__/`, and `.env`
— the Django equivalents of what `node_modules` and `.env` exclusions did for
the Node version.


Port of the original Express + `ws` backend to Django. Two pieces:

- **`payments`** — regular Django views for the eSewa/Khalti coin-purchase flow.
- **`chess_game`** — the realtime chess game, using **Django Channels** (ASGI)
  for WebSockets, since Django has no built-in WebSocket support the way
  Node's `ws` library does.

## Setup

```bash
cd chess_django
python -m venv venv
source venv/bin/activate  # venv\Scripts\activate on Windows
pip install -r requirements.txt

cp .env.example .env       # then fill in ESEWA_SECRET_KEY / KHALTI_SECRET_KEY

python manage.py makemigrations payments
python manage.py migrate
python manage.py runserver 0.0.0.0:8000
```

No `makemigrations`/`migrate` step is needed — this version uses a plain in-memory store (see below), matching the original Node behavior exactly.


## Endpoint mapping

| Original (Express)                          | Django                                       |
|---|---|
| `GET /api/payments/balance/:deviceId`       | `GET /api/payments/balance/<device_id>/`     |
| `POST /api/payments/initiate`               | `POST /api/payments/initiate/`               |
| `GET /api/payments/esewa/form/:orderId`     | `GET /api/payments/esewa/form/<uuid>/`       |
| `GET /api/payments/esewa/return`            | `GET /api/payments/esewa/return/`            |
| `GET /api/payments/khalti/return`           | `GET /api/payments/khalti/return/`           |
| `GET /health`                               | `GET /health/`                               |
| `ws://host:8080` (raw ws)                   | `ws://host:8000/ws/chess/`                   |

Update your frontend's WebSocket URL and `PUBLIC_BASE_URL` accordingly.

## What changed under the hood

- **`orderStore.js`/`coinStore.js` → `payments/store.py`.** Ported almost
  directly: plain Python dicts/sets held in process memory, guarded by a
  `threading.Lock` (Node's single-threaded event loop didn't need one, but
  Channels/ASGI can run handlers across threads). No database is used —
  balances and orders reset on every restart, exactly like the original.
- **`ws` raw sockets → Channels consumers.** `ChessConsumer` (one instance per
  connection) replaces a raw `ws` socket. `GameManager` and `Game` are ported
  almost line-for-line, just with `async def` methods and `await socket.send(...)`
  instead of `socket.send(...)`.
- **`chess.js` → `python-chess`.** Move validation/game-over detection is
  reimplemented with `python-chess`'s `Board` API. Moves can still arrive as
  either a SAN string (`"Nf3"`) or a `{from, to, promotion}` object — both are
  handled in `chess_game/game.py`'s `_parse_move`.
- **Manual ping/pong keepalive removed.** The original `setInterval` ping loop
  in `index.js` was there to detect dead `ws` connections manually; Channels/
  Daphne handle connection liveness themselves, so it's not ported.
- **Single-process assumption preserved.** `game_manager` is a module-level
  singleton, matching the original single-process Node server. If you ever
  run multiple Daphne workers or replicas, matchmaking state needs to move to
  a shared backend (e.g. Redis via `channels_redis`) since in-memory Python
  objects won't be shared across processes.

## Note for the Spring Boot port later

Keep this Django version around as the reference implementation — the models
(`Order`, `CoinBalance`), the view/consumer boundary, and the `Game`/`GameManager`
split all map cleanly onto Spring's Controller + Entity/Repository +
`WebSocketHandler` equivalents.
