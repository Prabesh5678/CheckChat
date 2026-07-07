"""In-memory stores, ported directly from orderStore.js + coinStore.js.

No database — this intentionally mirrors the original Node behavior:
everything lives in process memory and resets on every server restart.
"""

import threading
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone

COIN_PACKAGES = {
    "small": {"coins": 100, "npr": 10, "label": "100 Coins"},
    "medium": {"coins": 500, "npr": 40, "label": "500 Coins"},
    "large": {"coins": 1000, "npr": 70, "label": "1000 Coins"},
}


def get_package(package_id):
    return COIN_PACKAGES.get(package_id)


@dataclass
class Order:
    order_id: str
    device_id: str
    package_id: str
    gateway: str
    status: str = "pending"
    created_at: datetime = None

    def package(self):
        return get_package(self.package_id)


# module-level state + a lock, since ASGI/Channels can run handlers
# concurrently across threads (unlike Node's single-threaded event loop)
_lock = threading.Lock()
_orders: dict[str, Order] = {}
_balances: dict[str, int] = {}
_processed_orders: set[str] = set()


def create_order(device_id, package_id, gateway):
    order_id = str(uuid.uuid4())
    order = Order(
        order_id=order_id,
        device_id=device_id,
        package_id=package_id,
        gateway=gateway,
        status="pending",
        created_at=datetime.now(timezone.utc),
    )
    with _lock:
        _orders[order_id] = order
    return order


def get_order(order_id):
    with _lock:
        return _orders.get(str(order_id))


def mark_order_status(order_id, status):
    with _lock:
        order = _orders.get(str(order_id))
        if order:
            order.status = status
        return order


def get_balance(device_id):
    with _lock:
        return _balances.get(device_id, 0)


def credit_once(device_id, order_id, amount):
    """Idempotent credit — mirrors creditOnce() in the original coinStore.js,
    using a Set of processed order IDs rather than a DB row lock."""
    with _lock:
        if order_id in _processed_orders:
            return _balances.get(device_id, 0)
        _processed_orders.add(order_id)
        next_balance = _balances.get(device_id, 0) + amount
        _balances[device_id] = next_balance
        return next_balance
