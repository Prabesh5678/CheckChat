import { Router } from "express";
import crypto from "crypto";
import {
  createOrder,
  getOrder,
  markOrderStatus,
  getPackage,
} from "../store/orderStore.js";
import { getBalance, creditOnce } from "../store/coinStore.js";
import dotenv from "dotenv";
dotenv.config();
const router = Router();

const PUBLIC_BASE_URL = process.env.PUBLIC_BASE_URL ?? "http://localhost:8080";

const ESEWA_PRODUCT_CODE = process.env.ESEWA_PRODUCT_CODE ?? "EPAYTEST";
const ESEWA_SECRET_KEY = process.env.ESEWA_SECRET_KEY;
const ESEWA_FORM_URL =
  process.env.ESEWA_FORM_URL ??
  "https://rc-epay.esewa.com.np/api/epay/main/v2/form";
const ESEWA_STATUS_URL =
  process.env.ESEWA_STATUS_URL ??
  "https://rc.esewa.com.np/api/epay/transaction/status/";

const KHALTI_SECRET_KEY = process.env.KHALTI_SECRET_KEY;
const KHALTI_BASE_URL =
  process.env.KHALTI_BASE_URL ?? "https://dev.khalti.com/api/v2";

// ── balance lookup ──

router.get("/balance/:deviceId", (req, res) => {
  const { deviceId } = req.params;
  console.log(`[payments] balance lookup for deviceId=${deviceId}`);
  res.json({ deviceId, balance: getBalance(deviceId) });
});

// ── generic initiate dispatcher ──

router.post("/initiate", async (req, res) => {
  const { gateway, packageId, deviceId } = req.body;
  if (!gateway || !packageId || !deviceId) {
    return res.status(400).json({ error: "Missing required fields" });
  }

  console.log(
    `[payments] initiate for deviceId=${deviceId}, packageId=${packageId}, gateway=${gateway}`,
  );

  const pkg = getPackage(packageId);
  if (!pkg) {
    return res.status(400).json({ error: `unknown packageId: ${packageId}` });
  }

  if (gateway === "esewa") {
    const orderId = createOrder({ deviceId, packageId, gateway: "esewa" });
    console.log("esewa orderId:", orderId);
    return res.json({
      orderId,
      redirectUrl: `${PUBLIC_BASE_URL}/api/payments/esewa/form/${orderId}`,
    });
  }

  if (gateway === "khalti") {
    return initiateKhalti({ req, res, deviceId, packageId, pkg });
  }
  return res.status(400).json({ error: `unknown gateway: ${gateway}` });
});

// ══════════════════════════════════════════════════════════════════════
// eSewa
// ══════════════════════════════════════════════════════════════════════

function esewaSignature({ totalAmount, transactionUuid, productCode }) {
  const message = `total_amount=${totalAmount},transaction_uuid=${transactionUuid},product_code=${productCode}`;
  return crypto
    .createHmac("sha256", ESEWA_SECRET_KEY)
    .update(message)
    .digest("base64");
}

router.get("/esewa/form/:orderId", (req, res) => {
  const order = getOrder(req.params.orderId);
  if (!order) return res.status(404).send("Unknown order.");

  const pkg = getPackage(order.packageId);
  const totalAmount = pkg.npr.toFixed(2); // eSewa wants e.g. "10.00"
  const transactionUuid = order.orderId;

  const signature = esewaSignature({
    totalAmount,
    transactionUuid,
    productCode: ESEWA_PRODUCT_CODE,
  });

  const successUrl = `${PUBLIC_BASE_URL}/api/payments/esewa/return`;
  const failureUrl = `${PUBLIC_BASE_URL}/api/payments/esewa/return?order=${order.orderId}&canceled=1`;

  res.send(`<!DOCTYPE html>
<html>
  <body>
    <form id="esewaForm" action="${ESEWA_FORM_URL}" method="POST">
      <input type="hidden" name="amount" value="${totalAmount}" />
      <input type="hidden" name="tax_amount" value="0" />
      <input type="hidden" name="total_amount" value="${totalAmount}" />
      <input type="hidden" name="transaction_uuid" value="${transactionUuid}" />
      <input type="hidden" name="product_code" value="${ESEWA_PRODUCT_CODE}" />
      <input type="hidden" name="product_service_charge" value="0" />
      <input type="hidden" name="product_delivery_charge" value="0" />
      <input type="hidden" name="success_url" value="${successUrl}" />
      <input type="hidden" name="failure_url" value="${failureUrl}" />
      <input type="hidden" name="signed_field_names" value="total_amount,transaction_uuid,product_code" />
      <input type="hidden" name="signature" value="${signature}" />
    </form>
    <script>document.getElementById('esewaForm').submit();</script>
  </body>
</html>`);
});

router.get("/esewa/return", async (req, res) => {
  const { data } = req.query;
  if (!data) {
    return res.status(400).send("Missing payment data");
  }

  const decoded = JSON.parse(Buffer.from(data, "base64").toString("utf8"));
  const orderId = decoded.transaction_uuid;

  const order = getOrder(orderId);
  console.log("Order:", order);
  if (!order) {
    return res
      .status(404)
      .send(renderResultPage({ success: false, message: "Unknown order." }));
  }

  const pkg = getPackage(order.packageId);
  const totalAmount = pkg.npr.toFixed(2);

  try {
    const statusUrl = new URL(ESEWA_STATUS_URL);
    statusUrl.searchParams.set("product_code", ESEWA_PRODUCT_CODE);
    statusUrl.searchParams.set("total_amount", totalAmount);
    statusUrl.searchParams.set("transaction_uuid", orderId);

    const statusRes = await fetch(statusUrl.toString());
    const statusData = await statusRes.json();

    if (statusData.status !== "COMPLETE") {
      markOrderStatus(orderId, "failed");
      return res.send(
        renderResultPage({
          success: false,
          message: `Payment not completed (status: ${statusData.status}).`,
        }),
      );
    }

    creditOnce(order.deviceId, order.orderId, pkg.coins);
    markOrderStatus(orderId, "paid");
    return res.send(
      renderResultPage({
        success: true,
        message: `Payment successful! ${pkg.coins} coins added.`,
      }),
    );
  } catch (err) {
    console.error("[payments] eSewa status check failed:", err);
    return res
      .status(500)
      .send(
        renderResultPage({ success: false, message: "Verification error." }),
      );
  }
});

// ══════════════════════════════════════════════════════════════════════
// Khalti
// ══════════════════════════════════════════════════════════════════════

async function initiateKhalti({ req, res, deviceId, packageId, pkg }) {
  if (!KHALTI_SECRET_KEY) {
    return res.status(500).json({
      error:
        "KHALTI_SECRET_KEY is not set — sign up at test-admin.khalti.com " +
        "and set your sandbox secret key as an env var.",
    });
  }

  try {
    const orderId = createOrder({ deviceId, packageId, gateway: "khalti" });
    console.log("khalti orderId:", orderId);

    const response = await fetch(`${KHALTI_BASE_URL}/epayment/initiate/`, {
      method: "POST",
      headers: {
        Authorization: `key ${KHALTI_SECRET_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        return_url: `${PUBLIC_BASE_URL}/api/payments/khalti/return?order=${orderId}`,
        website_url: PUBLIC_BASE_URL,
        amount: pkg.npr * 100, // Khalti wants paisa
        purchase_order_id: orderId,
        purchase_order_name: pkg.label,
      }),
    });

    const data = await response.json();
    if (!response.ok) {
      console.error("[payments] Khalti initiate failed:", data);
      markOrderStatus(orderId, "failed");
      return res
        .status(502)
        .json({ error: "Khalti initiate failed", detail: data });
    }

    res.json({ orderId, redirectUrl: data.payment_url });
  } catch (err) {
    console.error("[payments] Khalti initiate error:", err);
    res.status(500).json({ error: "failed to initiate Khalti payment" });
  }
}

router.get("/khalti/return", async (req, res) => {
  const { pidx } = req.query;
  console.log("pidx:", pidx);
  const orderId = String(req.query.order || "").split("?")[0];
  const order = getOrder(orderId);
  if (!order) {
    return res
      .status(404)
      .send(renderResultPage({ success: false, message: "Unknown order." }));
  }
  if (!pidx) {
    return res.send(
      renderResultPage({ success: false, message: "Missing pidx." }),
    );
  }

  try {
    // Same principle as eSewa: don't trust the redirect query params,
    // independently ask Khalti's lookup API to confirm the real status.
    const response = await fetch(`${KHALTI_BASE_URL}/epayment/lookup/`, {
      method: "POST",
      headers: {
        Authorization: `key ${KHALTI_SECRET_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ pidx }),
    });
    const data = await response.json();

    if (data.status !== "Completed") {
      markOrderStatus(orderId, "failed");
      return res.send(
        renderResultPage({
          success: false,
          message: `Payment not completed (status: ${data.status}).`,
        }),
      );
    }

    const pkg = getPackage(order.packageId);
    creditOnce(order.deviceId, order.orderId, pkg.coins);
    markOrderStatus(orderId, "paid");
    return res.send(
      renderResultPage({
        success: true,
        message: `Payment successful! ${pkg.coins} coins added.`,
      }),
    );
  } catch (err) {
    console.error("[payments] Khalti lookup failed:", err);
    return res
      .status(500)
      .send(
        renderResultPage({ success: false, message: "Verification error." }),
      );
  }
});

function renderResultPage({ success, message }) {
  return `<!DOCTYPE html>
<html>
  <head>
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Payment ${success ? "Successful" : "Failed"}</title>
    <style>
      body { font-family: sans-serif; text-align: center; padding: 48px 16px; background: #0f0f12; color: #eee; }
      h1 { color: ${success ? "#4ade80" : "#f87171"}; }
      p { color: #aaa; }
    </style>
  </head>
  <body>
    <h1>${success ? "✓ Success" : "✗ Payment Failed"}</h1>
    <p>${message}</p>
    <p>You can close this tab and return to the app.</p>
  </body>
</html>`;
}

export default router;
