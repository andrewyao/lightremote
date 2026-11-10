import datetime as dt
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

import geotag

FIXTURES = Path(__file__).resolve().parents[1] / 'LightRemoteTests/Fixtures/clock_matching.json'


class GeotagTests(unittest.TestCase):
    def test_clock_and_coverage_contract(self):
        for case in json.loads(FIXTURES.read_text()):
            with self.subTest(case=case['name']), tempfile.TemporaryDirectory() as folder:
                root = ET.Element(f'{geotag.GPX_NS}gpx')
                extensions = ET.SubElement(ET.SubElement(root, f'{geotag.GPX_NS}metadata'),
                                           f'{geotag.GPX_NS}extensions')
                for when, offset in case['clock']:
                    ET.SubElement(extensions, f'{geotag.LR_NS}cameraClock',
                                  measuredAt=when, cameraMinusUtcSeconds=str(offset))
                for when, offset in case['offsets']:
                    ET.SubElement(extensions, f'{geotag.LR_NS}utcOffset',
                                  **{'from': when, 'minutes': str(offset)})
                segment = ET.SubElement(ET.SubElement(root, f'{geotag.GPX_NS}trk'), f'{geotag.GPX_NS}trkseg')
                for when in case['points']:
                    ET.SubElement(ET.SubElement(segment, f'{geotag.GPX_NS}trkpt'),
                                  f'{geotag.GPX_NS}time').text = when
                path = Path(folder) / '2026-11-08.gpx'
                ET.ElementTree(root).write(path)
                track = geotag.Track(path)
                offset, _ = geotag.choose_offset({track.day: track}, dt.datetime.fromisoformat(case['wall']))
                self.assertEqual(offset, case['expectedOffset'])
                self.assertEqual(len(track.clock), len(case['clock']))

    def test_filenames_are_single_arguments_and_batches_are_bounded(self):
        files = [f'/tmp/filename\n-ver\n{i}.JPG' for i in range(123)]
        reply = subprocess.CompletedProcess([], 0, '1 image files updated', '')
        with patch.object(geotag.subprocess, 'run', return_value=reply) as run:
            geotag.write_photos(files, 3600, ['/tmp/track.gpx'])
        self.assertEqual(run.call_count, 3)
        seen = []
        for call in run.call_args_list:
            args = call.args[0]
            self.assertNotIn('-@', args)
            self.assertNotIn('-ver', args)
            batch = args[args.index('--') + 1:]
            self.assertLessEqual(len(batch), 50)
            seen.extend(batch)
        self.assertEqual(seen, files)

    @unittest.skipUnless(shutil.which('exiftool'), 'requires exiftool')
    def test_real_exiftool_keeps_newline_filename_as_data(self):
        with tempfile.TemporaryDirectory() as folder:
            photo = Path(folder) / 'photo\n-ver\n.JPG'
            shutil.copy(FIXTURES.parents[2] / 'MockCamera/frames/frame00.jpg', photo)
            subprocess.run(['exiftool', '-DateTimeOriginal=2026:11:08 12:00:00',
                            '-overwrite_original', '--', str(photo)], check=True, capture_output=True)
            gpx = Path(folder) / 'track.gpx'
            gpx.write_text('''<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
            <trk><trkseg><trkpt lat="37" lon="-122"><time>2026-11-08T12:00:00Z</time></trkpt></trkseg></trk></gpx>''')
            self.assertEqual(geotag.write_photos([str(photo)], 0, [str(gpx)], no_backup=True), 1)
            result = subprocess.run(['exiftool', '-json', '-GPSLatitude', '-n', '--', str(photo)],
                                    check=True, capture_output=True, text=True)
            self.assertEqual(json.loads(result.stdout)[0]['GPSLatitude'], 37)

    def test_failed_photo_scan_is_reported(self):
        with patch.object(geotag.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'exiftool')):
            with self.assertRaises(subprocess.CalledProcessError):
                geotag.read_photos('/tmp/missing')


if __name__ == '__main__':
    unittest.main()
