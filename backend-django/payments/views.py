import base64
import hashlib
import hmac
import json
import logging
from urllib.parse import urlencode

import requests
from django.conf import settings
from django.http import HttpResponse, HttpResponseNotFound, JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_GET, require_POST

from . import store

logger = logging.getLogger(__name__)


# ── balance lookup ──


@require_GET
def balance_lookup(request, device_id):
    logger.info("[payments] balance lookup for deviceId=%s", device_id)
    return JsonResponse({"deviceId": device_id, "balance": store.get_balance(device_id)})


# ── generic initiate dispatcher ──


@csrf_exempt
@require_POST
def initiate(request):
    try:
        body = json.loads(request.body or "{}")
    except json.JSONDecodeError:
        return JsonResponse({"error": "Invalid JSON body"}, status=400)

    gateway = body.get("gateway")
    package_id = body.get("packageId")
    device_id = body.get("deviceId")

    if not gateway or not package_id or not device_id:
        return JsonResponse({"error": "Missing required fields"}, status=400)

    logger.info(
        "[payments] initiate for deviceId=%s, packageId=%s, gateway=%s",
        device_id,
        package_id,
        gateway,
    )

    pkg = store.get_package(package_id)
    if not pkg:
        return JsonResponse({"error": f"unknown packageId: {package_id}"}, status=400)

    if gateway == "esewa":
        order = store.create_order(device_id, package_id, "esewa")
        logger.info("esewa orderId: %s", order.order_id)
        return JsonResponse(
            {
                "orderId": order.order_id,
                "redirectUrl": f"{settings.PUBLIC_BASE_URL}/api/payments/esewa/form/{order.order_id}",
            }
        )

    if gateway == "khalti":
        return _initiate_khalti(device_id, package_id, pkg)

    return JsonResponse({"error": f"unknown gateway: {gateway}"}, status=400)


# ══════════════════════════════════════════════════════════════════════
# eSewa
# ══════════════════════════════════════════════════════════════════════


def _esewa_signature(total_amount, transaction_uuid, product_code):
    if not settings.ESEWA_SECRET_KEY:
        raise RuntimeError(
            "ESEWA_SECRET_KEY is not set — for the eSewa sandbox (EPAYTEST), "
            "set it to the test secret key: 8gBm/:&EnhH.1/q"
        )
    message = f"total_amount={total_amount},transaction_uuid={transaction_uuid},product_code={product_code}"
    digest = hmac.new(settings.ESEWA_SECRET_KEY.encode(), message.encode(), hashlib.sha256).digest()
    return base64.b64encode(digest).decode()


@require_GET
def esewa_form(request, order_id):
    order = store.get_order(order_id)
    if not order:
        return HttpResponseNotFound("Unknown order.")

    pkg = store.get_package(order.package_id)
    total_amount = f"{pkg['npr']:.2f}"  # eSewa wants e.g. "10.00"
    transaction_uuid = order.order_id

    signature = _esewa_signature(total_amount, transaction_uuid, settings.ESEWA_PRODUCT_CODE)

    success_url = f"{settings.PUBLIC_BASE_URL}/api/payments/esewa/return"
    failure_url = f"{settings.PUBLIC_BASE_URL}/api/payments/esewa/return?order={order.order_id}&canceled=1"

    html = f"""<!DOCTYPE html>
<html>
  <body>
    <form id="esewaForm" action="{settings.ESEWA_FORM_URL}" method="POST">
      <input type="hidden" name="amount" value="{total_amount}" />
      <input type="hidden" name="tax_amount" value="0" />
      <input type="hidden" name="total_amount" value="{total_amount}" />
      <input type="hidden" name="transaction_uuid" value="{transaction_uuid}" />
      <input type="hidden" name="product_code" value="{settings.ESEWA_PRODUCT_CODE}" />
      <input type="hidden" name="product_service_charge" value="0" />
      <input type="hidden" name="product_delivery_charge" value="0" />
      <input type="hidden" name="success_url" value="{success_url}" />
      <input type="hidden" name="failure_url" value="{failure_url}" />
      <input type="hidden" name="signed_field_names" value="total_amount,transaction_uuid,product_code" />
      <input type="hidden" name="signature" value="{signature}" />
    </form>
    <script>document.getElementById('esewaForm').submit();</script>
  </body>
</html>"""
    return HttpResponse(html)


@require_GET
def esewa_return(request):
    data = request.GET.get("data")
    if not data:
        return HttpResponse("Missing payment data", status=400)

    try:
        decoded = json.loads(base64.b64decode(data).decode("utf-8"))
    except Exception:
        return HttpResponse("Malformed payment data", status=400)

    order_id = decoded.get("transaction_uuid")
    order = store.get_order(order_id)
    logger.info("Order: %s", order)
    if not order:
        return HttpResponseNotFound(_render_result_page(False, "Unknown order."))

    pkg = store.get_package(order.package_id)
    total_amount = f"{pkg['npr']:.2f}"

    try:
        params = {
            "product_code": settings.ESEWA_PRODUCT_CODE,
            "total_amount": total_amount,
            "transaction_uuid": order.order_id,
        }
        status_res = requests.get(f"{settings.ESEWA_STATUS_URL}?{urlencode(params)}", timeout=15)
        status_data = status_res.json()

        if status_data.get("status") != "COMPLETE":
            store.mark_order_status(order_id, "failed")
            return HttpResponse(
                _render_result_page(
                    False, f"Payment not completed (status: {status_data.get('status')})."
                )
            )

        store.credit_once(order.device_id, order.order_id, pkg["coins"])
        store.mark_order_status(order_id, "paid")
        return HttpResponse(
            _render_result_page(True, f"Payment successful! {pkg['coins']} coins added.")
        )
    except Exception:
        logger.exception("[payments] eSewa status check failed")
        return HttpResponse(_render_result_page(False, "Verification error."), status=500)


# ══════════════════════════════════════════════════════════════════════
# Khalti
# ══════════════════════════════════════════════════════════════════════


def _initiate_khalti(device_id, package_id, pkg):
    if not settings.KHALTI_SECRET_KEY:
        return JsonResponse(
            {
                "error": (
                    "KHALTI_SECRET_KEY is not set — sign up at test-admin.khalti.com "
                    "and set your sandbox secret key as an env var."
                )
            },
            status=500,
        )

    order = store.create_order(device_id, package_id, "khalti")
    logger.info("khalti orderId: %s", order.order_id)

    try:
        response = requests.post(
            f"{settings.KHALTI_BASE_URL}/epayment/initiate/",
            headers={
                "Authorization": f"key {settings.KHALTI_SECRET_KEY}",
                "Content-Type": "application/json",
            },
            json={
                "return_url": f"{settings.PUBLIC_BASE_URL}/api/payments/khalti/return?order={order.order_id}",
                "website_url": settings.PUBLIC_BASE_URL,
                "amount": pkg["npr"] * 100,  # Khalti wants paisa
                "purchase_order_id": order.order_id,
                "purchase_order_name": pkg["label"],
            },
            timeout=15,
        )
        data = response.json()
        if not response.ok:
            logger.error("[payments] Khalti initiate failed: %s", data)
            store.mark_order_status(order.order_id, "failed")
            return JsonResponse({"error": "Khalti initiate failed", "detail": data}, status=502)

        return JsonResponse({"orderId": order.order_id, "redirectUrl": data.get("payment_url")})
    except Exception:
        logger.exception("[payments] Khalti initiate error")
        return JsonResponse({"error": "failed to initiate Khalti payment"}, status=500)


@require_GET
def khalti_return(request):
    pidx = request.GET.get("pidx")
    logger.info("pidx: %s", pidx)
    order_id = (request.GET.get("order") or "").split("?")[0]
    order = store.get_order(order_id)
    if not order:
        return HttpResponseNotFound(_render_result_page(False, "Unknown order."))
    if not pidx:
        return HttpResponse(_render_result_page(False, "Missing pidx."))

    try:
        # Same principle as eSewa: don't trust the redirect query params,
        # independently ask Khalti's lookup API to confirm the real status.
        response = requests.post(
            f"{settings.KHALTI_BASE_URL}/epayment/lookup/",
            headers={
                "Authorization": f"key {settings.KHALTI_SECRET_KEY}",
                "Content-Type": "application/json",
            },
            json={"pidx": pidx},
            timeout=15,
        )
        data = response.json()

        if data.get("status") != "Completed":
            store.mark_order_status(order_id, "failed")
            return HttpResponse(
                _render_result_page(False, f"Payment not completed (status: {data.get('status')}).")
            )

        pkg = store.get_package(order.package_id)
        store.credit_once(order.device_id, order.order_id, pkg["coins"])
        store.mark_order_status(order_id, "paid")
        return HttpResponse(
            _render_result_page(True, f"Payment successful! {pkg['coins']} coins added.")
        )
    except Exception:
        logger.exception("[payments] Khalti lookup failed")
        return HttpResponse(_render_result_page(False, "Verification error."), status=500)


def _render_result_page(success, message):
    color = "#4ade80" if success else "#f87171"
    title = "Successful" if success else "Failed"
    heading = "✓ Success" if success else "✗ Payment Failed"
    return f"""<!DOCTYPE html>
<html>
  <head>
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Payment {title}</title>
    <style>
      body {{ font-family: sans-serif; text-align: center; padding: 48px 16px; background: #0f0f12; color: #eee; }}
      h1 {{ color: {color}; }}
      p {{ color: #aaa; }}
    </style>
  </head>
  <body>
    <h1>{heading}</h1>
    <p>{message}</p>
    <p>You can close this tab and return to the app.</p>
  </body>
</html>"""
