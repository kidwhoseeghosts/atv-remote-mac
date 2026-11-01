#!/usr/bin/env python3
"""ATVRemote daemon: долгоживущий мост между Swift-приложением и pyatv.

Протокол: JSON Lines. По одной JSON-строке на сообщение, UTF-8, поток stdin/stdout.

Запрос  (Swift -> daemon):
    {"id": 7, "cmd": "key", "key": "up", "action": "tap"}
Ответ   (daemon -> Swift):
    {"type": "response", "id": 7, "ok": true,  "result": {...}}
    {"type": "response", "id": 7, "ok": false, "error": {"code": "...", "message": "..."}}
Событие (daemon -> Swift):
    {"type": "event", "event": "state|playing|artwork|power|keyboard|volume|features|log|ready", "data": {...}}

stdout используется ТОЛЬКО для протокола, все логи идут в stderr.
Демон завершается, когда закрывается stdin (родитель умер) или приходит команда "quit".

Аргументы:
    --storage PATH   файл pyatv (FileStorage) с учётными данными
    --cache-dir DIR  каталог для обложек
    --demo           фейковое Apple TV (для проверки интерфейса без устройства)
    --verbose        подробные логи pyatv в stderr
    --lang CODE      язык сообщений для пользователя (en | ru); логи всегда на английском
"""

from __future__ import annotations

import argparse
import asyncio
import base64  # noqa: F401  (оставлено для возможной отправки обложек inline)
import hashlib
import json
import logging
import os
import sys
import time
import traceback
from typing import Any, Awaitable, Callable, Dict, List, Optional

import pyatv
from pyatv import const, exceptions, interface
from pyatv.const import (
    DeviceModel,
    FeatureName,
    FeatureState,
    InputAction,
    PairingRequirement,
    Protocol,
)
from pyatv.storage.file_storage import FileStorage

try:  # приватные детали pyatv нужны только для способов «с удержанием»; без них эти способы просто скрываются
    from pyatv.protocols.companion.api import HidCommand
except Exception:  # noqa: BLE001
    HidCommand = None  # type: ignore[assignment,misc]
try:
    from pyatv.protocols.mrp import messages as mrp_messages
except Exception:  # noqa: BLE001
    mrp_messages = None  # type: ignore[assignment]
try:
    from pyatv.settings import MrpTunnel
except Exception:  # noqa: BLE001
    MrpTunnel = None  # type: ignore[assignment,misc]

PROTOCOL_VERSION = 1
LOG = logging.getLogger("atvd")

# ---------------------------------------------------------------------------
# Таблицы соответствия
# ---------------------------------------------------------------------------

# имя клавиши в протоколе -> (метод remote_control, FeatureName для проверки)
KEY_MAP: Dict[str, str] = {
    "up": "up",
    "down": "down",
    "left": "left",
    "right": "right",
    "select": "select",
    "menu": "menu",
    "home": "home",
    "home_hold": "home_hold",
    "top_menu": "top_menu",
    "play_pause": "play_pause",
    "play": "play",
    "pause": "pause",
    "stop": "stop",
    "next": "next",
    "previous": "previous",
    "skip_forward": "skip_forward",
    "skip_backward": "skip_backward",
    "volume_up": "volume_up",
    "volume_down": "volume_down",
    "channel_up": "channel_up",
    "channel_down": "channel_down",
    "screensaver": "screensaver",
    "control_center": "control_center",
    "guide": "guide",
    "wakeup": "wakeup",
    "suspend": "suspend",
}

# клавиши, принимающие аргумент action (SingleTap/DoubleTap/Hold)
ACTION_KEYS = {"up", "down", "left", "right", "select", "menu", "home"}

# Клавиши громкости: идут своим путём (Companion HID → запасные способы), см. Daemon.volume_key
VOLUME_KEYS = {"volume_up": 1, "volume_down": -1}
VOLUME_STEP = 5.0  # шаг запасного пути через AirPlay set_volume, %
VOLUME_ATTEMPT_TIMEOUT = 5.0
VOLUME_MAX_PENDING = 4  # при зажатой кнопке лишние нажатия отбрасываем, чтобы не копить очередь
VOLUME_HOLD_TIME = 0.4  # сколько держим кнопку в способах «с удержанием», с
VOLUME_DIAG_DELAY = 2.0  # пауза между способами в диагностике, с
# Порядок по умолчанию (пока пользователь не выбрал рабочий способ в «Диагностике громкости»).
# «Удержание» в авто-порядок не входит: оно может шагнуть громкость несколько раз.
VOLUME_DEFAULT_ORDER = ["mrp_hid", "companion_hid", "remote_control", "audio", "set_volume"]
VOLUME_HINT_KEY = (
    "Check: Apple TV → Settings → Remotes and Devices → Volume Control "
    "(HDMI-CEC is required; over IR the volume cannot be changed from the network), and HDMI-CEC on the TV. "
    "Settings → “Volume diagnostics” will show which method works."
)

# --- Локализация сообщений для пользователя -------------------------------------------------
# Ключ — английский текст (он же текст по умолчанию), значение — русский. Язык задаёт приложение
# аргументом --lang. Всё, что идёт только в журнал (log_event), пишется по-английски и не переводится.
LANG = "en"

RU: Dict[str, str] = {
    "Unknown command: {cmd}": "Неизвестная команда: {cmd}",
    "Not supported by this device/protocol": "Не поддерживается этим устройством/протоколом",
    "Pairing required (credentials missing or invalid)": "Нужно выполнить сопряжение (нет/неверные ключи)",
    "Authentication error: {err}": "Ошибка аутентификации: {err}",
    "Pairing failed: {err}": "Сопряжение не удалось: {err}",
    "Operation timed out": "Таймаут операции",
    "Connection lost: {err}": "Соединение потеряно: {err}",
    "Action is unavailable in the current state": "Действие недоступно в текущем состоянии",
    "Command failed: {err}": "Команда не выполнена: {err}",
    "Not connected to Apple TV": "Нет соединения с Apple TV",
    "Device not found on the network (asleep or on another network?)":
        "Устройство не найдено в сети (спит или другая сеть?)",
    "device and protocol are required": "Нужны device и protocol",
    "The device has no {proto} service": "У устройства нет сервиса {proto}",
    "{proto} pairing is disabled or not supported": "Сопряжение {proto} отключено или не поддерживается",
    "Pairing has not been started": "Сопряжение не начато",
    "Wrong PIN or Apple TV rejected the pairing": "Неверный PIN или Apple TV отклонил сопряжение",
    "Scan for devices first": "Сначала выполните поиск устройств",
    "device is required": "Нужен device",
    "Connecting…": "Подключение…",
    "Reconnecting (attempt {n})": "Повтор подключения (попытка {n})",
    "Connected": "Подключено",
    "Unknown key: {key}": "Неизвестная клавиша: {key}",
    "MRP HID (AirPlay tunnel)": "MRP HID (туннель AirPlay)",
    "Companion HID, hold": "Companion HID, удержание",
    "MRP HID, hold": "MRP HID, удержание",
    "not supported": "не поддерживается",
    "no response": "нет ответа",
    "no response within 5 s": "нет ответа за 5 с",
    "connection lost: {err}": "соединение потеряно: {err}",
    "Volume did not change. {hint}": "Громкость не изменилась. {hint}",
    VOLUME_HINT_KEY:
        "Проверьте: Apple TV → Настройки → Пульты и устройства → Управление громкостью "
        "(нужен HDMI-CEC, по ИК громкость по сети не меняется), и HDMI-CEC на ТВ. "
        "Настройки → «Диагностика громкости» покажет, какой способ работает.",
    "Method “{only}” is unavailable right now": "Способ «{only}» сейчас недоступен",
    "app is required (bundle id or URL)": "Нужен app (bundle id или URL)",
    "Unknown mode: {mode}": "Неизвестный mode: {mode}",
    "Mute is unavailable: over HDMI-CEC/IR Apple TV only supports volume up/down "
    "(Companion has no Mute button). Use “Volume Down” or the TV remote.":
        "Mute недоступен: по HDMI-CEC/ИК Apple TV умеет только «громче/тише» "
        "(у Companion нет кнопки Mute). Используйте «Тише» или пульт ТВ.",
}


def set_language(lang: Optional[str]) -> None:
    global LANG
    LANG = (lang or "en").lower().replace("_", "-").split("-")[0]


def tr(text: str, **kw: Any) -> str:
    """Сообщение для пользователя на выбранном языке (по умолчанию английский)."""
    out = RU.get(text, text) if LANG == "ru" else text
    return out.format(**kw) if kw else out

ACTIONS = {
    "tap": InputAction.SingleTap,
    "double": InputAction.DoubleTap,
    "hold": InputAction.Hold,
}

# Какие функции показываем клиенту (имя FeatureName -> состояние)
REPORTED_FEATURES = [
    "Up", "Down", "Left", "Right", "Select", "Menu", "Home", "HomeHold", "TopMenu",
    "PlayPause", "Play", "Pause", "Stop", "Next", "Previous", "SkipForward",
    "SkipBackward", "VolumeUp", "VolumeDown", "Volume", "SetVolume", "TurnOn",
    "TurnOff", "PowerState", "AppList", "LaunchApp", "TextSet", "TextAppend",
    "TextClear", "TextGet", "TextFocusState", "Artwork", "PushUpdates", "Title",
    "App", "Position", "TotalTime", "ControlCenter", "Screensaver",
]

TV_MODELS = {
    DeviceModel.Gen2,
    DeviceModel.Gen3,
    DeviceModel.Gen4,
    DeviceModel.Gen4K,
    DeviceModel.AppleTV4KGen2,
    DeviceModel.AppleTV4KGen3,
    DeviceModel.AppleTVGen1,
}

# какие протоколы имеет смысл спаривать, и в каком порядке
PAIRABLE_ORDER = [Protocol.Companion, Protocol.AirPlay, Protocol.MRP]
PROTOCOL_BY_NAME = {p.name.lower(): p for p in Protocol}

FATAL_CONNECT_ERRORS = (
    exceptions.NoCredentialsError,
    exceptions.InvalidCredentialsError,
    exceptions.AuthenticationError,
    exceptions.DeviceIdMissingError,
    exceptions.NoServiceError,
    exceptions.NotSupportedError,
)

CONNECTION_ERRORS = (
    exceptions.ConnectionLostError,
    exceptions.ConnectionFailedError,
    ConnectionError,
    BrokenPipeError,
    asyncio.TimeoutError,
)


class CommandError(Exception):
    """Ошибка команды с машиночитаемым кодом."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _enum_name(value: Any) -> Optional[str]:
    return value.name if value is not None and hasattr(value, "name") else None


def _safe(fn: Callable[[], Any], default: Any = None) -> Any:
    try:
        return fn()
    except Exception:  # noqa: BLE001 - мы собираем «что получится»
        return default


# ---------------------------------------------------------------------------
# Сериализация объектов pyatv
# ---------------------------------------------------------------------------


def serialize_config(config: interface.BaseConfig) -> Dict[str, Any]:
    info = config.device_info
    services = []
    for svc in config.services:
        services.append(
            {
                "protocol": svc.protocol.name.lower(),
                "paired": svc.credentials is not None,
                "pairing": _enum_name(svc.pairing),
                "port": svc.port,
                "requires_password": bool(svc.requires_password),
            }
        )
    model = _safe(lambda: info.model)
    protocols = {s.protocol for s in config.services}
    is_tv = model in TV_MODELS or (
        model in (None, DeviceModel.Unknown)
        and bool(protocols & {Protocol.Companion, Protocol.MRP})
    )
    return {
        "id": config.identifier,
        "identifiers": sorted(config.all_identifiers),
        "name": config.name,
        "address": str(config.address),
        "model": _safe(lambda: info.model_str, ""),
        "os": _enum_name(_safe(lambda: info.operating_system)),
        "version": _safe(lambda: info.version),
        "is_tv": bool(is_tv),
        "services": services,
    }


def serialize_playing(playing: Optional[interface.Playing], app: Optional[interface.App]) -> Dict[str, Any]:
    data: Dict[str, Any] = {
        "app": app.name if app is not None else None,
        "app_id": app.identifier if app is not None else None,
        "timestamp": time.time(),
    }
    if playing is None:
        data.update({"device_state": "Idle"})
        return data
    for key in (
        "title", "artist", "album", "genre", "series_name", "season_number",
        "episode_number", "position", "total_time", "content_identifier",
    ):
        data[key] = _safe(lambda k=key: getattr(playing, k))
    data["media_type"] = _enum_name(_safe(lambda: playing.media_type))
    data["device_state"] = _enum_name(_safe(lambda: playing.device_state)) or "Idle"
    data["shuffle"] = _enum_name(_safe(lambda: playing.shuffle))
    data["repeat"] = _enum_name(_safe(lambda: playing.repeat))
    return data


# ---------------------------------------------------------------------------
# Слушатели pyatv
# ---------------------------------------------------------------------------


class Listener(
    interface.DeviceListener,
    interface.PushListener,
    interface.PowerListener,
    interface.KeyboardListener,
    interface.AudioListener,
):
    """Один объект на все callbacks pyatv; перекидывает их в Daemon."""

    def __init__(self, daemon: "Daemon", generation: int) -> None:
        self.daemon = daemon
        self.generation = generation  # чтобы игнорировать события от старых соединений

    def _current(self) -> bool:
        return self.generation == self.daemon.generation

    # DeviceListener
    def connection_lost(self, exception: Exception) -> None:
        if self._current():
            LOG.warning("connection lost: %r", exception)
            self.daemon.on_connection_lost(f"{exception}")

    def connection_closed(self) -> None:
        if self._current():
            LOG.info("connection closed")
            self.daemon.on_connection_lost("closed")

    # PushListener
    def playstatus_update(self, updater: Any, playstatus: interface.Playing) -> None:
        if self._current():
            self.daemon.on_playing(playstatus)

    def playstatus_error(self, updater: Any, exception: Exception) -> None:
        if self._current():
            LOG.warning("playstatus error: %r", exception)
            self.daemon.schedule(self.daemon.refresh_playing())

    # PowerListener
    def powerstate_update(self, old_state: const.PowerState, new_state: const.PowerState) -> None:
        if self._current():
            self.daemon.emit("power", {"state": new_state.name})

    # KeyboardListener
    def focusstate_update(
        self, old_state: const.KeyboardFocusState, new_state: const.KeyboardFocusState
    ) -> None:
        if self._current():
            self.daemon.emit("keyboard", {"focus": new_state.name})

    # AudioListener
    def volume_update(self, old_level: float, new_level: float) -> None:
        self.daemon._volume_events += 1
        if self._current():
            self.daemon.emit("volume", {"level": new_level})
            self.daemon.refresh_features()

    def volume_device_update(self, output_device: Any, old_level: float, new_level: float) -> None:
        pass  # громкость отдельных выходов нам не нужна

    def outputdevices_update(self, old_devices: Any, new_devices: Any) -> None:
        pass


# ---------------------------------------------------------------------------
# Демон
# ---------------------------------------------------------------------------


class Daemon:
    RECONNECT_DELAYS = [1, 2, 3, 5, 8, 12, 20, 30]

    def __init__(
        self,
        loop: asyncio.AbstractEventLoop,
        storage_path: str,
        cache_dir: str,
        out: Callable[[Dict[str, Any]], None],
    ) -> None:
        self.loop = loop
        self.storage_path = storage_path
        self.cache_dir = cache_dir
        self._out = out
        self.storage: Optional[FileStorage] = None

        self.configs: Dict[str, interface.BaseConfig] = {}  # id -> config из последнего scan
        self.atv: Optional[interface.AppleTV] = None
        self.generation = 0
        self.target: Optional[Dict[str, Any]] = None  # {"id":..., "address":...}
        self.state = "disconnected"

        self._supervisor: Optional[asyncio.Task] = None
        self._lost_event = asyncio.Event()
        self._first_result: Optional[asyncio.Future] = None
        self._tasks: set = set()

        self._pairing: Optional[interface.PairingHandler] = None
        self._pairing_ctx: Optional[Dict[str, Any]] = None

        self._last_artwork_key: Optional[str] = None
        self._artwork_enabled = True
        self._artwork_files: List[str] = []
        self._stopping = False
        self.quit_event = asyncio.Event()
        self.client_name = "ATVRemote"
        self._volume_before_mute = 30.0
        self._volume_lock = asyncio.Lock()
        self._volume_pending = 0
        self._volume_path: Optional[str] = None
        self._volume_fail_logged = 0.0
        self._last_features: Optional[Dict[str, str]] = None
        self.volume_method: Optional[str] = None  # выбранный пользователем способ (id) или None = авто
        self.force_mrp_tunnel = False
        self._volume_events = 0  # счётчик событий громкости от Apple TV (для диагностики)

    # ---- вспомогательное ------------------------------------------------

    def emit(self, event: str, data: Optional[Dict[str, Any]] = None) -> None:
        self._out({"type": "event", "event": event, "data": data or {}})

    def schedule(self, coro: Awaitable[Any]) -> None:
        task = self.loop.create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    def set_state(self, state: str, message: str = "", **extra: Any) -> None:
        self.state = state
        data = {"state": state, "message": message}
        if self.target:
            data["device_id"] = self.target.get("id")
        data.update(extra)
        self.emit("state", data)

    async def start(self) -> None:
        os.makedirs(os.path.dirname(self.storage_path) or ".", exist_ok=True)
        os.makedirs(self.cache_dir, exist_ok=True)
        self.storage = FileStorage(self.storage_path, self.loop)
        await self.storage.load()

    # ---- диспетчер ----------------------------------------------------------

    async def handle(self, msg: Dict[str, Any]) -> None:
        msg_id = msg.get("id")
        cmd = msg.get("cmd")
        try:
            handler = getattr(self, f"cmd_{cmd}", None)
            if handler is None:
                raise CommandError("unknown_command", tr("Unknown command: {cmd}", cmd=cmd))
            result = await handler(msg)
            self._out({"type": "response", "id": msg_id, "ok": True, "result": result or {}})
        except CommandError as err:
            self._out(
                {"type": "response", "id": msg_id, "ok": False,
                 "error": {"code": err.code, "message": err.message}}
            )
        except Exception as err:  # noqa: BLE001
            code, message = self.classify(err)
            if code == "connection":
                self.on_connection_lost(message)
            else:
                LOG.debug("command %s failed: %s", cmd, traceback.format_exc())
            self._out(
                {"type": "response", "id": msg_id, "ok": False,
                 "error": {"code": code, "message": message}}
            )

    @staticmethod
    def classify(err: BaseException) -> "tuple[str, str]":
        if isinstance(err, CommandError):
            return err.code, err.message
        if isinstance(err, exceptions.NotSupportedError):
            return "not_supported", tr("Not supported by this device/protocol")
        if isinstance(err, (exceptions.NoCredentialsError, exceptions.InvalidCredentialsError)):
            return "no_credentials", tr("Pairing required (credentials missing or invalid)")
        if isinstance(err, exceptions.AuthenticationError):
            return "auth", tr("Authentication error: {err}", err=err)
        if isinstance(err, exceptions.PairingError):
            return "pairing_failed", tr("Pairing failed: {err}", err=err)
        if isinstance(err, (asyncio.TimeoutError, exceptions.OperationTimeoutError)):
            return "timeout", tr("Operation timed out")
        if isinstance(err, CONNECTION_ERRORS):
            return "connection", tr("Connection lost: {err}", err=err)
        if isinstance(err, exceptions.BlockedStateError):
            return "blocked", tr("Action is unavailable in the current state")
        if isinstance(err, exceptions.CommandError):
            return "command_failed", tr("Command failed: {err}", err=err)
        return "internal", f"{type(err).__name__}: {err}"

    def require_atv(self) -> interface.AppleTV:
        if self.atv is None:
            raise CommandError("not_connected", tr("Not connected to Apple TV"))
        return self.atv

    # ---- базовые команды -------------------------------------------------

    async def cmd_hello(self, msg: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "protocol": PROTOCOL_VERSION,
            "pyatv": const.__version__,
            "python": sys.version.split()[0],
            "storage": self.storage_path,
        }

    async def cmd_quit(self, msg: Dict[str, Any]) -> Dict[str, Any]:
        self.quit_event.set()
        return {}

    async def cmd_set_options(self, msg: Dict[str, Any]) -> Dict[str, Any]:
        if "artwork" in msg:
            self._artwork_enabled = bool(msg["artwork"])
        if msg.get("client_name"):
            self.client_name = str(msg["client_name"])[:40]
        if "volume_method" in msg:
            value = str(msg.get("volume_method") or "")
            self.volume_method = value if value and value != "auto" else None
            self._volume_path = None
        if "force_mrp_tunnel" in msg:
            self.force_mrp_tunnel = bool(msg["force_mrp_tunnel"])
        return {
            "artwork": self._artwork_enabled,
            "client_name": self.client_name,
            "volume_method": self.volume_method or "auto",
            "force_mrp_tunnel": self.force_mrp_tunnel,
        }

    async def cmd_scan(self, msg: Dict[str, Any]) -> Dict[str, Any]:
        timeout = int(msg.get("timeout", 5))
        hosts = msg.get("hosts") or None
        configs = await pyatv.scan(self.loop, timeout=timeout, hosts=hosts, storage=self.storage)
        found = []
        for config in configs:
            if config.identifier is None:
                continue
            self.configs[config.identifier] = config
            found.append(serialize_config(config))
        found.sort(key=lambda d: (not d["is_tv"], d["name"].lower()))
        return {"devices": found}

    async def _find_config(self, device_id: str, address: Optional[str]) -> interface.BaseConfig:
        attempts: List[Optional[List[str]]] = []
        if address:
            attempts.append([address])  # unicast: быстро и надёжно, если IP не менялся
        attempts.append(None)           # multicast mDNS
        for hosts in attempts:
            configs = await pyatv.scan(
                self.loop, timeout=5, identifier=device_id, hosts=hosts, storage=self.storage
            )
            if configs:
                self.configs[device_id] = configs[0]
                return configs[0]
        raise CommandError("not_found", tr("Device not found on the network (asleep or on another network?)"))

    # ---- сопряжение ----------------------------------------------------------

    async def cmd_pair_start(self, msg: Dict[str, Any]) -> Dict[str, Any]:
        device_id = msg.get("device")
        proto_name = str(msg.get("protocol", "")).lower()
        proto = PROTOCOL_BY_NAME.get(proto_name)
        if not device_id or proto is None:
            raise CommandError("invalid_args", tr("device and protocol are required"))
        await self._close_pairing()
        config = self.configs.get(device_id) or await self._find_config(device_id, msg.get("address"))
        service = config.get_service(proto)
        if service is None:
            raise CommandError("no_service", tr("The device has no {proto} service", proto=proto.name))
        if service.pairing in (PairingRequirement.Unsupported, PairingRequirement.Disabled):
            raise CommandError("pairing_disabled", tr("{proto} pairing is disabled or not supported", proto=proto.name))
        await self._apply_client_identity(config)
        handler = await pyatv.pair(config, proto, self.loop, storage=self.storage)
        try:
            await handler.begin()
        except Exception:
            await handler.close()
            raise
        self._pairing = handler
        self._pairing_ctx = {"device": device_id, "protocol": proto}
        provides_pin = bool(handler.device_provides_pin)
        result: Dict[str, Any] = {"device_provides_pin": provides_pin}
        if not provides_pin:
            # устройство PIN не показывает: задаём свой
            pin = 1234
            handler.pin(pin)
            result["pin"] = pin
        return result

    async def _connect_pyatv(self, config: interface.BaseConfig) -> interface.AppleTV:
        """pyatv.connect; при включённом «принудительном MRP-туннеле» — с откатом на авто, если не вышло."""
        assert self.storage is not None
        if MrpTunnel is None:
            return await pyatv.connect(config, self.loop, storage=self.storage)
        settings = await self.storage.get_settings(config)
        if self.force_mrp_tunnel:
            settings.protocols.airplay.mrp_tunnel = MrpTunnel.Force
            try:
                return await pyatv.connect(config, self.loop, storage=self.storage)
            except Exception as err:  # noqa: BLE001
                self.log_event("warning", f"Forced MRP tunnel did not come up ({type(err).__name__}: {err}); "
                                          "connecting in normal mode")
                settings.protocols.airplay.mrp_tunnel = MrpTunnel.Auto
        else:
            settings.protocols.airplay.mrp_tunnel = MrpTunnel.Auto
        return await pyatv.connect(config, self.loop, storage=self.storage)

    async def _apply_client_identity(self, config: interface.BaseConfig) -> None:
        """Имя, под которым мы показываемся в списке пультов на Apple TV."""
        assert self.storage is not None
        settings = await self.storage.get_settings(config)
        settings.info.name = self.client_name

    async def cmd_pair_pin(self, msg: Dict[str, Any]) -> Dict[str, Any]:
        if self._pairing is None or self._pairing_ctx is None:
            raise CommandError("no_pairing", tr("Pairing has not been started"))
        handler, ctx = self._pairing, self._pairing_ctx
        pin = msg.get("pin")
        if pin is not None:
            handler.pin(str(pin).strip())
        try:
            await handler.finish()
            paired = bool(handler.has_paired)
            if paired:
                assert self.storage is not None
                await self.storage.save()
        finally:
            await self._close_pairing()
        if not paired:
            raise CommandError("pairing_failed", tr("Wrong PIN or Apple TV rejected the pairing"))
        # обновим кэш конфигурации, чтобы paired=true отразилось в UI
        cached = self.configs.get(ctx["device"])
        if cached is not None:
            settings = await self.storage.get_settings(cached)  # type: ignore[union-attr]
            cached.apply(settings)
            return {"paired": True, "device": serialize_config(cached)}
        return {"paired": True}

    async def cmd_pair_cancel(self, msg: Dict[str, Any]) -> Dict[str, Any]:
        await self._close_pairing()
        return {}

    async def _close_pairing(self) -> None:
        handler, self._pairing, self._pairing_ctx = self._pairing, None, None
        if handler is not None:
            try:
                await handler.close()
            except Exception:  # noqa: BLE001
                LOG.debug("pairing close failed", exc_info=True)

    async def cmd_forget(self, msg: Dict[str, Any]) -> Dict[str, Any]:
        """Забыть учётные данные устройства."""
        device_id = msg.get("device")
        config = self.configs.get(device_id)
        if config is None:
            raise CommandError("not_found", tr("Scan for devices first"))
        assert self.storage is not None
        if self.target and self.target.get("id") == device_id:
            await self.cmd_disconnect({})
        await self.storage.remove_settings(await self.storage.get_settings(config))
        await self.storage.save()
        return {}

    # ---- подключение ----------------------------------------------------------

    async def cmd_connect(self, msg: Dict[str, Any]) -> Dict[str, Any]:
        device_id = msg.get("device")
        if not device_id:
            raise CommandError("invalid_args", tr("device is required"))
        await self._stop_supervisor()
        self.target = {"id": device_id, "address": msg.get("address"), "name": msg.get("name")}
        self._first_result = self.loop.create_future()
        self._supervisor = self.loop.create_task(self._supervise())
        return await asyncio.wait_for(asyncio.shield(self._first_result), timeout=45)

    async def cmd_disconnect(self, msg: Dict[str, Any]) -> Dict[str, Any]:
        await self._stop_supervisor()
        self.target = None
        self.set_state("disconnected")
        return {}

    async def _stop_supervisor(self) -> None:
        task, self._supervisor = self._supervisor, None
        self.generation += 1
        if task is not None:
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):  # noqa: BLE001
                pass
        await self._drop_connection()
        if self._first_result is not None and not self._first_result.done():
            self._first_result.cancel()
        self._first_result = None

    async def _drop_connection(self) -> None:
        atv, self.atv = self.atv, None
        if atv is not None:
            try:
                closing = atv.close()
                if closing:
                    await asyncio.wait_for(asyncio.gather(*closing, return_exceptions=True), 5)
            except Exception:  # noqa: BLE001
                LOG.debug("atv.close failed", exc_info=True)

    def on_connection_lost(self, reason: str) -> None:
        if self.target is None or self._stopping:
            return
        if self.state in ("connected", "connecting"):
            if self.state == "connected":
                self.set_state("reconnecting", tr("Connection lost: {err}", err=reason))
            self._lost_event.set()

    async def _supervise(self) -> None:
        attempt = 0
        generation = self.generation
        while self.target is not None and generation == self.generation:
            self.set_state("connecting" if attempt == 0 else "reconnecting",
                           tr("Connecting…") if attempt == 0 else tr("Reconnecting (attempt {n})", n=attempt + 1))
            try:
                info = await asyncio.wait_for(self._connect_once(generation), timeout=40)
            except asyncio.CancelledError:
                raise
            except FATAL_CONNECT_ERRORS as err:
                code, message = self.classify(err)
                LOG.warning("fatal connect error: %r", err)
                self._finish_first(error=CommandError(code, message))
                self.set_state("needs_pairing", message)
                return
            except CommandError as err:
                self._finish_first(error=err)
                attempt += 1
                self.set_state("reconnecting", err.message)
            except Exception as err:  # noqa: BLE001
                code, message = self.classify(err)
                LOG.warning("connect failed (%s): %s", type(err).__name__, err)
                self._finish_first(error=CommandError(code, message))
                attempt += 1
                self.set_state("reconnecting", message)
            else:
                attempt = 0
                self._finish_first(result=info)
                self.set_state("connected", tr("Connected"), device=info.get("device"))
                self._lost_event.clear()
                await self._lost_event.wait()
                # соединение потеряно -> закрываем и пробуем снова
                await self._drop_connection()
                if generation != self.generation:
                    return
                self.generation += 1
                generation = self.generation
                continue
            delay = self.RECONNECT_DELAYS[min(attempt - 1, len(self.RECONNECT_DELAYS) - 1)]
            await asyncio.sleep(delay)

    def _finish_first(self, result: Any = None, error: Optional[Exception] = None) -> None:
        fut = self._first_result
        if fut is None or fut.done():
            return
        if error is not None:
            fut.set_exception(error)
        else:
            fut.set_result(result)

    async def _connect_once(self, generation: int) -> Dict[str, Any]:
        assert self.target is not None and self.storage is not None
        device_id = self.target["id"]
        config = await self._find_config(device_id, self.target.get("address"))
        self.target["address"] = str(config.address)

        await self._apply_client_identity(config)
        atv = await self._connect_pyatv(config)
        listener = Listener(self, generation)
        try:
            atv.listener = listener
            atv.push_updater.listener = listener
            atv.power.listener = listener
            atv.keyboard.listener = listener
            _safe(lambda: setattr(atv.audio, "listener", listener))
            atv.push_updater.start()
        except Exception:
            closing = atv.close()
            if closing:
                await asyncio.gather(*closing, return_exceptions=True)
            raise
        self.atv = atv
        self._last_artwork_key = None
        self._lost_event.clear()

        features = self.features_snapshot(atv)
        self._last_features = features
        self.emit("features", {"features": features})
        self.log_event(
            "info",
            "Volume features: VolumeUp={VolumeUp}, VolumeDown={VolumeDown}, SetVolume={SetVolume}".format(
                **{k: features.get(k, "?") for k in ("VolumeUp", "VolumeDown", "SetVolume")}),
        )
        self.log_event("info", "Volume: " + self.volume_summary(atv, config))
        power = _safe(lambda: atv.power.power_state)
        if power is not None:
            self.emit("power", {"state": power.name})
        self.schedule(self.refresh_playing())
        return {"device": serialize_config(config), "features": features}

    # ---- состояние ---------------------------------------------------------

    @staticmethod
    def features_snapshot(atv: interface.AppleTV) -> Dict[str, str]:
        result: Dict[str, str] = {}
        for name in REPORTED_FEATURES:
            feature = getattr(FeatureName, name, None)
            if feature is None:
                continue
            info = _safe(lambda f=feature: atv.features.get_feature(f))
            result[name] = info.state.name if info is not None else "Unknown"
        return result

    async def refresh_playing(self) -> None:
        atv = self.atv
        if atv is None:
            return
        try:
            playing = await atv.metadata.playing()
        except Exception as err:  # noqa: BLE001
            LOG.debug("metadata.playing failed: %r", err)
            return
        self.on_playing(playing)

    def refresh_features(self) -> None:
        """Состояние функций меняется по ходу работы (флаги Companion) — шлём, если изменилось."""
        atv = self.atv
        if atv is None:
            return
        features = self.features_snapshot(atv)
        if features != self._last_features:
            self._last_features = features
            self.emit("features", {"features": features})

    def on_playing(self, playing: interface.Playing) -> None:
        atv = self.atv
        app = _safe(lambda: atv.metadata.app) if atv is not None else None
        self.emit("playing", serialize_playing(playing, app))
        self.refresh_features()
        if self._artwork_enabled and atv is not None:
            self.schedule(self.refresh_artwork(atv))

    async def refresh_artwork(self, atv: interface.AppleTV) -> None:
        try:
            key = await asyncio.wait_for(self._artwork_id(atv), 5)
        except Exception:  # noqa: BLE001
            return
        if key == self._last_artwork_key:
            return
        self._last_artwork_key = key
        try:
            art = await asyncio.wait_for(atv.metadata.artwork(width=512, height=None), 10)
        except Exception as err:  # noqa: BLE001
            LOG.debug("artwork failed: %r", err)
            art = None
        if art is None or not art.bytes:
            self.emit("artwork", {"path": None})
            return
        ext = "png" if "png" in (art.mimetype or "") else "jpg"
        digest = hashlib.sha1(art.bytes).hexdigest()[:12]
        path = os.path.join(self.cache_dir, f"artwork-{digest}.{ext}")
        if not os.path.exists(path):
            with open(path, "wb") as fh:
                fh.write(art.bytes)
        self._artwork_files.append(path)
        for old in self._artwork_files[:-3]:  # храним не больше трёх файлов
            if old != path:
                try:
                    os.remove(old)
                except OSError:
                    pass
        self._artwork_files = self._artwork_files[-3:]
        self.emit("artwork", {"path": path})

    @staticmethod
    async def _artwork_id(atv: interface.AppleTV) -> str:
        return str(atv.metadata.artwork_id)

    # ---- управление -----------------------------------------------------------

    async def cmd_key(self, msg: Dict[str, Any]) -> Dict[str, Any]:
        atv = self.require_atv()
        key = msg.get("key")
        method_name = KEY_MAP.get(str(key))
        if method_name is None:
            raise CommandError("invalid_args", tr("Unknown key: {key}", key=key))
        if key in VOLUME_KEYS:
            return await self.volume_key(atv, str(key))
        action = ACTIONS.get(str(msg.get("action", "tap")), InputAction.SingleTap)
        fn = getattr(atv.remote_control, method_name)
        if method_name in ACTION_KEYS and action != InputAction.SingleTap:
            await asyncio.wait_for(fn(action=action), timeout=10)
        else:
            await asyncio.wait_for(fn(), timeout=10)
        return {}

    # ---- громкость ---------------------------------------------------------

    # --- способы изменить громкость ------------------------------------------------
    #
    # Громкость у Apple TV — это НЕ звук самой приставки: ТВ/ресивер регулируются через HDMI-CEC
    # (или ИК), а приставка лишь получает «нажми Volume+». Её можно попросить по разным каналам:
    #   mrp_hid        — MRP-туннель поверх AirPlay (нужны ключи AirPlay!): HID Consumer 0xE9/0xEA.
    #   companion_hid  — Companion `_hidC` VolumeUp/VolumeDown (8/9 в pyatv).
    #   remote_control — фасад pyatv, если главным протоколом выбран не Companion.
    #   audio          — audio.volume_up/down (с учётом «relative/absolute» от Apple TV).
    #   companion_hold / mrp_hold — то же с удержанием кнопки ~0,4 с (нужны ТВ, игнорирующие «короткий» клик).
    #   set_volume     — абсолютная громкость (HomePod/AirPlay-колонки), шагами по 5 %.

    def log_event(self, level: str, message: str) -> None:
        """Строка в stderr демона: приложение перехватывает её в «Журнал» и в файл журнала."""
        getattr(LOG, level)(message)

    @staticmethod
    def active_protocols(atv: interface.AppleTV) -> List[str]:
        names: List[str] = []
        for proto in (Protocol.MRP, Protocol.Companion, Protocol.AirPlay, Protocol.RAOP, Protocol.DMAP):
            found = False
            for iface in (atv.remote_control, atv.audio, atv.metadata):
                if _safe(lambda i=iface, p=proto: i.get(p)) is not None:
                    found = True
                    break
            if found:
                names.append(proto.name)
        return names

    def volume_info(self, atv: interface.AppleTV, config: Optional[interface.BaseConfig] = None) -> Dict[str, Any]:
        config = config or self.configs.get((self.target or {}).get("id", ""))
        creds: Dict[str, bool] = {}
        if config is not None:
            for svc in config.services:
                creds[svc.protocol.name.lower()] = svc.credentials is not None
        active = self.active_protocols(atv)
        mrp_up = "MRP" in active
        airplay_known = "airplay" in creds
        info: Dict[str, Any] = {
            "protocols": active,
            "credentials": creds,
            "mrp_tunnel": mrp_up,
            "airplay_paired": bool(creds.get("airplay")),
            "airplay_available": airplay_known,
            "force_mrp_tunnel": self.force_mrp_tunnel,
            "preferred": self.volume_method or "auto",
        }
        mrp_audio = _safe(lambda: atv.audio.get(Protocol.MRP))
        if mrp_audio is not None:
            info["mrp_volume"] = {
                "available": _safe(lambda: bool(mrp_audio.is_available)),
                "relative": _safe(lambda: bool(mrp_audio.is_volume_relative)),
                "absolute": _safe(lambda: bool(mrp_audio.is_volume_absolute)),
            }
        if not mrp_up:
            if airplay_known and not info["airplay_paired"]:
                info["advice"] = "pair_airplay"
            elif airplay_known:
                info["advice"] = "force_tunnel"
            else:
                info["advice"] = "none"
        return info

    def volume_summary(self, atv: interface.AppleTV, config: Optional[interface.BaseConfig] = None) -> str:
        info = self.volume_info(atv, config)
        feats = self._last_features or {}
        parts = [
            "protocols=" + ",".join(info["protocols"]),
            "mrp_tunnel=" + ("yes" if info["mrp_tunnel"] else "no"),
            "credentials=" + (",".join(f"{k}:{'yes' if v else 'no'}" for k, v in sorted(info["credentials"].items())) or "?"),
            f"VolumeUp={feats.get('VolumeUp', '?')}",
            f"SetVolume={feats.get('SetVolume', '?')}",
            "method=" + info["preferred"],
        ]
        if "mrp_volume" in info:
            mv = info["mrp_volume"]
            parts.append(f"MRP.volume(avail={mv['available']},rel={mv['relative']},abs={mv['absolute']})")
        if info.get("advice") == "pair_airplay":
            parts.append("WARNING: AirPlay is not paired — the MRP method is unavailable")
        return "; ".join(parts)

    def volume_methods(self, atv: interface.AppleTV) -> "Dict[str, tuple]":
        """id -> (подпись, фабрика `make(sign) -> корутина`). Только реально доступные способы."""
        methods: Dict[str, tuple] = {}
        rc = atv.remote_control
        names = {1: "volume_up", -1: "volume_down"}
        companion_rc = _safe(lambda: rc.get(Protocol.Companion))
        mrp_rc = _safe(lambda: rc.get(Protocol.MRP))

        if mrp_rc is not None and hasattr(mrp_rc, "volume_up"):
            methods["mrp_hid"] = (tr("MRP HID (AirPlay tunnel)"),
                                  lambda sign: getattr(mrp_rc, names[sign])())
        if companion_rc is not None and hasattr(companion_rc, "volume_up"):
            methods["companion_hid"] = ("Companion HID",
                                        lambda sign: getattr(companion_rc, names[sign])())
        main_protocol = _safe(lambda: rc.main_protocol)
        if main_protocol not in (None, Protocol.Companion, Protocol.MRP) or (
                companion_rc is None and mrp_rc is None):
            methods["remote_control"] = ("remote_control", lambda sign: getattr(rc, names[sign])())
        methods["audio"] = ("audio", lambda sign: getattr(atv.audio, names[sign])())

        info = _safe(lambda: atv.features.get_feature(FeatureName.SetVolume))
        if info is not None and info.state == FeatureState.Available:
            async def stepped(sign: int) -> None:
                current = float(atv.audio.volume)
                await atv.audio.set_volume(max(0.0, min(100.0, current + sign * VOLUME_STEP)))

            methods["set_volume"] = ("AirPlay set_volume", stepped)

        # «с удержанием» — только для диагностики/ручного выбора
        api = _safe(lambda: companion_rc.api) if companion_rc is not None else None
        if api is not None and HidCommand is not None and hasattr(api, "hid_command"):
            async def companion_hold(sign: int) -> None:
                cmd = HidCommand.VolumeUp if sign > 0 else HidCommand.VolumeDown
                await api.hid_command(True, cmd)
                await asyncio.sleep(VOLUME_HOLD_TIME)
                await api.hid_command(False, cmd)

            methods["companion_hold"] = (tr("Companion HID, hold"), companion_hold)
        protocol = _safe(lambda: mrp_rc.protocol) if mrp_rc is not None else None
        if protocol is not None and mrp_messages is not None:
            async def mrp_hold(sign: int) -> None:
                usage = 0xE9 if sign > 0 else 0xEA
                await protocol.send(mrp_messages.send_hid_event(12, usage, True))
                await asyncio.sleep(VOLUME_HOLD_TIME)
                await protocol.send(mrp_messages.send_hid_event(12, usage, False))

            methods["mrp_hold"] = (tr("MRP HID, hold"), mrp_hold)
        return methods

    def volume_attempts(self, atv: interface.AppleTV, key: str) -> "List[tuple]":
        """Список способов по приоритету: (подпись, фабрика корутины). Выбранный пользователем — первым."""
        sign = VOLUME_KEYS[key]
        methods = self.volume_methods(atv)
        order: List[str] = []
        if self.volume_method in methods:
            order.append(str(self.volume_method))
        order += [m for m in VOLUME_DEFAULT_ORDER if m in methods and m not in order]
        return [(methods[m][0], (lambda make=methods[m][1]: make(sign))) for m in order]

    async def volume_key(self, atv: interface.AppleTV, key: str) -> Dict[str, Any]:
        if self._volume_pending >= VOLUME_MAX_PENDING:
            return {"dropped": True}
        self._volume_pending += 1
        try:
            async with self._volume_lock:
                return await self._volume_key_locked(atv, key)
        finally:
            self._volume_pending -= 1

    async def _volume_key_locked(self, atv: interface.AppleTV, key: str) -> Dict[str, Any]:
        failures: List[str] = []
        for name, fn in self.volume_attempts(atv, key):
            try:
                await asyncio.wait_for(fn(), timeout=VOLUME_ATTEMPT_TIMEOUT)
            except exceptions.NotSupportedError:
                failures.append(f"{name}: not supported")
            except (exceptions.ConnectionLostError, exceptions.ConnectionFailedError,
                    ConnectionError, BrokenPipeError):
                raise  # настоящий обрыв — пусть сработает переподключение
            except (asyncio.TimeoutError, exceptions.OperationTimeoutError):
                failures.append(f"{name}: no response")
            except Exception as err:  # noqa: BLE001
                failures.append(f"{name}: {type(err).__name__}: {err}")
            else:
                if self._volume_path != name:
                    self._volume_path = name
                    extra = f" (earlier attempts failed: {'; '.join(failures)})" if failures else ""
                    self.log_event("info", f"Volume: {key} sent via {name}{extra}")
                return {"path": name}
        now = time.monotonic()
        detail = "; ".join(failures) or "no methods available"
        if now - self._volume_fail_logged > 2.0:  # при зажатой кнопке не спамим журнал
            self._volume_fail_logged = now
            self.log_event("warning", f"Volume: {key} failed — {detail}")
        self._volume_path = None
        raise CommandError("volume_failed", tr("Volume did not change. {hint}", hint=tr(VOLUME_HINT_KEY)))

    async def _run_volume_method(self, atv: interface.AppleTV, method_id: str, label: str,
                                 make: Callable[[int], Awaitable[Any]], sign: int) -> Dict[str, Any]:
        """Один шаг диагностики: отправить, посчитать события громкости, вернуть итог."""
        events_before = self._volume_events
        level_before = _safe(lambda: float(atv.audio.volume))
        started = time.monotonic()
        result: Dict[str, Any] = {"id": method_id, "label": label, "direction": "up" if sign > 0 else "down"}
        try:
            async with self._volume_lock:
                await asyncio.wait_for(make(sign), timeout=VOLUME_ATTEMPT_TIMEOUT + 1)
            result["ok"] = True
        except exceptions.NotSupportedError:
            result.update(ok=False, error=tr("not supported"))
        except (asyncio.TimeoutError, exceptions.OperationTimeoutError):
            result.update(ok=False, error=tr("no response within 5 s"))
        except (exceptions.ConnectionLostError, exceptions.ConnectionFailedError,
                ConnectionError, BrokenPipeError) as err:
            result.update(ok=False, error=tr("connection lost: {err}", err=err))
        except Exception as err:  # noqa: BLE001
            result.update(ok=False, error=f"{type(err).__name__}: {err}")
        await asyncio.sleep(0.3)  # дать Apple TV прислать событие громкости
        level_after = _safe(lambda: float(atv.audio.volume))
        result["elapsed_ms"] = int((time.monotonic() - started) * 1000)
        result["volume_events"] = self._volume_events - events_before
        result["volume_changed"] = bool(
            result["volume_events"] or (level_before is not None and level_after is not None
                                        and level_before != level_after))
        return result

    async def cmd_volume_diag(self, msg: Dict[str, Any]) -> Dict[str, Any]:
        """Диагностика громкости.

        Без параметров — только описание (протоколы, доступные способы).
        `run: true` — пройти по способам по очереди: для каждого «громче», пауза, «тише», пауза.
        `method: id` — прогнать один способ (`direction`: up|down). События `volume_diag` — прогресс.
        """
        atv = self.require_atv()
        methods = self.volume_methods(atv)
        info = self.volume_info(atv)
        info["methods"] = [{"id": mid, "label": label} for mid, (label, _) in methods.items()]
        only = msg.get("method")
        if only is not None:
            if only not in methods:
                raise CommandError("invalid_args", tr("Method “{only}” is unavailable right now", only=only))
            sign = -1 if msg.get("direction") == "down" else 1
            res = await self._run_volume_method(atv, str(only), methods[only][0], methods[only][1], sign)
            self.log_event("info", f"Volume diagnostics: {res}")
            info["results"] = [res]
            return info
        if not msg.get("run"):
            return info

        delay = float(msg.get("delay", VOLUME_DIAG_DELAY))
        self.log_event("info", "Volume diagnostics: " + self.volume_summary(atv))
        results: List[Dict[str, Any]] = []
        total = len(methods)
        for index, (mid, (label, make)) in enumerate(methods.items(), start=1):
            self.emit("volume_diag", {"index": index, "total": total, "id": mid, "label": label, "phase": "up"})
            up = await self._run_volume_method(atv, mid, label, make, 1)
            self.log_event("info", f"Volume diagnostics [{index}/{total}] {label}: up → {up}")
            await asyncio.sleep(delay)
            self.emit("volume_diag", {"index": index, "total": total, "id": mid, "label": label, "phase": "down"})
            down = await self._run_volume_method(atv, mid, label, make, -1)
            self.log_event("info", f"Volume diagnostics [{index}/{total}] {label}: down → {down}")
            results.append({"id": mid, "label": label, "up": up, "down": down,
                            "ok": bool(up.get("ok") and down.get("ok"))})
            if index < total:
                await asyncio.sleep(delay)
        self.emit("volume_diag", {"index": total, "total": total, "phase": "done"})
        self.log_event("info", "Volume diagnostics: summary — " + "; ".join(
            f"{r['label']}: {'sent' if r['ok'] else (r['up'].get('error') or r['down'].get('error'))}"
            for r in results))
        info["results"] = results
        return info

    async def cmd_power(self, msg: Dict[str, Any]) -> Dict[str, Any]:
        atv = self.require_atv()
        on = msg.get("on")
        if on is None:
            state = atv.power.power_state
            on = state != const.PowerState.On
        if on:
            await asyncio.wait_for(atv.power.turn_on(), timeout=15)
        else:
            await asyncio.wait_for(atv.power.turn_off(), timeout=15)
        return {"requested": "on" if on else "off"}

    async def cmd_apps(self, msg: Dict[str, Any]) -> Dict[str, Any]:
        atv = self.require_atv()
        apps = await asyncio.wait_for(atv.apps.app_list(), timeout=15)
        items = [{"id": a.identifier, "name": a.name or a.identifier} for a in apps]
        items.sort(key=lambda a: a["name"].lower())
        return {"apps": items}

    async def cmd_launch_app(self, msg: Dict[str, Any]) -> Dict[str, Any]:
        atv = self.require_atv()
        app_id = msg.get("app")
        if not app_id:
            raise CommandError("invalid_args", tr("app is required (bundle id or URL)"))
        await asyncio.wait_for(atv.apps.launch_app(str(app_id)), timeout=15)
        return {}

    async def cmd_text(self, msg: Dict[str, Any]) -> Dict[str, Any]:
        atv = self.require_atv()
        mode = msg.get("mode", "set")
        kb = atv.keyboard
        if mode == "clear":
            await asyncio.wait_for(kb.text_clear(), timeout=10)
        elif mode == "append":
            await asyncio.wait_for(kb.text_append(str(msg.get("text", ""))), timeout=10)
        elif mode == "set":
            await asyncio.wait_for(kb.text_set(str(msg.get("text", ""))), timeout=10)
        elif mode == "get":
            return {"text": await asyncio.wait_for(kb.text_get(), timeout=10)}
        else:
            raise CommandError("invalid_args", tr("Unknown mode: {mode}", mode=mode))
        return {"focus": _enum_name(_safe(lambda: kb.text_focus_state))}

    async def cmd_set_volume(self, msg: Dict[str, Any]) -> Dict[str, Any]:
        atv = self.require_atv()
        await asyncio.wait_for(atv.audio.set_volume(float(msg.get("level", 0))), timeout=10)
        return {}

    async def cmd_mute(self, msg: Dict[str, Any]) -> Dict[str, Any]:
        """«Без звука»: в Companion/HID у pyatv нет кнопки Mute, поэтому best effort.

        Умеем только если Apple TV сам регулирует громкость вывода по AirPlay (HomePod,
        AirPlay-колонки): тогда переключаем set_volume(0) ↔ прежний уровень. Для ТВ по
        HDMI-CEC доступны только шаги «громче/тише», для ИК — ничего: вернём not_supported.
        """
        atv = self.require_atv()
        unsupported = CommandError(
            "not_supported",
            tr("Mute is unavailable: over HDMI-CEC/IR Apple TV only supports volume up/down "
               "(Companion has no Mute button). Use “Volume Down” or the TV remote."),
        )
        info = _safe(lambda: atv.features.get_feature(FeatureName.SetVolume))
        if info is None or info.state != FeatureState.Available:
            self.log_event("info", "Mute: absolute volume unavailable (HDMI-CEC/IR) — not supported")
            raise unsupported
        try:
            current = float(atv.audio.volume)
            if current > 0:
                self._volume_before_mute = current
                await asyncio.wait_for(atv.audio.set_volume(0.0), timeout=8)
                self.log_event("info", "Mute: set_volume(0) via AirPlay")
                return {"muted": True, "level": 0.0}
            restore = self._volume_before_mute or 30.0
            await asyncio.wait_for(atv.audio.set_volume(restore), timeout=8)
            self.log_event("info", f"Unmuted: set_volume({restore:.0f}) via AirPlay")
            return {"muted": False, "level": restore}
        except (asyncio.TimeoutError, exceptions.OperationTimeoutError):
            raise unsupported from None

    async def cmd_now_playing(self, msg: Dict[str, Any]) -> Dict[str, Any]:
        atv = self.require_atv()
        playing = await asyncio.wait_for(atv.metadata.playing(), timeout=10)
        return serialize_playing(playing, _safe(lambda: atv.metadata.app))

    async def cmd_status(self, msg: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "state": self.state,
            "target": self.target,
            "features": self.features_snapshot(self.atv) if self.atv else {},
        }

    # ---- завершение -----------------------------------------------------------

    async def shutdown(self) -> None:
        if self._stopping:
            return
        self._stopping = True
        await self._close_pairing()
        await self._stop_supervisor()
        for path in self._artwork_files:
            try:
                os.remove(path)
            except OSError:
                pass


# ---------------------------------------------------------------------------
# stdin/stdout
# ---------------------------------------------------------------------------


class StdoutWriter:
    def __init__(self) -> None:
        self._stream = sys.stdout

    def __call__(self, obj: Dict[str, Any]) -> None:
        try:
            self._stream.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")
            self._stream.flush()
        except (BrokenPipeError, ValueError):
            os._exit(0)  # родитель закрыл канал


def install_demo() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    import fake_atv  # type: ignore

    fake_atv.install()


async def amain(args: argparse.Namespace, reader: Optional[asyncio.StreamReader] = None,
                out: Optional[Callable[[Dict[str, Any]], None]] = None) -> None:
    loop = asyncio.get_running_loop()
    writer = out or StdoutWriter()
    daemon = Daemon(loop, args.storage, args.cache_dir, writer)
    await daemon.start()

    if reader is None:
        reader = asyncio.StreamReader(limit=4 * 1024 * 1024)
        await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)

    writer({"type": "event", "event": "ready",
            "data": {"protocol": PROTOCOL_VERSION, "pyatv": const.__version__,
                     "demo": bool(args.demo)}})

    async def read_loop() -> None:
        while True:
            line = await reader.readline()
            if not line:  # EOF: родитель завершился
                return
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
                if not isinstance(msg, dict):
                    raise ValueError("not an object")
            except ValueError as err:
                writer({"type": "event", "event": "log",
                        "data": {"level": "error", "message": f"bad json: {err}"}})
                continue
            daemon.schedule(daemon.handle(msg))

    reader_task = loop.create_task(read_loop())
    quit_task = loop.create_task(daemon.quit_event.wait())
    await asyncio.wait({reader_task, quit_task}, return_when=asyncio.FIRST_COMPLETED)
    await asyncio.sleep(0.1)  # дать отправиться ответу на quit
    for task in (reader_task, quit_task):
        task.cancel()
    await daemon.shutdown()


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    default_dir = os.path.expanduser("~/Library/Application Support/ATVRemote")
    parser.add_argument("--storage", default=os.path.join(default_dir, "pyatv.conf"))
    parser.add_argument("--cache-dir", default=os.path.join(default_dir, "cache"))
    parser.add_argument("--demo", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--lang", default=os.environ.get("ATV_LANG", "en"),
                        help="user-facing message language: en | ru")
    parser.add_argument("--version", action="store_true")
    return parser.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    set_language(args.lang)
    if args.version:
        print(f"atvd protocol {PROTOCOL_VERSION}, pyatv {const.__version__}")
        return 0
    logging.basicConfig(
        stream=sys.stderr,
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    if args.demo:
        install_demo()
    # stdout — только для протокола
    try:
        asyncio.run(amain(args))
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
