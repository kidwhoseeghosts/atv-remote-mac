"""Тесты протокола демона на фейковом Apple TV (без сети и без Apple TV).

Запуск:  python3 -m unittest discover -s tests -v     (из корня проекта, venv с pyatv)
"""

import asyncio
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PY_DIR = os.path.join(os.path.dirname(HERE), "Resources", "python")
sys.path.insert(0, PY_DIR)

import atvd  # noqa: E402
import fake_atv  # noqa: E402
import pyatv  # noqa: E402

ORIG = (pyatv.scan, pyatv.pair, pyatv.connect)


class Harness:
    """Запускает amain() с in-memory каналами и позволяет слать команды."""

    def __init__(self, tmp: str) -> None:
        self.messages = []
        self.waiters = []
        self.next_id = 1
        args = atvd.parse_args(["--storage", os.path.join(tmp, "pyatv.conf"),
                                "--cache-dir", os.path.join(tmp, "cache"), "--demo"])
        self.args = args
        self.reader = asyncio.StreamReader()
        self.task = asyncio.get_running_loop().create_task(
            atvd.amain(args, reader=self.reader, out=self.out))

    def out(self, obj):
        self.messages.append(obj)
        for w in list(self.waiters):
            w()

    async def wait_for(self, pred, timeout=5):
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while True:
            for m in self.messages:
                if pred(m):
                    return m
            fut = loop.create_future()
            cb = lambda: fut.done() or fut.set_result(None)  # noqa: E731
            self.waiters.append(cb)
            try:
                await asyncio.wait_for(fut, max(0.01, deadline - loop.time()))
            finally:
                self.waiters.remove(cb)

    async def call(self, cmd, timeout=10, **kw):
        mid = self.next_id
        self.next_id += 1
        self.reader.feed_data((json.dumps({"id": mid, "cmd": cmd, **kw}) + "\n").encode())
        resp = await self.wait_for(lambda m: m.get("type") == "response" and m.get("id") == mid, timeout)
        return resp

    def events(self, name):
        return [m["data"] for m in self.messages if m.get("type") == "event" and m["event"] == name]

    async def close(self):
        self.reader.feed_eof()
        await asyncio.wait_for(self.task, 10)


class DaemonTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        fake_atv.install()
        fake_atv.CONFIGS.clear()
        fake_atv.CONNECT_FAILURES["count"] = 0
        fake_atv.LAST_ATV = None
        self.tmp = tempfile.mkdtemp()
        atvd.Daemon.RECONNECT_DELAYS = [0.05]
        self.h = Harness(self.tmp)
        await self.h.wait_for(lambda m: m.get("event") == "ready")

    async def asyncTearDown(self):
        await self.h.close()
        shutil.rmtree(self.tmp, ignore_errors=True)
        pyatv.scan, pyatv.pair, pyatv.connect = ORIG

    async def pair_all(self):
        scan = await self.h.call("scan")
        dev = scan["result"]["devices"][0]
        for proto in ("companion", "airplay"):
            r = await self.h.call("pair_start", device=dev["id"], protocol=proto)
            self.assertTrue(r["ok"], r)
            self.assertTrue(r["result"]["device_provides_pin"])
            r = await self.h.call("pair_pin", pin=fake_atv.DEMO_PIN)
            self.assertTrue(r["ok"], r)
        return dev

    async def test_hello_and_unknown(self):
        r = await self.h.call("hello")
        self.assertTrue(r["ok"])
        self.assertEqual(r["result"]["protocol"], atvd.PROTOCOL_VERSION)
        self.assertRegex(r["result"]["pyatv"], r"^\d+\.\d+")
        r = await self.h.call("nope")
        self.assertFalse(r["ok"])
        self.assertEqual(r["error"]["code"], "unknown_command")

    async def test_scan_shape(self):
        r = await self.h.call("scan")
        dev = r["result"]["devices"][0]
        self.assertEqual(dev["id"], fake_atv.DEMO_ID)
        self.assertTrue(dev["is_tv"])
        self.assertEqual({s["protocol"] for s in dev["services"]}, {"companion", "airplay"})
        self.assertFalse(any(s["paired"] for s in dev["services"]))
        json.dumps(r)  # сериализуемо

    async def test_connect_without_pairing_needs_pairing(self):
        await self.h.call("scan")
        r = await self.h.call("connect", device=fake_atv.DEMO_ID)
        self.assertFalse(r["ok"])
        self.assertEqual(r["error"]["code"], "no_credentials")
        st = await self.h.wait_for(lambda m: m.get("event") == "state" and m["data"]["state"] == "needs_pairing")
        self.assertTrue(st)

    async def test_wrong_pin(self):
        scan = await self.h.call("scan")
        dev = scan["result"]["devices"][0]
        await self.h.call("pair_start", device=dev["id"], protocol="companion")
        r = await self.h.call("pair_pin", pin="0000")
        self.assertFalse(r["ok"])
        self.assertEqual(r["error"]["code"], "pairing_failed")

    async def test_pair_persists_credentials_in_file(self):
        dev = await self.pair_all()
        path = os.path.join(self.tmp, "pyatv.conf")
        self.assertTrue(os.path.exists(path))
        with open(path) as fh:
            data = json.load(fh)
        blob = json.dumps(data)
        self.assertIn("fake-Companion-credentials", blob)
        self.assertIn("fake-AirPlay-credentials", blob)
        self.assertIn("ATVRemote", blob)  # имя клиента
        # rescan отражает paired=true
        scan = await self.h.call("scan")
        self.assertTrue(all(s["paired"] for s in scan["result"]["devices"][0]["services"]))

    async def test_full_flow_keys_apps_text_power(self):
        dev = await self.pair_all()
        r = await self.h.call("connect", device=dev["id"], address=dev["address"])
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["result"]["features"]["Up"], "Available")
        self.assertEqual(r["result"]["features"]["Guide"] if "Guide" in r["result"]["features"] else "n/a", "n/a")
        atv = fake_atv.LAST_ATV
        for key in ["up", "down", "left", "right", "select", "menu", "home", "play_pause",
                    "skip_forward", "skip_backward", "volume_up", "volume_down", "top_menu"]:
            r = await self.h.call("key", key=key)
            self.assertTrue(r["ok"], (key, r))
        log = atv.remote_control.log
        for key in ["up", "down", "left", "right", "select", "menu", "home", "play_pause",
                    "skip_forward", "skip_backward", "volume_up", "volume_down", "top_menu"]:
            self.assertTrue(any(l.startswith(key) for l in log), key)
        r = await self.h.call("key", key="select", action="hold")
        self.assertTrue(r["ok"])
        self.assertIn("hold", atv.remote_control.log[-1].lower())
        r = await self.h.call("key", key="bogus")
        self.assertEqual(r["error"]["code"], "invalid_args")
        r = await self.h.call("key", key="channel_up")
        self.assertEqual(r["error"]["code"], "not_supported")

        r = await self.h.call("apps")
        self.assertEqual([a["id"] for a in r["result"]["apps"]][0:1], ["com.apple.TVMusic"])  # список отсортирован по имени
        r = await self.h.call("launch_app", app="com.netflix.Netflix")
        self.assertTrue(r["ok"])
        self.assertEqual(atv.apps.launched, ["com.netflix.Netflix"])

        r = await self.h.call("text", mode="set", text="Привет, мир")
        self.assertTrue(r["ok"])
        self.assertEqual(atv.keyboard.text, "Привет, мир")
        r = await self.h.call("text", mode="clear")
        self.assertEqual(atv.keyboard.text, "")

        r = await self.h.call("power", on=False)
        self.assertTrue(r["ok"])
        pw = await self.h.wait_for(lambda m: m.get("event") == "power" and m["data"]["state"] == "Off")
        self.assertTrue(pw)
        await self.h.call("power", on=True)

        r = await self.h.call("mute")
        self.assertEqual(r["result"], {"muted": True, "level": 0.0})
        self.assertEqual(atv.volume, 0.0)
        r = await self.h.call("mute")
        self.assertFalse(r["result"]["muted"])
        self.assertGreater(atv.volume, 0)

        r = await self.h.call("now_playing")
        self.assertEqual(r["result"]["title"], "Demo Track 1")
        self.assertEqual(r["result"]["app"], "Netflix")  # запущен выше
        # push update при play_pause
        await self.h.wait_for(lambda m: m.get("event") == "playing" and m["data"]["device_state"] == "Paused")
        art = await self.h.wait_for(lambda m: m.get("event") == "artwork" and m["data"].get("path"))
        self.assertTrue(os.path.exists(art["data"]["path"]))

    # ---- громкость -------------------------------------------------------

    async def connect_fake(self):
        dev = await self.pair_all()
        r = await self.h.call("connect", device=dev["id"])
        self.assertTrue(r["ok"], r)
        return fake_atv.LAST_ATV, r

    async def test_volume_uses_companion_hid_first(self):
        atv, _ = await self.connect_fake()
        atv.set_volume_state = atvd.FeatureState.Unavailable  # ТВ по HDMI-CEC
        with self.assertLogs("atvd", level="INFO") as logs:
            r = await self.h.call("key", key="volume_up")
            r2 = await self.h.call("key", key="volume_down")
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["result"]["path"], "Companion HID")
        self.assertEqual(r2["result"]["path"], "Companion HID")
        self.assertEqual([l for l in atv.remote_control.log if l.startswith("volume")],
                         ["volume_up", "volume_down"])
        self.assertEqual(atv.audio_calls, [])  # AirPlay/audio не трогали
        # путь залогирован один раз (при смене), а не на каждое нажатие
        self.assertEqual(len([l for l in logs.output if "sent via Companion HID" in l]), 1)

    async def test_volume_falls_back_to_audio_then_set_volume(self):
        atv, _ = await self.connect_fake()
        atv.hid_volume = "unsupported"
        before = atv.volume
        with self.assertLogs("atvd", level="INFO") as logs:
            r = await self.h.call("key", key="volume_up")
        self.assertEqual(r["result"]["path"], "audio", r)
        self.assertEqual(atv.volume, before + 5)
        self.assertTrue(any("via audio" in l and "Companion HID: not supported" in l for l in logs.output))
        # и дальше — set_volume (AirPlay)
        atv.audio_volume = "unsupported"
        r = await self.h.call("key", key="volume_down")
        self.assertEqual(r["result"]["path"], "AirPlay set_volume", r)
        self.assertEqual(atv.audio_calls[-1], f"set_volume:{before:g}")

    async def test_volume_failure_is_reported_with_hint(self):
        atv, _ = await self.connect_fake()
        atv.hid_volume = "timeout"
        atv.audio_volume = "unsupported"
        atv.set_volume_state = atvd.FeatureState.Unavailable
        with self.assertLogs("atvd", level="WARNING") as logs:
            r = await self.h.call("key", key="volume_up")
        self.assertTrue(any("Companion HID: no response" in l for l in logs.output), logs.output)
        self.assertFalse(r["ok"])
        self.assertEqual(r["error"]["code"], "volume_failed")
        self.assertIn("HDMI-CEC", r["error"]["message"])
        # соединение при этом не считается потерянным
        r = await self.h.call("key", key="up")
        self.assertTrue(r["ok"])

    async def test_volume_hold_repeat_burst(self):
        atv, _ = await self.connect_fake()
        atv.set_volume_state = atvd.FeatureState.Unavailable
        rs = await asyncio.gather(*[self.h.call("key", key="volume_up") for _ in range(3)])
        self.assertTrue(all(r["ok"] for r in rs), rs)
        self.assertEqual(len([l for l in atv.remote_control.log if l == "volume_up"]), 3)

    async def test_volume_prefers_mrp_tunnel_when_present(self):
        atv, _ = await self.connect_fake()
        atv.has_mrp = True
        r = await self.h.call("key", key="volume_up")
        self.assertEqual(r["result"]["path"], "MRP HID (AirPlay tunnel)", r)
        self.assertEqual(atv.mrp_calls, ["volume_up"])
        self.assertEqual([l for l in atv.remote_control.log if l.startswith("volume")], [])
        # MRP отказал -> запасной Companion HID
        atv.mrp_volume = "unsupported"
        r = await self.h.call("key", key="volume_down")
        self.assertEqual(r["result"]["path"], "Companion HID", r)

    async def test_volume_user_selected_method_goes_first(self):
        atv, _ = await self.connect_fake()
        atv.has_mrp = True
        r = await self.h.call("set_options", volume_method="companion_hid")
        self.assertEqual(r["result"]["volume_method"], "companion_hid")
        r = await self.h.call("key", key="volume_up")
        self.assertEqual(r["result"]["path"], "Companion HID")
        self.assertEqual(atv.mrp_calls, [])
        await self.h.call("set_options", volume_method="auto")
        r = await self.h.call("key", key="volume_up")
        self.assertEqual(r["result"]["path"], "MRP HID (AirPlay tunnel)")

    async def test_volume_diag_describes_and_advises(self):
        atv, _ = await self.connect_fake()
        r = await self.h.call("volume_diag")
        info = r["result"]
        self.assertFalse(info["mrp_tunnel"])
        self.assertTrue(info["airplay_paired"])
        self.assertEqual(info["advice"], "force_tunnel")
        ids = [m["id"] for m in info["methods"]]
        self.assertIn("companion_hid", ids)
        self.assertNotIn("mrp_hid", ids)
        atv.has_mrp = True
        info = (await self.h.call("volume_diag"))["result"]
        self.assertTrue(info["mrp_tunnel"])
        self.assertNotIn("advice", info)
        self.assertIn("mrp_hid", [m["id"] for m in info["methods"]])

    async def test_volume_diag_run_reports_each_method(self):
        atv, _ = await self.connect_fake()
        atv.has_mrp = True
        atv.mrp_volume = "silent"  # отправляется, но ТВ молчит
        with self.assertLogs("atvd", level="INFO") as logs:
            r = await self.h.call("volume_diag", run=True, delay=0.01)
        self.assertTrue(r["ok"], r)
        res = {x["id"]: x for x in r["result"]["results"]}
        self.assertEqual(list(res)[:2], ["mrp_hid", "companion_hid"])
        for mid in ("mrp_hid", "companion_hid", "companion_hold", "mrp_hold", "audio", "set_volume"):
            self.assertIn(mid, res)
            self.assertTrue(res[mid]["ok"], res[mid])
        # «молчащий» MRP не менял громкость, рабочие — менял (по уровню у демо-устройства)
        self.assertFalse(res["mrp_hid"]["up"]["volume_changed"])
        self.assertTrue(res["companion_hid"]["up"]["volume_changed"])
        # удержание реально шлёт down, паузу и up
        self.assertEqual([c for c in atv.remote_control.api.calls if c[1] == "VolumeUp"],
                         [(True, "VolumeUp"), (False, "VolumeUp")])
        self.assertEqual(len(atv.remote_control.mrp.protocol.sent), 4)  # вверх и вниз: down+up
        self.assertTrue(any("Volume diagnostics: summary" in l for l in logs.output))
        progress = self.h.events("volume_diag")
        self.assertEqual(progress[-1]["phase"], "done")
        # диагностика ничего не ломает: после неё громкость работает
        r = await self.h.call("key", key="volume_up")
        self.assertTrue(r["ok"])

    async def test_volume_diag_single_method_and_errors(self):
        atv, _ = await self.connect_fake()
        r = await self.h.call("volume_diag", method="companion_hid", direction="down")
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["result"]["results"][0]["direction"], "down")
        r = await self.h.call("volume_diag", method="mrp_hid")
        self.assertFalse(r["ok"])
        self.assertEqual(r["error"]["code"], "invalid_args")
        atv.hid_volume = "unsupported"
        r = await self.h.call("volume_diag", method="companion_hid")
        self.assertFalse(r["result"]["results"][0]["ok"])
        self.assertEqual(r["result"]["results"][0]["error"], "not supported")

    async def test_mute_unsupported_over_hdmi_cec_has_explanation(self):
        atv, r = await self.connect_fake()
        atv.set_volume_state = atvd.FeatureState.Unavailable
        r = await self.h.call("mute")
        self.assertFalse(r["ok"])
        self.assertEqual(r["error"]["code"], "not_supported")
        self.assertIn("HDMI-CEC", r["error"]["message"])
        # а громкость при этом работает
        r = await self.h.call("key", key="volume_down")
        self.assertTrue(r["ok"])

    async def test_features_event_refreshes_when_state_changes(self):
        atv, _ = await self.connect_fake()
        n = len(self.h.events("features"))
        atv.set_volume_state = atvd.FeatureState.Unavailable
        atv.set_playing(fake_atv.DeviceState.Paused)
        await self.h.wait_for(lambda m: m.get("event") == "features" and m["data"]["features"]["SetVolume"] == "Unavailable")
        self.assertGreater(len(self.h.events("features")), n)

    async def test_reconnect_after_drop(self):
        dev = await self.pair_all()
        r = await self.h.call("connect", device=dev["id"])
        self.assertTrue(r["ok"])
        first = fake_atv.LAST_ATV
        n_conn = len([m for m in self.h.messages if m.get("event") == "state" and m["data"]["state"] == "connected"])
        first.drop()
        await self.h.wait_for(lambda m: m.get("event") == "state" and m["data"]["state"] == "reconnecting")
        await asyncio.sleep(0.5)
        n_conn2 = len([m for m in self.h.messages if m.get("event") == "state" and m["data"]["state"] == "connected"])
        self.assertEqual(n_conn2, n_conn + 1)
        self.assertIsNot(fake_atv.LAST_ATV, first)
        r = await self.h.call("key", key="up")
        self.assertTrue(r["ok"])

    async def test_command_failure_triggers_reconnect(self):
        dev = await self.pair_all()
        await self.h.call("connect", device=dev["id"])
        first = fake_atv.LAST_ATV
        first.alive = False  # молча умерло
        r = await self.h.call("key", key="up")
        self.assertFalse(r["ok"])
        self.assertEqual(r["error"]["code"], "connection")
        await asyncio.sleep(0.6)
        self.assertIsNot(fake_atv.LAST_ATV, first)
        r = await self.h.call("key", key="up")
        self.assertTrue(r["ok"])

    async def test_connect_retries_when_asleep(self):
        dev = await self.pair_all()
        fake_atv.CONNECT_FAILURES["count"] = 2
        r = await self.h.call("connect", device=dev["id"])
        self.assertFalse(r["ok"])  # первая попытка вернула ошибку клиенту
        await self.h.wait_for(lambda m: m.get("event") == "state" and m["data"]["state"] == "connected")

    async def test_disconnect_and_not_connected(self):
        dev = await self.pair_all()
        await self.h.call("connect", device=dev["id"])
        r = await self.h.call("disconnect")
        self.assertTrue(r["ok"])
        r = await self.h.call("key", key="up")
        self.assertEqual(r["error"]["code"], "not_connected")

    async def test_forget(self):
        dev = await self.pair_all()
        r = await self.h.call("forget", device=dev["id"])
        self.assertTrue(r["ok"], r)
        scan = await self.h.call("scan")
        self.assertFalse(any(s["paired"] for s in scan["result"]["devices"][0]["services"]))


class LocalizationTest(unittest.TestCase):
    """Сообщения демона для пользователя: английский по умолчанию, русский по --lang ru."""

    def tearDown(self):
        atvd.set_language("en")

    def test_default_is_english(self):
        atvd.set_language(None)
        self.assertEqual(atvd.tr("Operation timed out"), "Operation timed out")
        self.assertEqual(atvd.tr("Unknown key: {key}", key="x"), "Unknown key: x")

    def test_russian(self):
        atvd.set_language("ru-RU")
        self.assertEqual(atvd.tr("Operation timed out"), "Таймаут операции")
        self.assertEqual(atvd.tr("Unknown key: {key}", key="x"), "Неизвестная клавиша: x")

    def test_every_user_message_has_russian(self):
        import re
        src = open(os.path.join(PY_DIR, "atvd.py"), encoding="utf-8").read()
        for key in set(re.findall(r'\btr\(\s*"((?:[^"\\]|\\.)*)"', src)):
            # многострочные литералы дают только начало ключа — проверяем по префиксу
            self.assertTrue(any(k == key or k.startswith(key) for k in atvd.RU), key)

    def test_unknown_language_falls_back_to_english(self):
        atvd.set_language("de")
        self.assertEqual(atvd.tr("Connected"), "Connected")


class SubprocessTest(unittest.TestCase):
    """Настоящий процесс: stdin/stdout JSON lines, завершение по EOF."""

    def test_roundtrip(self):
        tmp = tempfile.mkdtemp()
        try:
            proc = subprocess.Popen(
                [sys.executable, os.path.join(PY_DIR, "atvd.py"), "--demo",
                 "--storage", os.path.join(tmp, "p.conf"), "--cache-dir", os.path.join(tmp, "c")],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            ready = json.loads(proc.stdout.readline())
            self.assertEqual(ready["event"], "ready")
            self.assertTrue(ready["data"]["demo"])
            proc.stdin.write(json.dumps({"id": 1, "cmd": "scan"}) + "\n")
            proc.stdin.flush()
            resp = json.loads(proc.stdout.readline())
            self.assertTrue(resp["ok"])
            self.assertEqual(resp["result"]["devices"][0]["name"], "Living Room (demo)")
            proc.stdin.write("not json\n")
            proc.stdin.write(json.dumps({"id": 2, "cmd": "quit"}) + "\n")
            proc.stdin.flush()
            lines = [json.loads(l) for l in proc.stdout.read().splitlines()]
            self.assertTrue(any(l.get("id") == 2 and l["ok"] for l in lines))
            self.assertEqual(proc.wait(timeout=10), 0)
            for pipe in (proc.stdin, proc.stdout, proc.stderr):
                if pipe and not pipe.closed:
                    pipe.close()
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_exit_on_eof(self):
        tmp = tempfile.mkdtemp()
        try:
            proc = subprocess.Popen(
                [sys.executable, os.path.join(PY_DIR, "atvd.py"), "--demo",
                 "--storage", os.path.join(tmp, "p.conf"), "--cache-dir", os.path.join(tmp, "c")],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            proc.stdout.readline()
            proc.stdin.close()
            self.assertEqual(proc.wait(timeout=10), 0)
            for pipe in (proc.stdin, proc.stdout, proc.stderr):
                if pipe and not pipe.closed:
                    pipe.close()
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
