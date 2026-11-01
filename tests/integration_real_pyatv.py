"""Интеграционный тест: наш демон + НАСТОЯЩИЙ pyatv.connect против fake Companion-устройства
из исходников pyatv (tests/fake_device в sdist pyatv).

Запуск:
    pip download pyatv==<ver> --no-deps --no-binary :all: && tar xzf pyatv-*.tar.gz
    PYATV_SRC=/путь/к/pyatv-<ver> python3 tests/integration_real_pyatv.py
Подменяется только pyatv.scan (мДНС в песочнице нет); connect/Companion/HID/apps/keyboard — реальные.
"""
import asyncio
import json
import os
import sys
import tempfile

src = os.environ.get("PYATV_SRC")
if not src:
    sys.exit("set PYATV_SRC to unpacked pyatv sdist")
sys.path.insert(0, src)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "python"))

import pyatv  # noqa: E402
from pyatv.auth.server_auth import CLIENT_CREDENTIALS  # noqa: E402
from pyatv.conf import AppleTV, ManualService  # noqa: E402
from pyatv.const import Protocol  # noqa: E402
from tests.fake_device import FakeAppleTV  # noqa: E402

import atvd  # noqa: E402


async def main() -> None:
    loop = asyncio.get_running_loop()
    fake = FakeAppleTV(loop, test_mode=False)
    state, usecase = fake.add_service(Protocol.Companion)
    await fake.start()
    usecase = fake.get_usecase(Protocol.Companion)
    state = fake.get_state(Protocol.Companion)
    usecase.set_installed_apps({"com.test.Test": "Test", "com.test.Two": "Two"})

    PAIR_MODE = {"real_pairing": False}

    def make_cfg():
        c = AppleTV("127.0.0.1", "Fake ATV")
        c.add_service(ManualService(
            "fakeid", Protocol.Companion, fake.get_port(Protocol.Companion), {},
            credentials=None if PAIR_MODE["real_pairing"] else CLIENT_CREDENTIALS,
            pairing_requirement=pyatv.const.PairingRequirement.Mandatory))
        return c

    async def scan(loop, timeout=5, identifier=None, protocol=None, hosts=None, aiozc=None, storage=None):
        c = make_cfg()
        if storage is not None:
            c.apply(await storage.get_settings(c))
        return [c]

    pyatv.scan = scan  # connect остаётся настоящим

    msgs, waiters = [], []
    tmp = tempfile.mkdtemp()
    reader = asyncio.StreamReader()
    args = atvd.parse_args(["--storage", os.path.join(tmp, "s.conf"), "--cache-dir", tmp])
    task = loop.create_task(atvd.amain(args, reader=reader, out=msgs.append))
    n = 0

    async def call(cmd, **kw):
        nonlocal n
        n += 1
        mid = n
        reader.feed_data((json.dumps({"id": mid, "cmd": cmd, **kw}) + "\n").encode())
        for _ in range(500):
            for m in msgs:
                if m.get("type") == "response" and m["id"] == mid:
                    return m
            await asyncio.sleep(0.02)
        raise TimeoutError(cmd)

    # --- часть 1: НАСТОЯЩЕЕ сопряжение (SRP) против fake-устройства ---
    from pyatv.protocols.companion.server_auth import PIN_CODE
    PAIR_MODE["real_pairing"] = True
    r = await call("scan")
    assert r["ok"] and r["result"]["devices"][0]["id"] == "fakeid", r
    assert not r["result"]["devices"][0]["services"][0]["paired"]
    r = await call("pair_start", device="fakeid", protocol="companion")
    assert r["ok"] and r["result"]["device_provides_pin"], r
    r = await call("pair_pin", pin=str(PIN_CODE))
    assert r["ok"] and r["result"]["paired"], r
    r = await call("scan")
    assert r["result"]["devices"][0]["services"][0]["paired"], r
    print("REAL PAIRING OK; storage:", open(os.path.join(tmp, "s.conf")).read()[:120], "...")
    r = await call("connect", device="fakeid", address="127.0.0.1")
    assert r["ok"], r
    print("connected with stored (paired) credentials")
    await call("disconnect")
    PAIR_MODE["real_pairing"] = False
    r = await call("connect", device="fakeid", address="127.0.0.1")
    assert r["ok"], r
    print("features:", {k: v for k, v in r["result"]["features"].items() if v == "Available"})
    for key in ["up", "down", "left", "right", "select", "menu", "home", "play_pause"]:
        r = await call("key", key=key)
        print("key", key, "->", "ok" if r["ok"] else r["error"])
    print("HID last:", state.latest_button if hasattr(state, "latest_button") else "n/a")
    # громкость: реальный pyatv, Companion HID VolumeUp/VolumeDown (идут первым путём)
    for key, button in (("volume_up", "volume_up"), ("volume_down", "volume_down")):
        r = await call("key", key=key)
        assert r["ok"], (key, r)
        assert r["result"]["path"] == "Companion HID", r
        print("volume key", key, "->", r["result"], "| fake device got:", state.latest_button)
        assert state.latest_button == button, state.latest_button
    r = await call("apps")
    print("apps:", r["result"] if r["ok"] else r["error"])
    r = await call("launch_app", app="com.test.Test")
    assert r["ok"], r
    assert state.active_app == "com.test.Test", state.active_app
    r = await call("text", mode="set", text="hello")
    print("text set:", r)
    r = await call("power", on=False)
    print("power off:", r)
    r = await call("quit")
    await asyncio.wait_for(task, 10)
    await fake.stop()
    print("INTEGRATION OK")


asyncio.run(main())
