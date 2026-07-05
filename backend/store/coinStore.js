const balances = new Map(); // deviceId -> integer coin balance
const processedOrders = new Set(); // orderIds already credited, for idempotency

export function getBalance(deviceId) {
  return balances.get(deviceId) ?? 0;
}
export function creditOnce(deviceId, orderId, amount) {
  if (processedOrders.has(orderId)) {
    return balances.get(deviceId) ?? 0;
  }
  processedOrders.add(orderId);
  const next = (balances.get(deviceId) ?? 0) + amount;
  balances.set(deviceId, next);
  return next;
}

export function wasOrderProcessed(orderId) {
  return processedOrders.has(orderId);
}
