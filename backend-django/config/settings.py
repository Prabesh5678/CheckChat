import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

BASE_DIR = Path(__file__).resolve().parent.parent

SECRET_KEY = os.environ.get("DJANGO_SECRET_KEY", "dev-insecure-secret-key-change-me")
DEBUG = os.environ.get("DJANGO_DEBUG", "1") == "1"
ALLOWED_HOSTS = os.environ.get("DJANGO_ALLOWED_HOSTS", "*").split(",")

INSTALLED_APPS = [
    # "daphne" first so it patches `runserver` to serve ASGI (http + websocket)
    "daphne",
    "django.contrib.staticfiles",
    "corsheaders",
    "channels",
    "payments",
    "chess_game",
]

MIDDLEWARE = [
    "corsheaders.middleware.CorsMiddleware",
    "django.middleware.common.CommonMiddleware",
]

# Dev-friendly default matching the original server's app.use(cors()) with no
# restrictions. Tighten this for production.
CORS_ALLOW_ALL_ORIGINS = True

ROOT_URLCONF = "config.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [],
        "APP_DIRS": True,
        "OPTIONS": {"context_processors": []},
    }
]

WSGI_APPLICATION = "config.wsgi.application"
ASGI_APPLICATION = "config.asgi.application"

# In-memory channel layer works for a single ASGI process/worker — the same
# assumption the original single-process Node `ws` server made. Swap in
# channels_redis's RedisChannelLayer if you ever run multiple workers/replicas.
CHANNEL_LAYERS = {
    "default": {
        "BACKEND": "channels.layers.InMemoryChannelLayer",
    }
}

# No models use the ORM anymore — payments/store.py is a plain in-memory
# store, matching the original Node in-memory Maps/Sets. Leaving DATABASES
# empty means no db.sqlite3 file gets created at all.
DATABASES = {}

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

STATIC_URL = "static/"

# The frontend calls these endpoints without trailing slashes (matching the
# original Express routes). Without this, Django's APPEND_SLASH tries to
# redirect POST requests to add a slash and can't preserve the body, causing
# a 500 instead of a clean match.
APPEND_SLASH = False

# ── Payment gateway config (mirrors the original Node .env) ──
PUBLIC_BASE_URL = os.environ.get("PUBLIC_BASE_URL", "http://localhost:8000")

ESEWA_PRODUCT_CODE = os.environ.get("ESEWA_PRODUCT_CODE", "EPAYTEST")
ESEWA_SECRET_KEY = os.environ.get("ESEWA_SECRET_KEY", "")
ESEWA_FORM_URL = os.environ.get(
    "ESEWA_FORM_URL", "https://rc-epay.esewa.com.np/api/epay/main/v2/form"
)
ESEWA_STATUS_URL = os.environ.get(
    "ESEWA_STATUS_URL", "https://rc.esewa.com.np/api/epay/transaction/status/"
)

KHALTI_SECRET_KEY = os.environ.get("KHALTI_SECRET_KEY", "")
KHALTI_BASE_URL = os.environ.get("KHALTI_BASE_URL", "https://dev.khalti.com/api/v2")
