"""What's playing on the laptop (Spotify, browser, ...), read from Windows' media controls."""
import asyncio
import base64
import io

from winrt.windows.media.control import (
    GlobalSystemMediaTransportControlsSessionManager as SessionManager,
    GlobalSystemMediaTransportControlsSessionPlaybackStatus as PlaybackStatus,
)


async def _current():
    manager = await SessionManager.request_async()
    session = manager.get_current_session()
    if session is None:
        return None
    props = await session.try_get_media_properties_async()
    status = session.get_playback_info().playback_status
    return {"title": props.title or "", "artist": props.artist or "",
            "app": app_name(session.source_app_user_model_id),
            "playing": status == PlaybackStatus.PLAYING}


def app_name(app_id):
    """'Spotify.exe' -> 'Spotify', 'Microsoft.MicrosoftEdge.Stable_8wek...!App' -> 'MicrosoftEdge'."""
    name = app_id.split("!")[0].split("_")[0].removesuffix(".exe")
    parts = name.split(".")
    return parts[1] if len(parts) > 1 else parts[0]


ART_PX = 360  # the Dock blurs it as a background: small is plenty


async def _artwork():
    manager = await SessionManager.request_async()
    session = manager.get_current_session()
    if session is None:
        return None
    props = await session.try_get_media_properties_async()
    if props.thumbnail is None:
        return None
    from winrt.windows.storage.streams import DataReader
    stream = await props.thumbnail.open_read_async()
    size = stream.size
    if not size:
        return None
    reader = DataReader(stream.get_input_stream_at(0))
    await reader.load_async(size)
    data = bytearray(size)
    reader.read_bytes(data)
    return bytes(data)


def artwork():
    """The playing song's cover as a base64 JPEG (at most ART_PX), or None."""
    try:
        data = asyncio.run(_artwork())
        if not data:
            return None
        from PIL import Image
        image = Image.open(io.BytesIO(data)).convert("RGB")
        image.thumbnail((ART_PX, ART_PX))
        out = io.BytesIO()
        image.save(out, "JPEG", quality=80)
        return base64.b64encode(out.getvalue()).decode()
    except Exception as e:  # no cover, or an app that hands over something odd
        print(f"no artwork: {e!r}")
        return None


def current():
    """A dict with title, artist, app, playing; or None when nothing is playing."""
    try:
        return asyncio.run(_current())
    except OSError:
        return None


if __name__ == "__main__":
    print(current())
