"""What's playing on the laptop (Spotify, browser, ...), read from Windows' media controls."""
import asyncio

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


def current():
    """A dict with title, artist, app, playing; or None when nothing is playing."""
    try:
        return asyncio.run(_current())
    except OSError:
        return None


if __name__ == "__main__":
    print(current())
