"""Report installed requirements separately from actual OS/account authorization."""
from pathlib import Path
import shutil
from runtime_paths import paths


def capabilities(core):
    connected = bool(core.app and not core.app.closed)
    modules = set(getattr(core.args, 'adapter', []))
    def feature(available, reason='', **extra):
        return {'available': bool(available), 'status': 'available' if available else 'unavailable',
                'reason': '' if available else reason, **extra}
    cua = paths.node.is_file() and paths.cua.is_file()
    browser = 'adapters.browser.adapter' in modules
    capture = 'adapters.capture' in modules
    screen = paths.helpers/'Organic Capture.app/Contents/MacOS/OrganicCapture'
    result = {
        'chat': feature(connected, 'Official App Server is disconnected'),
        'models': feature(connected, 'Official App Server is disconnected'),
        'files': feature(connected, 'Official App Server is disconnected'),
        'approvals': feature(connected, 'Official App Server is disconnected'),
        'nativeComputer': feature(cua and connected, 'Official Node/CUA runtime is missing or disconnected', authorization='checked-by-official-cua'),
        'browser': feature(browser and connected and paths.node.is_file() and (paths.modules/'playwright/package.json').is_file() and paths.chromium and paths.chromium.is_file(), 'Playwright, Chromium, Node or browser adapter unavailable'),
        'browserExtension': feature(browser and connected and cua, 'Official browser CUA runtime unavailable', authorization='extension-and-browser-connection-required', connectionVerified=False),
        'captureWindow': feature(capture and connected and cua, 'Capture adapter or official CUA unavailable', authorization='checked-by-official-cua'),
        'captureScreen': feature(capture and screen.is_file(), 'Build capture helpers before screen capture', authorization='macos-screen-recording-required', permissionVerified=False),
        'captureHotkey': feature(capture and (paths.helpers/'HotkeyHelper').is_file(), 'Build hotkey helper before enabling shortcut'),
        'attachments': feature('adapters.preview' in modules, 'Preview adapter not loaded'),
        'preview': feature('adapters.preview' in modules, 'Preview adapter not loaded'),
        'scheduler': feature('adapters.scheduler.adapter' in modules and connected, 'Scheduler or official backend unavailable'),
        'plugins': feature('adapters.app_server' in modules and connected, 'Official App Server aliases unavailable', authorization='checked-by-official-backend'),
        'voice': feature(False, 'Paused: realtime audio and tool handoff have not passed upstream validation'),
        'git': feature(('POST','/workspace/git/status') in core.routes and shutil.which('git'), 'Workspace adapter or Git executable unavailable'),
        'terminal': feature(('POST','/terminal/open') in core.routes, 'Workspace terminal adapter unavailable', maxBufferBytes=262144),
    }
    return {'version': '26102601', 'features': result,
            'paths': {'dataDir': str(paths.data), 'workRoot': str(paths.work), 'resources': str(paths.resources)},
            'routes': sorted(method+' '+url for method, url in core.routes)}
