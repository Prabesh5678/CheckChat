import { randomUUID } from "crypto";

export const COIN_PACKAGES = {
  small: { coins: 100, npr: 10, label: "100 Coins" },
  medium: { coins: 500, npr: 40, label: "500 Coins" },
  large: { coins: 1000, npr: 70, label: "1000 Coins" },
};

export function getPackage(packageId) {
  return COIN_PACKAGES[packageId] ?? null;
}

const orders = new Map();

export function createOrder({ deviceId, packageId, gateway }) {
  const orderId = randomUUID();
  orders.set(orderId, {
    orderId,
    deviceId,
    packageId,
    gateway,
    status: "pending",
    createdAt: Date.now(),
  });
  return orderId;
}

export function getOrder(orderId) {
  return orders.get(orderId) ?? null;
}

export function markOrderStatus(orderId, status) {
  const order = orders.get(orderId);
  if (!order) return null;
  order.status = status;
  return order;
}
