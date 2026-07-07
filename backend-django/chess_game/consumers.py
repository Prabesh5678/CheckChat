import logging

from channels.generic.websocket import AsyncWebsocketConsumer

from .game_manager import game_manager

logger = logging.getLogger(__name__)


class ChessConsumer(AsyncWebsocketConsumer):
    """One instance per connected client — this plays the role that a raw
    `ws` socket played in the original server. Channels handles the
    keep-alive ping/pong itself, so there's no need to port the manual
    setInterval ping loop from index.js."""

    async def connect(self):
        await self.accept()
        game_manager.add_player(self)

    async def disconnect(self, close_code):
        await game_manager.remove_player(self)

    async def receive(self, text_data=None, bytes_data=None):
        if text_data is None:
            return
        await game_manager.handle_message(self, text_data)
