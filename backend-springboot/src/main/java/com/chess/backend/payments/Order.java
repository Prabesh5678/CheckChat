package com.chess.backend.payments;

import java.time.Instant;

public class Order {
    private final String orderId;
    private final String deviceId;
    private final String packageId;
    private final String gateway;
    private volatile String status;
    private final Instant createdAt;

    public Order(String orderId, String deviceId, String packageId, String gateway) {
        this.orderId = orderId;
        this.deviceId = deviceId;
        this.packageId = packageId;
        this.gateway = gateway;
        this.status = "pending";
        this.createdAt = Instant.now();
    }

    public String getOrderId() { return orderId; }
    public String getDeviceId() { return deviceId; }
    public String getPackageId() { return packageId; }
    public String getGateway() { return gateway; }
    public String getStatus() { return status; }
    public void setStatus(String status) { this.status = status; }
    public Instant getCreatedAt() { return createdAt; }
}
