#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('phrases', root / 'scripts/generate-common-phrases.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
source = (root / 'Resources/CommonPhrases/built-in.md').read_text()

class PhraseTests(unittest.TestCase):
    def test_resource(self):
        result = module.generate(source)
        self.assertEqual(len(result['entries']), 12)
        self.assertEqual(result['bindings']['ok'], 'builtin-001')
        self.assertEqual(result['entries'][3]['text'], '解释清楚一点')
    def test_device_keys_have_defaults(self):
        result = module.generate(source)
        self.assertEqual(len(result['bindings']), 14)
        self.assertEqual(result['bindings']['home'], 'builtin-006')
        self.assertEqual(result['bindings']['mute'], 'builtin-007')
        self.assertEqual(result['bindings']['volume_up'], 'builtin-007')
        self.assertEqual(result['bindings']['menu'], 'builtin-008')
        self.assertEqual(result['bindings']['youtube'], 'builtin-008')
        self.assertEqual(result['bindings']['volume_down'], 'builtin-009')
        self.assertEqual(result['bindings']['netflix'], 'builtin-009')
        self.assertEqual(result['bindings']['tv'], 'builtin-010')
        self.assertEqual(result['bindings']['input'], 'builtin-010')
        self.assertNotIn('power', result['bindings'])
        self.assertNotIn('back', result['bindings'])
    def test_swift_store_buttons_match_generator_bindings(self):
        swift = (root / 'Sources/RemoteBuddy/CommonPhrases/CommonPhraseStore.swift').read_text()
        case_to_raw = {'volumeUp': 'volume_up', 'volumeDown': 'volume_down'}
        import re
        def extract_buttons(name):
            match = re.search(rf'static let {name}\b[^=]*=\s*(\[(?:[^\[\]]|\[[^\[\]]*\])*\])', swift, re.S)
            self.assertIsNotNone(match, f'Missing {name}')
            tokens = re.findall(r'\.([A-Za-z0-9_]+)', match.group(1))
            return [case_to_raw.get(token, token) for token in tokens if token != 'nil']
        base = set(extract_buttons('baseButtons'))
        swift_groups = [
            base | set(extract_buttons('chromecastExtraRows')),
            base | set(extract_buttons('xiaomiExtraRows')),
            base | set(extract_buttons('t1ExtraRows')),
        ]
        all_swift = set().union(*swift_groups)
        result = module.generate(source)
        self.assertEqual(all_swift, set(result['bindings']))
        for group in swift_groups:
            self.assertEqual(len({result['bindings'][k] for k in group}), len(group))
    def test_entries_keep_only_original_chinese_content_with_neutral_fields(self):
        result = module.generate(source)
        self.assertEqual(result['schemaVersion'], 2)
        self.assertEqual(result['entries'][0], {'id': 'builtin-001', 'text': '好的', 'label': '好的'})
        self.assertTrue(all(set(p) == {'id', 'text', 'label'} for p in result['entries']))
        self.assertEqual(len(set(p['id'] for p in result['entries'])), 12)
        self.assertEqual(result['builtInIDs'], [p['id'] for p in result['entries']])
    def test_source_changes_flow_to_json(self):
        result = module.generate(source.replace('好的', '没问题'))
        self.assertEqual(result['entries'][0]['text'], '没问题')
    def test_bad_defaults_fail(self):
        for bad in [source.replace('| OK | 1 |', '| OK | 99 |'),
                    source.replace('| 左 | 2 |', '| OK | 2 |'),
                    source.replace('| 上 | 4 | 解释清楚一点 |', '| 上 | 4 | 错误 |'),
                    source.replace('| 静音 | 7 | 简短一点 |', '| 静音 | 6 | 检查一下有没有问题 |'),
                    source.replace('| TV | 10 | 还有其他方案吗？ |', '| TV | 6 | 检查一下有没有问题 |')]:
            with self.assertRaises(ValueError): module.generate(bad)
    def test_bad_phrase_rows_fail(self):
        for bad in [source.replace('| 2 | 继续 |', '| 1 | 继续 |'),
                    source.replace('| 1 | 好的 | 好的 |', '| 1 | 好的 | |')]:
            with self.assertRaises(ValueError): module.generate(bad)

unittest.main()
