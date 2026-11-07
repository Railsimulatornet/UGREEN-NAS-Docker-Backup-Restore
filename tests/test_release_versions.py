"""Keep the release, downloads and script versions in sync."""
import json,re,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
class ReleaseVersionTests(unittest.TestCase):
    def test_release_versions(self):
        cfg=json.loads((ROOT/'release.json').read_text(encoding='utf-8'))
        version=cfg['version']
        self.assertEqual(cfg['tag'],'v'+version)
        self.assertTrue(cfg['archive'].endswith(version+'.zip'))
        for name,marker in cfg['version_markers'].items():
            self.assertIn(marker.format(version=version),(ROOT/name).read_text(encoding='utf-8-sig'))
        for name in cfg['files']:
            self.assertTrue((ROOT/name).is_file(),name)
            if name.endswith('.sh'):
                text=(ROOT/name).read_text(encoding='utf-8')
                self.assertEqual(re.search(r'^SCRIPT_VERSION="([^"]+)"',text,re.M).group(1),version)
        for name in cfg['separate_assets']:
            self.assertIn(name,cfg['files'])
            self.assertTrue(name.endswith(version+'.pdf'),name)
