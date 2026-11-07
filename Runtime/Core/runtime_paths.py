"""Read-only program files, explicit official dependencies, private writable state."""
import os
from pathlib import Path

SOURCE = Path(__file__).resolve().parent
DEFAULT_DATA = Path.home() / 'Library/Application Support/Organic Codex/Core'
DEFAULT_MODULES = ('adapters.browser.adapter', 'adapters.app_server', 'adapters.capture',
                   'adapters.scheduler.adapter', 'adapters.preview', 'adapters.workspace')


class RuntimePaths:
    def __init__(self):
        self.configure()

    def configure(self, data_dir=None, work_root=None, resources=None):
        self.data = Path(data_dir or os.environ.get('ORGANIC_CORE_DATA_DIR') or DEFAULT_DATA).expanduser().resolve()
        self.work = Path(work_root or os.environ.get('ORGANIC_CORE_WORK_ROOT') or Path.home()).expanduser().resolve()
        override = resources or os.environ.get('ORGANIC_CORE_RESOURCES')
        candidates = [Path('/Applications/ChatGPT.app/Contents/Resources'), Path('/Applications/Codex.app/Contents/Resources')]
        self.resources = Path(override).expanduser().resolve() if override else next(
            (p for p in candidates if (p/'codex-cli/bin/codex').is_file()), candidates[0])
        self.modules = self.resources/'cua_node/lib/node_modules'
        self.cli = self.resources/'codex-cli/bin/codex'
        self.node = self.resources/'cua_node/bin/node'
        self.cua = self.modules/'@oai/cua-repl/bin/cua-repl.mjs'
        self.helpers = self.data/'helpers'
        self.logs = self.data/'logs'
        self.screenshots = self.data/'screenshots'
        chromium = os.environ.get('ORGANIC_CORE_CHROMIUM')
        found = sorted((Path.home()/'Library/Caches/ms-playwright').glob(
            'chromium-*/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing'))
        self.chromium = Path(chromium).expanduser() if chromium else (found[-1] if found else None)
        return self

    def prepare(self):
        if self.data == SOURCE or SOURCE in self.data.parents:
            raise ValueError('Core data directory must be outside the installed source directory')
        for folder in (self.data, self.logs, self.screenshots, self.helpers):
            folder.mkdir(parents=True, exist_ok=True)
        self.data.chmod(0o700)
        if not self.work.is_dir():
            raise ValueError('Core work root does not exist: '+str(self.work))

    def child_environment(self):
        return {'ORGANIC_CORE_DATA_DIR': str(self.data), 'ORGANIC_CORE_WORK_ROOT': str(self.work),
                'ORGANIC_CORE_RESOURCES': str(self.resources),
                'ORGANIC_CORE_CHROMIUM': str(self.chromium) if self.chromium else ''}


paths = RuntimePaths()
