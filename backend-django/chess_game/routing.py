from django.urls import re_path

from .consumers import ChessConsumer

# Match ANY path (including the bare root) so the frontend's existing
# ws://host:port URL — with no path — keeps working unchanged. This mirrors
# the original `new WebSocketServer({ server })`, which never checked the
# request path at all.
websocket_urlpatterns = [
    re_path(r"^.*$", ChessConsumer.as_asgi()),
]
