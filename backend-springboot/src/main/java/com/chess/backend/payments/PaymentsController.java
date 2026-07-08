package com.chess.backend.payments;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.client.RestTemplate;
import org.springframework.web.util.UriComponentsBuilder;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;

@RestController
@RequestMapping("/api/payments")
public class PaymentsController {

    private static final Logger log = LoggerFactory.getLogger(PaymentsController.class);

    private final PaymentStore store;
    private final RestTemplate restTemplate;
    private final ObjectMapper mapper = new ObjectMapper();

    @Value("${app.public-base-url}")
    private String publicBaseUrl;

    @Value("${app.esewa.product-code}")
    private String esewaProductCode;

    @Value("${app.esewa.secret-key}")
    private String esewaSecretKey;

    @Value("${app.esewa.form-url}")
    private String esewaFormUrl;

    @Value("${app.esewa.status-url}")
    private String esewaStatusUrl;

    @Value("${app.khalti.secret-key}")
    private String khaltiSecretKey;

    @Value("${app.khalti.base-url}")
    private String khaltiBaseUrl;

    public PaymentsController(PaymentStore store, RestTemplate restTemplate) {
        this.store = store;
        this.restTemplate = restTemplate;
    }

    // ── balance lookup ──

    @GetMapping({"/balance/{deviceId}", "/balance/{deviceId}/"})
    public Map<String, Object> balanceLookup(@PathVariable String deviceId) {
        log.info("[payments] balance lookup for deviceId={}", deviceId);
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("deviceId", deviceId);
        body.put("balance", store.getBalance(deviceId));
        return body;
    }

    // ── generic initiate dispatcher ──

    @PostMapping({"/initiate", "/initiate/"})
    public ResponseEntity<Map<String, Object>> initiate(@RequestBody Map<String, Object> body) {
        Object gatewayObj = body.get("gateway");
        Object packageIdObj = body.get("packageId");
        Object deviceIdObj = body.get("deviceId");

        if (gatewayObj == null || packageIdObj == null || deviceIdObj == null) {
            return ResponseEntity.badRequest().body(errorBody("Missing required fields"));
        }

        String gateway = gatewayObj.toString();
        String packageId = packageIdObj.toString();
        String deviceId = deviceIdObj.toString();

        log.info("[payments] initiate for deviceId={}, packageId={}, gateway={}", deviceId, packageId, gateway);

        CoinPackages.Package pkg = CoinPackages.get(packageId);
        if (pkg == null) {
            return ResponseEntity.badRequest().body(errorBody("unknown packageId: " + packageId));
        }

        if (gateway.equals("esewa")) {
            Order order = store.createOrder(deviceId, packageId, "esewa");
            log.info("esewa orderId: {}", order.getOrderId());
            Map<String, Object> resp = new LinkedHashMap<>();
            resp.put("orderId", order.getOrderId());
            resp.put("redirectUrl", publicBaseUrl + "/api/payments/esewa/form/" + order.getOrderId());
            return ResponseEntity.ok(resp);
        }

        if (gateway.equals("khalti")) {
            return initiateKhalti(deviceId, packageId, pkg);
        }

        return ResponseEntity.badRequest().body(errorBody("unknown gateway: " + gateway));
    }

    // ══════════════════════════════════════════════════════════════════
    // eSewa
    // ══════════════════════════════════════════════════════════════════

    private String esewaSignature(String totalAmount, String transactionUuid, String productCode) {
        if (esewaSecretKey == null || esewaSecretKey.isBlank()) {
            throw new IllegalStateException(
                    "ESEWA_SECRET_KEY is not set — for the eSewa sandbox (EPAYTEST), " +
                            "set it to the test secret key: 8gBm/:&EnhH.1/q");
        }
        try {
            String message = "total_amount=" + totalAmount + ",transaction_uuid=" + transactionUuid
                    + ",product_code=" + productCode;
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(esewaSecretKey.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
            byte[] digest = mac.doFinal(message.getBytes(StandardCharsets.UTF_8));
            return Base64.getEncoder().encodeToString(digest);
        } catch (Exception e) {
            throw new RuntimeException("Failed to compute eSewa signature", e);
        }
    }

    @GetMapping(value = {"/esewa/form/{orderId}", "/esewa/form/{orderId}/"}, produces = MediaType.TEXT_HTML_VALUE)
    public ResponseEntity<String> esewaForm(@PathVariable String orderId) {
        Order order = store.getOrder(orderId);
        if (order == null) {
            return ResponseEntity.status(404).body("Unknown order.");
        }

        CoinPackages.Package pkg = CoinPackages.get(order.getPackageId());
        String totalAmount = String.format("%.2f", (double) pkg.npr()); // eSewa wants e.g. "10.00"
        String transactionUuid = order.getOrderId();

        String signature = esewaSignature(totalAmount, transactionUuid, esewaProductCode);

        String successUrl = publicBaseUrl + "/api/payments/esewa/return";
        String failureUrl = publicBaseUrl + "/api/payments/esewa/return?order=" + order.getOrderId() + "&canceled=1";

        String html = """
                <!DOCTYPE html>
                <html>
                  <body>
                    <form id="esewaForm" action="%s" method="POST">
                      <input type="hidden" name="amount" value="%s" />
                      <input type="hidden" name="tax_amount" value="0" />
                      <input type="hidden" name="total_amount" value="%s" />
                      <input type="hidden" name="transaction_uuid" value="%s" />
                      <input type="hidden" name="product_code" value="%s" />
                      <input type="hidden" name="product_service_charge" value="0" />
                      <input type="hidden" name="product_delivery_charge" value="0" />
                      <input type="hidden" name="success_url" value="%s" />
                      <input type="hidden" name="failure_url" value="%s" />
                      <input type="hidden" name="signed_field_names" value="total_amount,transaction_uuid,product_code" />
                      <input type="hidden" name="signature" value="%s" />
                    </form>
                    <script>document.getElementById('esewaForm').submit();</script>
                  </body>
                </html>"""
                .formatted(esewaFormUrl, totalAmount, totalAmount, transactionUuid, esewaProductCode,
                        successUrl, failureUrl, signature);

        return ResponseEntity.ok(html);
    }

    @GetMapping(value = {"/esewa/return", "/esewa/return/"}, produces = MediaType.TEXT_HTML_VALUE)
    public ResponseEntity<String> esewaReturn(@RequestParam(required = false) String data) {
        if (data == null || data.isBlank()) {
            return ResponseEntity.badRequest().body("Missing payment data");
        }

        JsonNode decoded;
        try {
            byte[] decodedBytes = Base64.getDecoder().decode(data);
            decoded = mapper.readTree(new String(decodedBytes, StandardCharsets.UTF_8));
        } catch (Exception e) {
            return ResponseEntity.badRequest().body("Malformed payment data");
        }

        String orderId = decoded.path("transaction_uuid").asText(null);
        Order order = store.getOrder(orderId);
        log.info("Order: {}", order);
        if (order == null) {
            return ResponseEntity.status(404).body(renderResultPage(false, "Unknown order."));
        }

        CoinPackages.Package pkg = CoinPackages.get(order.getPackageId());
        String totalAmount = String.format("%.2f", (double) pkg.npr());

        try {
            String url = UriComponentsBuilder.fromHttpUrl(esewaStatusUrl)
                    .queryParam("product_code", esewaProductCode)
                    .queryParam("total_amount", totalAmount)
                    .queryParam("transaction_uuid", order.getOrderId())
                    .toUriString();

            @SuppressWarnings("unchecked")
            Map<String, Object> statusData = restTemplate.getForObject(url, Map.class);

            String status = statusData != null ? String.valueOf(statusData.get("status")) : null;
            if (!"COMPLETE".equals(status)) {
                store.markOrderStatus(orderId, "failed");
                return ResponseEntity.ok(renderResultPage(false, "Payment not completed (status: " + status + ")."));
            }

            store.creditOnce(order.getDeviceId(), order.getOrderId(), pkg.coins());
            store.markOrderStatus(orderId, "paid");
            return ResponseEntity.ok(renderResultPage(true, "Payment successful! " + pkg.coins() + " coins added."));
        } catch (Exception e) {
            log.error("[payments] eSewa status check failed", e);
            return ResponseEntity.status(500).body(renderResultPage(false, "Verification error."));
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Khalti
    // ══════════════════════════════════════════════════════════════════

    private ResponseEntity<Map<String, Object>> initiateKhalti(String deviceId, String packageId, CoinPackages.Package pkg) {
        if (khaltiSecretKey == null || khaltiSecretKey.isBlank()) {
            return ResponseEntity.status(500).body(errorBody(
                    "KHALTI_SECRET_KEY is not set — sign up at test-admin.khalti.com " +
                            "and set your sandbox secret key as an env var."));
        }

        Order order = store.createOrder(deviceId, packageId, "khalti");
        log.info("khalti orderId: {}", order.getOrderId());

        try {
            HttpHeaders headers = new HttpHeaders();
            headers.set("Authorization", "key " + khaltiSecretKey);
            headers.setContentType(MediaType.APPLICATION_JSON);

            Map<String, Object> requestBody = new LinkedHashMap<>();
            requestBody.put("return_url", publicBaseUrl + "/api/payments/khalti/return?order=" + order.getOrderId());
            requestBody.put("website_url", publicBaseUrl);
            requestBody.put("amount", pkg.npr() * 100); // Khalti wants paisa
            requestBody.put("purchase_order_id", order.getOrderId());
            requestBody.put("purchase_order_name", pkg.label());

            var entity = new org.springframework.http.HttpEntity<>(requestBody, headers);

            @SuppressWarnings("unchecked")
            ResponseEntity<Map> response = restTemplate.exchange(
                    khaltiBaseUrl + "/epayment/initiate/", HttpMethod.POST, entity, Map.class);

            Map<String, Object> data = response.getBody();
            if (!response.getStatusCode().is2xxSuccessful()) {
                log.error("[payments] Khalti initiate failed: {}", data);
                store.markOrderStatus(order.getOrderId(), "failed");
                Map<String, Object> err = errorBody("Khalti initiate failed");
                err.put("detail", data);
                return ResponseEntity.status(502).body(err);
            }

            Map<String, Object> resp = new LinkedHashMap<>();
            resp.put("orderId", order.getOrderId());
            resp.put("redirectUrl", data != null ? data.get("payment_url") : null);
            return ResponseEntity.ok(resp);
        } catch (Exception e) {
            log.error("[payments] Khalti initiate error", e);
            return ResponseEntity.status(500).body(errorBody("failed to initiate Khalti payment"));
        }
    }

    @GetMapping(value = {"/khalti/return", "/khalti/return/"}, produces = MediaType.TEXT_HTML_VALUE)
    public ResponseEntity<String> khaltiReturn(
            @RequestParam(required = false) String pidx,
            @RequestParam(required = false) String order) {
        log.info("pidx: {}", pidx);
        String orderId = order != null ? order.split("\\?")[0] : "";
        Order o = store.getOrder(orderId);
        if (o == null) {
            return ResponseEntity.status(404).body(renderResultPage(false, "Unknown order."));
        }
        if (pidx == null || pidx.isBlank()) {
            return ResponseEntity.ok(renderResultPage(false, "Missing pidx."));
        }

        try {
            // Same principle as eSewa: don't trust the redirect query params,
            // independently ask Khalti's lookup API to confirm the real status.
            HttpHeaders headers = new HttpHeaders();
            headers.set("Authorization", "key " + khaltiSecretKey);
            headers.setContentType(MediaType.APPLICATION_JSON);

            Map<String, Object> body = new HashMap<>();
            body.put("pidx", pidx);
            var entity = new org.springframework.http.HttpEntity<>(body, headers);

            @SuppressWarnings("unchecked")
            ResponseEntity<Map> response = restTemplate.exchange(
                    khaltiBaseUrl + "/epayment/lookup/", HttpMethod.POST, entity, Map.class);
            Map<String, Object> data = response.getBody();
            String status = data != null ? String.valueOf(data.get("status")) : null;

            if (!"Completed".equals(status)) {
                store.markOrderStatus(orderId, "failed");
                return ResponseEntity.ok(renderResultPage(false, "Payment not completed (status: " + status + ")."));
            }

            CoinPackages.Package pkg = CoinPackages.get(o.getPackageId());
            store.creditOnce(o.getDeviceId(), o.getOrderId(), pkg.coins());
            store.markOrderStatus(orderId, "paid");
            return ResponseEntity.ok(renderResultPage(true, "Payment successful! " + pkg.coins() + " coins added."));
        } catch (Exception e) {
            log.error("[payments] Khalti lookup failed", e);
            return ResponseEntity.status(500).body(renderResultPage(false, "Verification error."));
        }
    }

    // ── helpers ──

    private Map<String, Object> errorBody(String message) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("error", message);
        return body;
    }

    private String renderResultPage(boolean success, String message) {
        String color = success ? "#4ade80" : "#f87171";
        String title = success ? "Successful" : "Failed";
        String heading = success ? "\u2713 Success" : "\u2717 Payment Failed";
        return """
                <!DOCTYPE html>
                <html>
                  <head>
                    <meta name="viewport" content="width=device-width, initial-scale=1" />
                    <title>Payment %s</title>
                    <style>
                      body { font-family: sans-serif; text-align: center; padding: 48px 16px; background: #0f0f12; color: #eee; }
                      h1 { color: %s; }
                      p { color: #aaa; }
                    </style>
                  </head>
                  <body>
                    <h1>%s</h1>
                    <p>%s</p>
                    <p>You can close this tab and return to the app.</p>
                  </body>
                </html>"""
                .formatted(title, color, heading, message);
    }
}
