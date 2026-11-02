"""Generate a local Xcode spec without fetching Sparkle's entire git history."""
import json
import os
from pathlib import Path

root = Path(__file__).resolve().parents[2]
spec = json.loads((root / '.local/project-spec.json').read_text())
spec['name'] = 'OpenSidecar'
spec.pop('packages', None)
framework = '.local/dependencies/Sparkle.xcframework'
for name in ('OpenSidecarMac', 'OpenSidecarMacReceiver'):
    if (root / framework).is_dir():
        spec['targets'][name]['dependencies'] = [
            {'framework': framework, 'embed': True, 'codeSign': True}
        ]
        spec['targets'][name]['info']['properties']['SUEnableAutomaticChecks'] = False
    else:
        spec['targets'].pop(name, None)
        spec['schemes'].pop(name, None)
spec['schemes']['LocalTests'] = {
    'build': {'targets': {'OpenSidecarMacTests': 'all'}},
    'test': {'targets': ['OpenSidecarMacTests']},
}
spec['targets']['OpenSidecariOS']['settings']['base']['PRODUCT_BUNDLE_IDENTIFIER'] = os.environ.get(
    'IOS_BUNDLE_IDENTIFIER', 'com.example.opendisplay.ios.dev'
)
spec['settings']['base']['MARKETING_VERSION'] = json.loads(
    (root / '.release-please-manifest.json').read_text()
)['.']
(root / '.local/project-local.json').write_text(json.dumps(spec, indent=2) + '\n')
