"""Фейковое Apple TV для демо-режима (--demo) и тестов.

install() подменяет pyatv.scan / pyatv.pair / pyatv.connect так, что демон
работает с «виртуальным» Apple TV: поддерживает сопряжение (PIN 1234),
ключи, приложения, now playing, клавиатуру, питание.
Используются настоящие pyatv.conf / FileStorage / исключения, поэтому
это проверяет и реальную логику хранилища учётных данных.
"""

from __future__ import annotations

import asyncio
import ipaddress
import time
from typing import Any, Dict, List, Optional, Set

import pyatv
from pyatv import conf, const, exceptions, interface
from pyatv.const import (
    DeviceModel,
    DeviceState,
    FeatureName,
    FeatureState,
    InputAction,
    MediaType,
    OperatingSystem,
    PairingRequirement,
    PowerState,
    Protocol,
)

DEMO_ID = "AA:BB:CC:DD:EE:FF"
DEMO_PIN = "1234"

# 1x1 PNG
PNG = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
    "0000000d49444154789c6360f8cfc0f01f0005000201a5f645400000000049454e44ae426082"
)


def make_config(name: str = "Living Room (demo)", address: str = "192.168.1.50",
                identifier: str = DEMO_ID, with_airplay: bool = True) -> conf.AppleTV:
    info = interface.DeviceInfo(
        {
            interface.DeviceInfo.OPERATING_SYSTEM: OperatingSystem.TvOS,
            interface.DeviceInfo.VERSION: "18.1",
            interface.DeviceInfo.MODEL: DeviceModel.AppleTV4KGen3,
            interface.DeviceInfo.MAC: identifier,
        }
    )
    config = conf.AppleTV(ipaddress.IPv4Address(address), name, device_info=info)
    config.add_service(
        conf.ManualService(identifier, Protocol.Companion, 49153, {},
                           pairing_requirement=PairingRequirement.Mandatory)
    )
    if with_airplay:
        config.add_service(
            conf.ManualService(identifier, Protocol.AirPlay, 7000, {},
                               pairing_requirement=PairingRequirement.Mandatory)
        )
    return config


class FakeCompanionApi:
    """Как CompanionAPI: hid_command(down, HidCommand)."""

    def __init__(self, atv: "FakeAppleTV") -> None:
        self.atv = atv
        self.calls: List[Any] = []

    async def hid_command(self, down: bool, command: Any) -> None:
        self.atv.check_alive()
        self.calls.append((down, command.name))
        if self.atv.hid_volume == "unsupported":
            raise exceptions.NotSupportedError("hid")
        if down and command.name == "VolumeUp":
            self.atv.volume = min(100.0, self.atv.volume + 5)
        elif down and command.name == "VolumeDown":
            self.atv.volume = max(0.0, self.atv.volume - 5)


class FakeMrpProtocol:
    def __init__(self, atv: "FakeAppleTV") -> None:
        self.atv = atv
        self.sent: List[Any] = []

    async def send(self, message: Any) -> None:
        self.atv.check_alive()
        self.sent.append(message)


class FakeMrpRemote:
    """MRP-туннель поверх AirPlay: HID Consumer-клавиши громкости."""

    def __init__(self, atv: "FakeAppleTV") -> None:
        self.atv = atv
        self.protocol = FakeMrpProtocol(atv)

    async def volume_up(self) -> None: self._key("volume_up", 5)
    async def volume_down(self) -> None: self._key("volume_down", -5)

    def _key(self, name: str, delta: float) -> None:
        self.atv.check_alive()
        mode = self.atv.mrp_volume
        if mode == "unsupported":
            raise exceptions.NotSupportedError(name)
        self.atv.mrp_calls.append(name)
        if mode == "ok":  # "silent" = отправили, но ТВ не отреагировал
            self.atv.volume = max(0.0, min(100.0, self.atv.volume + delta))


class FakeRemote:
    def __init__(self, atv: "FakeAppleTV") -> None:
        self.atv = atv
        self.log: List[str] = []
        self.api = FakeCompanionApi(atv)
        self.mrp = FakeMrpRemote(atv)

    def _rec(self, name: str, **kw: Any) -> None:
        self.atv.check_alive()
        self.log.append(name if not kw else f"{name}:{kw}")
        if name == "play_pause":
            st = self.atv.playing_state
            self.atv.set_playing(DeviceState.Paused if st == DeviceState.Playing else DeviceState.Playing)
        elif name == "volume_up":
            self.atv.volume = min(100.0, self.atv.volume + 5)
        elif name == "volume_down":
            self.atv.volume = max(0.0, self.atv.volume - 5)

    async def up(self, action: InputAction = InputAction.SingleTap) -> None: self._rec("up", action=action.name)
    async def down(self, action: InputAction = InputAction.SingleTap) -> None: self._rec("down", action=action.name)
    async def left(self, action: InputAction = InputAction.SingleTap) -> None: self._rec("left", action=action.name)
    async def right(self, action: InputAction = InputAction.SingleTap) -> None: self._rec("right", action=action.name)
    async def select(self, action: InputAction = InputAction.SingleTap) -> None: self._rec("select", action=action.name)
    async def menu(self, action: InputAction = InputAction.SingleTap) -> None: self._rec("menu", action=action.name)
    async def home(self, action: InputAction = InputAction.SingleTap) -> None: self._rec("home", action=action.name)
    async def home_hold(self) -> None: self._rec("home_hold")
    async def top_menu(self) -> None: self._rec("top_menu")
    async def play_pause(self) -> None: self._rec("play_pause")
    async def play(self) -> None: self._rec("play")
    async def pause(self) -> None: self._rec("pause")
    async def stop(self) -> None: self._rec("stop")
    async def next(self) -> None: self._rec("next")
    async def previous(self) -> None: self._rec("previous")
    async def skip_forward(self, time_interval: float = 0.0) -> None: self._rec("skip_forward")
    async def skip_backward(self, time_interval: float = 0.0) -> None: self._rec("skip_backward")
    async def volume_up(self) -> None: self._volume_key("volume_up")
    async def volume_down(self) -> None: self._volume_key("volume_down")

    def _volume_key(self, name: str) -> None:
        """Имитация Companion HID: режим задаёт тест через atv.hid_volume."""
        mode = self.atv.hid_volume
        if mode == "unsupported":
            raise exceptions.NotSupportedError(name)
        if mode == "timeout":
            raise asyncio.TimeoutError()
        self._rec(name)

    # как у FacadeRemoteControl в pyatv
    def get(self, protocol: Protocol) -> Any:
        if protocol == Protocol.Companion:
            return self
        if protocol == Protocol.MRP and self.atv.has_mrp:
            return self.mrp
        return None

    @property
    def main_protocol(self) -> Protocol:
        return Protocol.Companion
    async def channel_up(self) -> None: raise exceptions.NotSupportedError("channel_up")
    async def channel_down(self) -> None: raise exceptions.NotSupportedError("channel_down")
    async def screensaver(self) -> None: self._rec("screensaver")
    async def control_center(self) -> None: self._rec("control_center")
    async def guide(self) -> None: raise exceptions.NotSupportedError("guide")
    async def wakeup(self) -> None: self._rec("wakeup")
    async def suspend(self) -> None: self._rec("suspend")


class FakePower:
    def __init__(self, atv: "FakeAppleTV") -> None:
        self.atv = atv
        self.listener: Optional[interface.PowerListener] = None

    @property
    def power_state(self) -> PowerState:
        return self.atv._pstate

    async def turn_on(self, await_new_state: bool = False) -> None:
        self.atv.check_alive()
        self._set(PowerState.On)

    async def turn_off(self, await_new_state: bool = False) -> None:
        self.atv.check_alive()
        self._set(PowerState.Off)

    def _set(self, new: PowerState) -> None:
        old, self.atv._pstate = self.atv._pstate, new
        if self.listener:
            self.listener.powerstate_update(old, new)


class FakeApps:
    APPS = [("Netflix", "com.netflix.Netflix"), ("YouTube", "com.google.ios.youtube"),
            ("Music", "com.apple.TVMusic"), ("Plex", "com.plexapp.plex")]

    def __init__(self, atv: "FakeAppleTV") -> None:
        self.atv = atv
        self.launched: List[str] = []

    async def app_list(self) -> List[interface.App]:
        self.atv.check_alive()
        return [interface.App(n, i) for n, i in self.APPS]

    async def launch_app(self, bundle_id_or_url: str) -> None:
        self.atv.check_alive()
        self.launched.append(bundle_id_or_url)
        names = {i: n for n, i in self.APPS}
        self.atv.app = interface.App(names.get(bundle_id_or_url), bundle_id_or_url)


class FakeKeyboard:
    def __init__(self, atv: "FakeAppleTV") -> None:
        self.atv = atv
        self.text = ""
        self.listener: Optional[interface.KeyboardListener] = None
        self.text_focus_state = const.KeyboardFocusState.Focused

    async def text_get(self) -> Optional[str]: self.atv.check_alive(); return self.text
    async def text_clear(self) -> None: self.atv.check_alive(); self.text = ""
    async def text_append(self, text: str) -> None: self.atv.check_alive(); self.text += text
    async def text_set(self, text: str) -> None: self.atv.check_alive(); self.text = text


class FakeAudio:
    def __init__(self, atv: "FakeAppleTV") -> None:
        self.atv = atv
        self.listener = None

    async def volume_up(self) -> None:
        self.atv.audio_calls.append("volume_up")
        if self.atv.audio_volume == "unsupported":
            raise exceptions.NotSupportedError("audio.volume_up")
        self.atv.volume = min(100.0, self.atv.volume + 5)

    async def volume_down(self) -> None:
        self.atv.audio_calls.append("volume_down")
        if self.atv.audio_volume == "unsupported":
            raise exceptions.NotSupportedError("audio.volume_down")
        self.atv.volume = max(0.0, self.atv.volume - 5)

    async def set_volume(self, level: float) -> None:
        self.atv.audio_calls.append(f"set_volume:{level:g}")
        self.atv.volume = level

    @property
    def volume(self) -> float:
        return self.atv.volume


class FakeMetadata:
    def __init__(self, atv: "FakeAppleTV") -> None:
        self.atv = atv

    @property
    def app(self) -> Optional[interface.App]:
        return self.atv.app

    @property
    def artwork_id(self) -> str:
        return f"art-{self.atv.track}"

    async def artwork(self, width: Optional[int] = 512, height: Optional[int] = None):
        return interface.ArtworkInfo(PNG, "image/png", 1, 1)

    async def playing(self) -> interface.Playing:
        return self.atv.playing_obj()


class FakePushUpdater:
    def __init__(self, atv: "FakeAppleTV") -> None:
        self.atv = atv
        self.listener: Optional[interface.PushListener] = None
        self.active = False

    def start(self, initial_delay: int = 0) -> None:
        self.active = True

    def stop(self) -> None:
        self.active = False


class FakeFeatures:
    def __init__(self, atv: "FakeAppleTV") -> None:
        self.atv = atv

    def get_feature(self, name: FeatureName) -> interface.FeatureInfo:
        unsupported = {FeatureName.ChannelUp, FeatureName.ChannelDown, FeatureName.Guide}
        if name in unsupported:
            return interface.FeatureInfo(FeatureState.Unsupported)
        if name == FeatureName.SetVolume:
            return interface.FeatureInfo(self.atv.set_volume_state)
        return interface.FeatureInfo(FeatureState.Available)

    def in_state(self, states: Any, *features: FeatureName) -> bool:
        return True


class FakePlaying(interface.Playing):
    def __init__(self, **kw: Any) -> None:
        self._kw = kw

    @property
    def media_type(self): return self._kw.get("media_type", MediaType.Video)
    @property
    def device_state(self): return self._kw.get("device_state", DeviceState.Idle)
    @property
    def title(self): return self._kw.get("title")
    @property
    def artist(self): return self._kw.get("artist")
    @property
    def album(self): return self._kw.get("album")
    @property
    def genre(self): return None
    @property
    def total_time(self): return self._kw.get("total_time")
    @property
    def position(self): return self._kw.get("position")
    @property
    def shuffle(self): return None
    @property
    def repeat(self): return None
    @property
    def hash(self): return "fake"
    @property
    def series_name(self): return self._kw.get("series_name")
    @property
    def season_number(self): return None
    @property
    def episode_number(self): return None
    @property
    def content_identifier(self): return None
    @property
    def itunes_store_identifier(self): return None


class FakeAppleTV:
    """Минимальная реализация pyatv.interface.AppleTV (утиная типизация)."""

    def __init__(self, config: conf.AppleTV) -> None:
        self.config = config
        self.alive = True
        self._pstate = PowerState.On
        self.volume = 40.0
        # тестовые «ручки»: поведение громкости (как у разных Apple TV)
        self.hid_volume = "ok"             # Companion HID volume_up/down: ok | unsupported | timeout
        self.audio_volume = "ok"           # audio.volume_up/down: ok | unsupported
        self.set_volume_state = FeatureState.Available  # Unavailable = ТВ по HDMI-CEC/ИК
        self.audio_calls: List[str] = []
        self.has_mrp = False               # поднят ли MRP-туннель (AirPlay сопряжён)
        self.mrp_volume = "ok"             # MRP HID: ok | silent | unsupported
        self.mrp_calls: List[str] = []
        self.playing_state = DeviceState.Playing
        self.track = 1
        self.app: Optional[interface.App] = interface.App("Music", "com.apple.TVMusic")
        self.listener: Optional[interface.DeviceListener] = None
        self.remote_control = FakeRemote(self)
        self.apps = FakeApps(self)
        self.keyboard = FakeKeyboard(self)
        self.audio = FakeAudio(self)
        self.metadata = FakeMetadata(self)
        self.push_updater = FakePushUpdater(self)
        self.features = FakeFeatures(self)
        self.power = FakePower(self)

    def check_alive(self) -> None:
        if not self.alive:
            raise exceptions.ConnectionLostError("fake connection lost")

    def playing_obj(self) -> FakePlaying:
        return FakePlaying(
            title=f"Demo Track {self.track}", artist="Demo Artist", album="Demo Album",
            media_type=MediaType.Music, device_state=self.playing_state,
            total_time=240, position=42,
        )

    def set_playing(self, state: DeviceState) -> None:
        self.playing_state = state
        if self.push_updater.listener:
            self.push_updater.listener.playstatus_update(self.push_updater, self.playing_obj())

    def drop(self) -> None:
        """Тест: имитация обрыва соединения."""
        self.alive = False
        if self.listener:
            self.listener.connection_lost(exceptions.ConnectionLostError("test drop"))

    def close(self) -> Set[asyncio.Task]:
        self.alive = False
        return set()


class FakePairing:
    def __init__(self, config: conf.AppleTV, protocol: Protocol, storage: Any) -> None:
        self.config, self.protocol, self.storage = config, protocol, storage
        self._pin: Optional[str] = None
        self.has_paired = False
        self.begun = False
        self.service = config.get_service(protocol)

    @property
    def device_provides_pin(self) -> bool:
        return True

    async def begin(self) -> None:
        self.begun = True

    def pin(self, pin: Any) -> None:
        self._pin = str(pin)

    async def finish(self) -> None:
        if self._pin != DEMO_PIN:
            self.has_paired = False
            return
        settings = await self.storage.get_settings(self.config)
        creds = f"fake-{self.protocol.name}-credentials"
        getattr(settings.protocols, self.protocol.name.lower()).credentials = creds
        self.service.credentials = creds
        self.has_paired = True

    async def close(self) -> None:
        pass


# ---------------------------------------------------------------------------

LAST_ATV: Optional[FakeAppleTV] = None
CONFIGS: List[conf.AppleTV] = []
CONNECT_FAILURES = {"count": 0}


def _fresh_configs() -> List[conf.AppleTV]:
    return list(CONFIGS) if CONFIGS else [make_config()]


async def fake_scan(loop, timeout=5, identifier=None, protocol=None, hosts=None, aiozc=None, storage=None):
    await asyncio.sleep(0.05)
    result = []
    for cfg in _fresh_configs():
        if identifier:
            ids = identifier if isinstance(identifier, set) else {identifier}
            if ids.isdisjoint(cfg.all_identifiers):
                continue
        if hosts and str(cfg.address) not in hosts:
            continue
        if storage is not None:
            cfg.apply(await storage.get_settings(cfg))
        result.append(cfg)
    return result


async def fake_pair(config, protocol, loop, session=None, storage=None, **kwargs):
    if config.get_service(protocol) is None:
        raise exceptions.NoServiceError("no service")
    return FakePairing(config, protocol, storage)


async def fake_connect(config, loop, protocol=None, session=None, storage=None):
    global LAST_ATV
    if CONNECT_FAILURES["count"] > 0:
        CONNECT_FAILURES["count"] -= 1
        raise exceptions.ConnectionFailedError("fake: device asleep")
    if storage is not None:
        settings = await storage.get_settings(config)
        config.apply(settings)
    comp = config.get_service(Protocol.Companion)
    if comp is None or comp.credentials is None:
        raise exceptions.NoCredentialsError("fake: not paired")
    atv = FakeAppleTV(config)
    LAST_ATV = atv
    return atv


def install() -> None:
    pyatv.scan = fake_scan  # type: ignore[assignment]
    pyatv.pair = fake_pair  # type: ignore[assignment]
    pyatv.connect = fake_connect  # type: ignore[assignment]
