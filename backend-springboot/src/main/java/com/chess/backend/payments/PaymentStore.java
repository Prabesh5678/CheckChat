package com.chess.backend.payments;

import org.springframework.stereotype.Component;

import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Plain in-memory store — direct port of orderStore.js / coinStore.js
 * (via payments/store.py in the Django version). No database: balances and
 * orders reset on every restart, matching the original Node behavior
 * exactly, since this app has no real usage of persisted coin balances.
 */
@Component
public class PaymentStore {

    private final Map<String, Order> orders = new ConcurrentHashMap<>();
    private final Map<String, Integer> balances = new ConcurrentHashMap<>();
    private final Set<String> processedOrders = ConcurrentHashMap.newKeySet();

    public Order createOrder(String deviceId, String packageId, String gateway) {
        String orderId = UUID.randomUUID().toString();
        Order order = new Order(orderId, deviceId, packageId, gateway);
        orders.put(orderId, order);
        return order;
    }

    public Order getOrder(String orderId) {
        if (orderId == null) return null;
        return orders.get(orderId);
    }

    public void markOrderStatus(String orderId, String status) {
        Order order = orders.get(orderId);
        if (order != null) {
            order.setStatus(status);
        }
    }

    public int getBalance(String deviceId) {
        return balances.getOrDefault(deviceId, 0);
    }

    /**
     * Idempotent credit — mirrors creditOnce() in coinStore.js. Synchronized
     * so a concurrent double-callback from the payment gateway can't credit
     * the same order twice.
     */
    public synchronized int creditOnce(String deviceId, String orderId, int amount) {
        if (!processedOrders.add(orderId)) {
            return balances.getOrDefault(deviceId, 0);
        }
        return balances.merge(deviceId, amount, Integer::sum);
    }
}
