#!/usr/bin/env python3
"""Processus d'aide : pilote une Apple TV via pyatv, JSON lignes sur stdin/stdout.

Requete : {"id":1,"cmd":"key","args":{"name":"up"}}
Reponse : {"id":1,"ok":true,"result":...} ou {"id":1,"ok":false,"error":"..."}
Evenement : {"event":"now_playing","data":{...}}
Tout le journal va sur stderr.
"""
import asyncio
import base64
import json
import logging
import os
import sys
import traceback
from pathlib import Path
from typing import Any, Dict, Optional

import pyatv
from pyatv import exceptions
from pyatv.const import (DeviceState, InputAction, KeyboardFocusState,
                         PowerState, Protocol)
from pyatv.interface import (AudioListener, DeviceListener, KeyboardListener,
                             PowerListener, PushListener)
from pyatv.storage.file_storage import FileStorage

# stdout est reserve au protocole : tout print() parasite part sur stderr.
OUT = sys.stdout
sys.stdout = sys.stderr
logging.basicConfig(stream=sys.stderr, level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("atv_helper")

ROOT = Path(os.environ.get("ATV_ROOT", str(Path.home() / "AppleTVRemote")))
STORAGE_FILE = ROOT / "pyatv.conf"

PROTOCOLS = {"companion": Protocol.Companion, "airplay": Protocol.AirPlay,
             "mrp": Protocol.MRP, "raop": Protocol.RAOP, "dmap": Protocol.DMAP}


def pyatv_version() -> str:
    try:
        from importlib.metadata import version
        return version("pyatv")
    except Exception:
        return "?"


class HelperError(Exception):
    pass


def emit(obj: Dict[str, Any]) -> None:
    OUT.write(json.dumps(obj, ensure_ascii=False, default=str) + "\n")
    OUT.flush()


def event(name: str, data: Any = None) -> None:
    emit({"event": name, "data": data})


def enum_name(v: Any) -> str:
    return getattr(v, "name", str(v)).lower()


class Listener(PushListener, DeviceListener, PowerListener, AudioListener,
               KeyboardListener):
    def __init__(self, helper: "Helper") -> None:
        self.h = helper

    # push
    def playstatus_update(self, updater, playstatus) -> None:
        asyncio.ensure_future(self.h.publish_playing(playstatus))

    def playstatus_error(self, updater, exception: Exception) -> None:
        log.warning("playstatus_error: %s", exception)

    # device
    def connection_lost(self, exception: Exception) -> None:
        log.warning("connexion perdue: %s", exception)
        self.h.on_lost(str(exception))

    def connection_closed(self) -> None:
        log.info("connexion fermee")

    # power
    def powerstate_update(self, old_state, new_state) -> None:
        event("power", {"state": enum_name(new_state)})

    # audio
    def volume_update(self, old_level: float, new_level: float) -> None:
        event("volume", {"level": new_level})

    def volume_device_update(self, output_device, old_level, new_level) -> None:
        pass

    def outputdevices_update(self, old_devices, new_devices) -> None:
        pass

    # keyboard
    def focusstate_update(self, old_state, new_state) -> None:
        event("keyboard", {"focused": new_state == KeyboardFocusState.Focused,
                           "state": enum_name(new_state)})


class Helper:
    def __init__(self) -> None:
        self.loop = asyncio.get_running_loop()
        ROOT.mkdir(parents=True, exist_ok=True)
        self.storage = FileStorage(str(STORAGE_FILE), self.loop)
        self.configs: Dict[str, Any] = {}
        self.atv: Optional[pyatv.interface.AppleTV] = None
        self.current_id: Optional[str] = None
        self.listener = Listener(self)
        self.pairing = None          # (handler, identifier, protocol_name)
        self.last_artwork_id: Optional[str] = None
        self.last_artwork: Optional[str] = None
        self.user_disconnect = False
        self.premute_volume: Optional[float] = None

    async def start(self) -> None:
        await self.storage.load()

    # ---------------------------------------------------------------- scan
    async def scan(self, timeout: int = 5, **_) -> Any:
        found = await pyatv.scan(self.loop, timeout=int(timeout), storage=self.storage)
        out = []
        for c in found:
            protos = {s.protocol for s in c.services}
            # Ne garde que les vraies Apple TV / HomePod (Companion, MRP ou AirPlay tvOS).
            if not c.identifier:
                continue
            self.configs[c.identifier] = c
            try:
                model = c.device_info.model_str
                version = c.device_info.version
            except Exception:
                model, version = "", None
            out.append({
                "name": c.name,
                "identifier": c.identifier,
                "all_identifiers": list(c.all_identifiers),
                "address": str(c.address),
                "model": model,
                "version": version,
                "is_apple_tv": any(s.protocol in (Protocol.Companion, Protocol.MRP) and enum_name(s.pairing) != "unsupported" for s in c.services),
                "services": [{
                    "protocol": enum_name(s.protocol),
                    "port": s.port,
                    "paired": s.credentials is not None,
                    "pairing": enum_name(s.pairing),
                } for s in c.services],
            })
        return out

    async def get_config(self, identifier: str):
        try:
            found = await pyatv.scan(self.loop, timeout=5, identifier=identifier,
                                     storage=self.storage)
            if found:
                self.configs[identifier] = found[0]
                return found[0]
        except Exception as ex:
            log.warning("scan cible echoue: %s", ex)
        cfg = self.configs.get(identifier)
        if cfg is None:
            raise HelperError("Appareil introuvable sur le réseau.")
        return cfg

    # -------------------------------------------------------------- pairing
    async def pair_begin(self, identifier: str, protocol: str, **_) -> Any:
        proto = PROTOCOLS.get(str(protocol).lower())
        if proto is None:
            raise HelperError(f"Protocole inconnu : {protocol}")
        await self.pair_cancel()
        cfg = await self.get_config(identifier)
        handler = await pyatv.pair(cfg, proto, self.loop, storage=self.storage)
        await handler.begin()
        self.pairing = (handler, identifier, str(protocol).lower())
        return {"device_provides_pin": handler.device_provides_pin,
                "protocol": str(protocol).lower()}

    async def pair_pin(self, pin: str, **_) -> Any:
        if not self.pairing:
            raise HelperError("Aucun appairage en cours.")
        handler, identifier, proto = self.pairing
        handler.pin(str(pin).strip())
        try:
            await handler.finish()
            paired = handler.has_paired
            if paired:
                await self.storage.save()
        finally:
            await handler.close()
            self.pairing = None
        if not paired:
            raise HelperError("Appairage refusé (code incorrect ?).")
        return {"paired": True, "protocol": proto}

    async def pair_cancel(self, **_) -> Any:
        if self.pairing:
            handler = self.pairing[0]
            self.pairing = None
            try:
                await handler.close()
            except Exception:
                pass
        return True

    async def forget(self, identifier: str, **_) -> Any:
        if self.current_id == identifier:
            await self.disconnect()
        cfg = self.configs.get(identifier)
        if cfg is None:
            cfg = await self.get_config(identifier)
        settings = await self.storage.get_settings(cfg)
        await self.storage.remove_settings(settings)
        await self.storage.save()
        return True

    # ------------------------------------------------------------ connexion
    async def connect(self, identifier: str, **_) -> Any:
        await self.disconnect(quiet=True)
        self.user_disconnect = False
        cfg = await self.get_config(identifier)
        atv = await pyatv.connect(cfg, self.loop, storage=self.storage)
        self.atv = atv
        self.current_id = identifier
        self.last_artwork_id = None
        self.last_artwork = None
        self.premute_volume = None
        atv.listener = self.listener
        atv.push_updater.listener = self.listener
        for name, attr in (("power", "power"), ("audio", "audio"), ("keyboard", "keyboard")):
            try:
                getattr(atv, attr).listener = self.listener
            except Exception as ex:
                log.info("pas de listener %s: %s", name, ex)
        try:
            atv.push_updater.start()
        except Exception as ex:
            log.info("push_updater: %s", ex)
        info = {"identifier": identifier, "name": cfg.name,
                "features": self.feature_summary()}
        event("connected", info)
        try:
            event("power", {"state": enum_name(atv.power.power_state)})
        except Exception:
            pass
        try:
            event("keyboard", {"focused": atv.keyboard.text_focus_state == KeyboardFocusState.Focused,
                               "state": enum_name(atv.keyboard.text_focus_state)})
        except Exception:
            pass
        asyncio.ensure_future(self.initial_playing())
        return info

    def feature_summary(self) -> Dict[str, bool]:
        res: Dict[str, bool] = {}
        atv = self.atv
        if not atv:
            return res
        try:
            from pyatv.const import FeatureName, FeatureState
            for n in ("Swipe", "TouchClick", "TextSet", "AppList", "LaunchApp",
                      "SetVolume", "VolumeUp", "PowerState", "Artwork", "ControlCenter", "HomeHold"):
                fn = getattr(FeatureName, n, None)
                if fn is not None:
                    st = atv.features.get_feature(fn).state
                    res[n] = st == FeatureState.Available
        except Exception as ex:
            log.info("features: %s", ex)
        return res

    async def initial_playing(self) -> None:
        try:
            if self.atv:
                await self.publish_playing(await self.atv.metadata.playing())
        except Exception as ex:
            log.info("playing initial: %s", ex)

    def on_lost(self, reason: str) -> None:
        ident = self.current_id
        self.atv = None
        if not self.user_disconnect:
            event("connection_lost", {"identifier": ident, "reason": reason})

    async def disconnect(self, quiet: bool = False, **_) -> Any:
        self.user_disconnect = True
        atv, self.atv = self.atv, None
        if atv:
            try:
                atv.push_updater.stop()
            except Exception:
                pass
            try:
                tasks = atv.close()
                if tasks:
                    await asyncio.wait(tasks, timeout=3)
            except Exception as ex:
                log.info("close: %s", ex)
            if not quiet:
                event("disconnected", {"identifier": self.current_id})
        self.current_id = None
        return True

    def need(self):
        if not self.atv:
            raise HelperError("Non connecté à une Apple TV.")
        return self.atv

    # ---------------------------------------------------------------- touches
    async def key(self, name: str, long: bool = False, **_) -> Any:
        atv = self.need()
        name = str(name).lower()
        if name.endswith("_long"):
            name, long = name[:-5], True
        rc = atv.remote_control
        action = InputAction.Hold if long else InputAction.SingleTap
        simple = {
            "up": rc.up, "down": rc.down, "left": rc.left, "right": rc.right,
            "select": rc.select, "menu": rc.menu, "home": rc.home,
        }
        if name == "home_hold":
            try:
                await rc.home(action=InputAction.Hold)
            except exceptions.NotSupportedError:
                await rc.control_center()
            return True
        if name == "control_center":
            await rc.control_center()
            return True
        if name in simple:
            if long:
                await simple[name](action=action)
            else:
                await simple[name]()
            return True
        plain = {
            "top_menu": rc.top_menu, "play_pause": rc.play_pause, "play": rc.play,
            "pause": rc.pause, "stop": rc.stop, "next": rc.next,
            "previous": rc.previous, "skip_forward": rc.skip_forward,
            "skip_backward": rc.skip_backward, "volume_up": rc.volume_up,
            "volume_down": rc.volume_down, "screensaver": rc.screensaver,
        }
        fn = plain.get(name)
        if fn is None:
            raise HelperError(f"Touche inconnue : {name}")
        await fn()
        return True

    async def swipe(self, start_x: int, start_y: int, end_x: int, end_y: int,
                    duration_ms: int = 150, **_) -> Any:
        atv = self.need()
        clamp = lambda v: max(0, min(1000, int(v)))
        await atv.touch.swipe(clamp(start_x), clamp(start_y), clamp(end_x),
                              clamp(end_y), max(1, int(duration_ms)))
        return True

    async def touch_click(self, action: str = "single", **_) -> Any:
        atv = self.need()
        a = {"single": InputAction.SingleTap, "double": InputAction.DoubleTap,
             "hold": InputAction.Hold}.get(str(action).lower(), InputAction.SingleTap)
        await atv.touch.click(a)
        return True

    # ------------------------------------------------------------------ texte
    async def text_set(self, text: str, **_) -> Any:
        await self.need().keyboard.text_set(str(text))
        return True

    async def text_append(self, text: str, **_) -> Any:
        await self.need().keyboard.text_append(str(text))
        return True

    async def text_clear(self, **_) -> Any:
        await self.need().keyboard.text_clear()
        return True

    async def text_get(self, **_) -> Any:
        return await self.need().keyboard.text_get()

    async def keyboard_state(self, **_) -> Any:
        st = self.need().keyboard.text_focus_state
        return {"focused": st == KeyboardFocusState.Focused, "state": enum_name(st)}

    # -------------------------------------------------------------------- apps
    async def apps(self, **_) -> Any:
        lst = await self.need().apps.app_list()
        return [{"name": a.name or a.identifier, "bundle_id": a.identifier} for a in lst]

    async def launch(self, bundle_id: str, **_) -> Any:
        await self.need().apps.launch_app(str(bundle_id))
        return True

    # ------------------------------------------------------------- alimentation
    async def power_on(self, **_) -> Any:
        await self.need().power.turn_on()
        return True

    async def power_off(self, **_) -> Any:
        await self.need().power.turn_off()
        return True

    async def power_state(self, **_) -> Any:
        return enum_name(self.need().power.power_state)

    async def volume_set(self, level: float, **_) -> Any:
        await self.need().audio.set_volume(float(level))
        return True

    async def mute_toggle(self, **_) -> Any:
        """Muet émulé : mémorise le volume, passe à 0, puis restaure au second appel."""
        atv = self.need()
        try:
            from pyatv.const import FeatureName, FeatureState
            ok = atv.features.get_feature(FeatureName.SetVolume).state == FeatureState.Available
        except Exception:
            ok = False
        if not ok:
            raise HelperError("Muet indisponible : le réglage du volume n'est pas pris en charge.")
        if self.premute_volume is not None:
            level, self.premute_volume = self.premute_volume, None
            await atv.audio.set_volume(float(level))
            return {"muted": False, "level": level}
        cur = atv.audio.volume
        if cur is None or float(cur) <= 0:
            raise HelperError("Volume actuel inconnu ou déjà à zéro.")
        self.premute_volume = float(cur)
        await atv.audio.set_volume(0.0)
        return {"muted": True, "level": 0.0}

    async def volume_get(self, **_) -> Any:
        return self.need().audio.volume

    # ------------------------------------------------------------- lecture en cours
    async def publish_playing(self, p) -> None:
        data = self.playing_dict(p)
        atv = self.atv
        if atv:
            try:
                app = atv.metadata.app
                if app:
                    data["app"] = app.name or app.identifier
                    data["app_id"] = app.identifier
            except Exception:
                pass
            try:
                aid = atv.metadata.artwork_id
            except Exception:
                aid = None
            if data["state"] in ("playing", "paused", "loading", "seeking", "stopped") and (data["title"] or aid):
                if aid is None or aid != self.last_artwork_id:
                    self.last_artwork_id = aid
                    self.last_artwork = None
                    try:
                        art = await atv.metadata.artwork(width=300, height=None)
                        if art and art.bytes:
                            self.last_artwork = base64.b64encode(art.bytes).decode("ascii")
                    except Exception as ex:
                        log.info("artwork: %s", ex)
                data["artwork"] = self.last_artwork
                data["artwork_mime"] = "image/jpeg"
        event("now_playing", data)

    @staticmethod
    def playing_dict(p) -> Dict[str, Any]:
        def g(attr):
            try:
                return getattr(p, attr)
            except Exception:
                return None
        return {
            "state": enum_name(g("device_state")) if g("device_state") is not None else "idle",
            "media_type": enum_name(g("media_type")) if g("media_type") is not None else None,
            "title": g("title"), "artist": g("artist"), "album": g("album"),
            "position": g("position"), "total_time": g("total_time"),
            "series_name": g("series_name"),
        }

    async def now_playing(self, **_) -> Any:
        atv = self.need()
        p = await atv.metadata.playing()
        await self.publish_playing(p)
        return self.playing_dict(p)

    async def ping(self, **_) -> Any:
        return "pong"

    async def shutdown(self, **_) -> Any:
        await self.disconnect(quiet=True)
        asyncio.get_running_loop().call_later(0.1, lambda: os._exit(0))
        return True

    # ---------------------------------------------------------------- dispatch
    async def handle(self, line: str) -> None:
        rid = None
        try:
            req = json.loads(line)
            rid = req.get("id")
            cmd = str(req.get("cmd", ""))
            args = req.get("args") or {}
            if cmd.startswith("_") or not hasattr(Helper, cmd) or cmd in ("handle", "start", "need", "on_lost", "publish_playing", "playing_dict", "feature_summary", "get_config", "initial_playing"):
                raise HelperError(f"Commande inconnue : {cmd}")
            result = await getattr(self, cmd)(**args)
            emit({"id": rid, "ok": True, "result": result})
        except exceptions.NotSupportedError:
            emit({"id": rid, "ok": False, "error": "Fonction non prise en charge par cet appareil (appairage manquant ?)."})
        except exceptions.BlockedStateError as ex:
            emit({"id": rid, "ok": False, "error": f"Action indisponible dans l'état actuel : {ex}"})
        except exceptions.AuthenticationError as ex:
            emit({"id": rid, "ok": False, "error": f"Authentification échouée : {ex}"})
        except HelperError as ex:
            emit({"id": rid, "ok": False, "error": str(ex)})
        except TypeError as ex:
            emit({"id": rid, "ok": False, "error": f"Arguments invalides : {ex}"})
        except Exception as ex:  # ne jamais planter
            log.error("erreur: %s\n%s", ex, traceback.format_exc())
            emit({"id": rid, "ok": False, "error": f"{type(ex).__name__}: {ex}"})


async def main() -> None:
    helper = Helper()
    await helper.start()
    reader = asyncio.StreamReader(limit=1 << 24)
    await asyncio.get_running_loop().connect_read_pipe(
        lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
    event("ready", {"pyatv": pyatv_version(),
                    "storage": str(STORAGE_FILE)})
    tasks = set()
    while True:
        line = await reader.readline()
        if not line:
            break
        s = line.decode("utf-8", "replace").strip()
        if not s:
            continue
        t = asyncio.ensure_future(helper.handle(s))
        tasks.add(t)
        t.add_done_callback(tasks.discard)
    if tasks:
        await asyncio.wait(tasks, timeout=30)
    await helper.disconnect(quiet=True)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
